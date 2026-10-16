import 'dart:io';

import 'edge_address_resolver.dart';
import 'hev_socks5_tunnel.dart';

typedef RouteProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);
typedef RouteAddressLookup =
    Future<List<InternetAddress>> Function(String host);

class _DefaultRoute {
  const _DefaultRoute(this.gateway, this.interfaceIndex, this.metric);

  final String gateway;
  final int interfaceIndex;
  final int metric;
}

class _DnsSnapshot {
  const _DnsSnapshot(this.isStatic, this.servers);

  final bool isStatic;
  final List<String> servers;
}

/// Owns IPv4 host bypasses, tunnel split routes and DNS changes on Windows.
/// The physical default and all IPv6 routes are always left untouched.
class RouteManager {
  RouteManager({
    RouteProcessRunner? processRun,
    RouteAddressLookup? lookup,
    this.tunnelWaitTimeout = const Duration(seconds: 10),
    this.tunnelPollInterval = const Duration(milliseconds: 400),
  }) : _processRun = processRun ?? _runProcess,
       _lookup = lookup ?? InternetAddress.lookup;

  static final RouteManager instance = RouteManager();

  static Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments,
  ) => Process.run(executable, arguments);

  static const List<String> controlPlaneHosts = [
    'vpn.mozilla.org',
    'firefox.settings.services.mozilla.com',
    'api.accounts.firefox.com',
    'accounts.firefox.com',
  ];

  static const List<String> dohLiterals = [
    '1.1.1.1',
    '1.0.0.1',
    '8.8.8.8',
    '8.8.4.4',
    '9.9.9.9',
    '149.112.112.112',
  ];

  final RouteProcessRunner _processRun;
  final RouteAddressLookup _lookup;
  final Duration tunnelWaitTimeout;
  final Duration tunnelPollInterval;
  final Set<String> _addedRoutes = {};
  final Set<String> _splitRoutes = {};
  final Map<String, String> _hostAddresses = {};
  List<String> _dohEndpoints = const [];
  final Map<int, _DnsSnapshot> _savedDns = {};
  final Set<int> _changedDns = {};
  _DefaultRoute? _physicalRoute;
  int? _tunnelIndex;
  bool _active = false;
  bool _enableComplete = false;
  bool _takeoverActive = false;
  bool _dnsFlushPending = false;

  bool get isActive => _active;
  bool get takeoverActive => _takeoverActive || _hasPendingTakeover;

  bool get _hasPendingTakeover =>
      _splitRoutes.isNotEmpty || _changedDns.isNotEmpty || _dnsFlushPending;

  /// Installs physical /32 bypasses before the tunnel starts.
  Future<void> enable({
    List<String> extraBypassHosts = const [],
    List<String> dohEndpointAddresses = const [],
  }) async {
    if (takeoverActive) {
      throw StateError('Release the previous tunnel takeover before enabling.');
    }
    if (_active) {
      if (_enableComplete) return;
      throw StateError('Disable the pending bypass cleanup before enabling.');
    }
    _dohEndpoints = dohEndpointAddresses;
    final route = await _readDefaultRoute();
    if (route == null) {
      throw StateError(
        'No connected IPv4 default with a usable physical gateway.',
      );
    }
    _physicalRoute = route;
    _active = true;

    try {
      final ips = <String>{...dohLiterals};
      for (final host in [...controlPlaneHosts, ...extraBypassHosts]) {
        final normalized = host.trim().toLowerCase();
        final ip = await _resolveRealIpv4(normalized);
        if (ip == null) continue;
        ips.add(ip);
        _hostAddresses[normalized] = ip;
      }
      for (final ip in ips) {
        await _addBypass(ip);
      }
      _enableComplete = true;
    } catch (failure) {
      try {
        await disable();
      } catch (rollbackFailure) {
        throw StateError('$failure; bypass rollback failed: $rollbackFailure');
      }
      rethrow;
    }
  }

  /// Returns an address only when its exact physical /32 bypass is installed.
  /// Synthetic answers, including synthetic literals, are never dialled.
  Future<String?> ensureBypassHost(String host) async {
    if (!_active || !_enableComplete) return null;
    final normalized = host.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    final ip = _hostAddresses[normalized] ?? await _resolveRealIpv4(normalized);
    if (ip == null) return null;
    if (!_addedRoutes.contains(ip)) {
      try {
        await _addBypass(ip);
      } catch (_) {
        return null;
      }
    }
    _hostAddresses[normalized] = ip;
    return ip;
  }

  /// Removes a /32 bypass that [ensureBypassHost] installed earlier, so split
  /// tunneling can retire destinations it no longer dials. Throws when the
  /// delete fails and keeps ownership, exactly like the other cleanups: the
  /// route stays in [_addedRoutes] and [disable] will try again.
  Future<bool> removeBypassHost(String ip) async {
    final literal = ip.trim();
    if (!_addedRoutes.contains(literal)) return false;
    final route = _physicalRoute;
    if (route == null) return false;
    await _runRoute([
      'delete',
      literal,
      'mask',
      '255.255.255.255',
      route.gateway,
      'if',
      '${route.interfaceIndex}',
    ]);
    _addedRoutes.remove(literal);
    _hostAddresses.removeWhere((host, address) => address == literal);
    return true;
  }

  /// Installs two owned /1 routes and DNS after the tunnel adapter appears.
  /// Failed operations roll back; failed rollback remains retryable.
  Future<void> takeoverRoutes({String? customDnsServer}) async {
    final dnsServer = customDnsServer?.trim() ?? HevSocks5Tunnel.mapdnsAddress;
    if (!_isIpLiteral(dnsServer)) {
      throw ArgumentError.value(
        customDnsServer,
        'customDnsServer',
        'Expected an IP literal',
      );
    }
    if (!_active || !_enableComplete || _physicalRoute == null) {
      throw StateError(
        'Enable physical bypasses before taking over the tunnel.',
      );
    }
    if (takeoverActive) {
      throw StateError(
        'Release the previous tunnel takeover before taking over.',
      );
    }
    final tunIndex = await _findTunnelInterfaceIndex();
    if (tunIndex == null || tunIndex == _physicalRoute!.interfaceIndex) {
      throw StateError('The tunnel IPv4 adapter did not appear.');
    }
    _tunnelIndex = tunIndex;

    try {
      await _captureDns(tunIndex);
      for (final destination in ['0.0.0.0', '128.0.0.0']) {
        await _runRoute([
          'add',
          destination,
          'mask',
          '128.0.0.0',
          '0.0.0.0',
          'metric',
          '1',
          'if',
          '$tunIndex',
        ]);
        _splitRoutes.add(destination);
      }
      for (final index in _savedDns.keys) {
        // A failed cmdlet may already have changed this interface's DNS.
        _changedDns.add(index);
        _dnsFlushPending = true;
        await _powershell(
          'Set-DnsClientServerAddress -InterfaceIndex $index '
          "-ServerAddresses '$dnsServer'",
        );
      }
      await _powershell('Clear-DnsClientCache');
      _dnsFlushPending = false;
      _takeoverActive = true;
    } catch (failure) {
      try {
        await releaseTunnel();
      } catch (rollbackFailure) {
        throw StateError('$failure; tunnel rollback failed: $rollbackFailure');
      }
      rethrow;
    }
  }

  /// Restore physical AND tunnel DNS, remove only owned split routes, and
  /// flush DNS before the caller stops the tunnel. Retry after any failure.
  Future<void> releaseTunnel() async {
    final failures = <Object>[];
    for (final index in _changedDns.toList().reversed) {
      final snapshot = _savedDns[index]!;
      try {
        await _powershell(
          'Set-DnsClientServerAddress -InterfaceIndex $index '
          '${snapshot.isStatic ? "-ServerAddresses @('${snapshot.servers.join("','")}')" : '-ResetServerAddresses'}',
        );
        _changedDns.remove(index);
        _savedDns.remove(index);
        _dnsFlushPending = true;
      } catch (failure) {
        failures.add(failure);
      }
    }
    for (final destination in _splitRoutes.toList().reversed) {
      try {
        await _runRoute([
          'delete',
          destination,
          'mask',
          '128.0.0.0',
          '0.0.0.0',
          'if',
          '$_tunnelIndex',
        ]);
        _splitRoutes.remove(destination);
      } catch (failure) {
        failures.add(failure);
      }
    }
    if (_dnsFlushPending) {
      try {
        await _powershell('Clear-DnsClientCache');
        _dnsFlushPending = false;
      } catch (failure) {
        failures.add(failure);
      }
    }
    if (!_hasPendingTakeover) {
      _savedDns.clear();
      _tunnelIndex = null;
      _takeoverActive = false;
    }
    if (failures.isNotEmpty) {
      throw StateError('Tunnel release failed: ${failures.join('; ')}');
    }
  }

  /// Leaves ownership metadata in place until each checked delete succeeds.
  Future<void> disable() async {
    await releaseTunnel();
    if (!_active) return;
    _enableComplete = false;
    final route = _physicalRoute!;
    final failures = <Object>[];
    for (final ip in _addedRoutes.toList()) {
      try {
        await _runRoute([
          'delete',
          ip,
          'mask',
          '255.255.255.255',
          route.gateway,
          'if',
          '${route.interfaceIndex}',
        ]);
        _addedRoutes.remove(ip);
      } catch (failure) {
        failures.add(failure);
      }
    }
    if (failures.isNotEmpty) {
      throw StateError('Bypass cleanup failed: ${failures.join('; ')}');
    }
    _hostAddresses.clear();
    _dohEndpoints = const [];
    _physicalRoute = null;
    _active = false;
  }

  Future<void> _addBypass(String ip) async {
    final route = _physicalRoute!;
    await _runRoute([
      'add',
      ip,
      'mask',
      '255.255.255.255',
      route.gateway,
      'metric',
      '1',
      'if',
      '${route.interfaceIndex}',
    ]);
    _addedRoutes.add(ip);
  }

  Future<void> _runRoute(List<String> args) async {
    final result = await _processRun('route.exe', args);
    if (result.exitCode != 0) {
      throw StateError(
        'route.exe ${args.join(' ')} failed '
        '(${result.exitCode}): ${result.stderr} ${result.stdout}',
      );
    }
  }

  Future<String?> _resolveRealIpv4(String host) async {
    if (isIpv4Literal(host)) {
      return HevSocks5Tunnel.isFakeDnsAddress(host) ? null : host;
    }
    if (host.isEmpty || host.contains(':')) return null;
    // The /32 bypass and the address the control plane dials have to be the
    // same real one: a forged answer would route the app's own traffic to the
    // impostor and leave the genuine server inside the tunnel. Once takeover
    // began the system answer is a mapdns fake IP anyway, which is filtered
    // below; DNS-over-HTTPS is consulted first so poisoning never decides.
    if (_dohEndpoints.isNotEmpty) {
      final viaDoh = await EdgeAddressResolver.resolve(host, _dohEndpoints);
      if (viaDoh != null && !HevSocks5Tunnel.isFakeDnsAddress(viaDoh)) {
        return viaDoh;
      }
    }
    try {
      final addresses = await _lookup(host);
      for (final addr in addresses) {
        if (addr.type != InternetAddressType.IPv4) continue;
        if (HevSocks5Tunnel.isFakeDnsAddress(addr.address)) continue;
        return addr.address;
      }
    } catch (_) {
      // Resolution failure lets the caller try its separate DoH chain.
    }
    return null;
  }

  Future<_DefaultRoute?> _readDefaultRoute() async {
    final out = await _powershell(
      r'$interfaces = @(Get-NetIPInterface -AddressFamily IPv4 | '
      r"Where-Object { $_.ConnectionState -eq 'Connected' }); "
      r'$tunIndices = @(Get-NetIPAddress -AddressFamily IPv4 | '
      "Where-Object { \$_.IPAddress -eq '${HevSocks5Tunnel.tunAddress}' } | "
      r'Select-Object -ExpandProperty InterfaceIndex); '
      r"$routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 | "
      r"Where-Object { $_.NextHop -ne '0.0.0.0' -and "
      "\$_.NextHop -ne '${HevSocks5Tunnel.tunAddress}' -and "
      r'$_.InterfaceIndex -notin $tunIndices }); '
      r'$candidates = @(foreach ($r in $routes) { '
      r'$i = $interfaces | Where-Object { $_.InterfaceIndex -eq $r.InterfaceIndex } | '
      r'Select-Object -First 1; if ($i) { [PSCustomObject]@{ '
      r'NextHop = $r.NextHop; InterfaceIndex = $r.InterfaceIndex; '
      r'RouteMetric = $r.RouteMetric; InterfaceMetric = $i.InterfaceMetric } } }); '
      r'$candidates | Sort-Object { [int]$_.RouteMetric + [int]$_.InterfaceMetric } | '
      r'ForEach-Object { "{0};{1};{2};{3}" -f $_.NextHop, $_.InterfaceIndex, '
      r'$_.RouteMetric, $_.InterfaceMetric }',
    );
    _DefaultRoute? best;
    for (final line in out.split(RegExp(r'\r?\n'))) {
      if (line.trim().isEmpty) continue;
      final parts = line.trim().split(';');
      if (parts.length != 4) {
        throw StateError('Invalid physical route snapshot.');
      }
      final gateway = parts[0].trim();
      final index = int.tryParse(parts[1].trim());
      final routeMetric = int.tryParse(parts[2].trim());
      final interfaceMetric = int.tryParse(parts[3].trim());
      final firstOctet = int.tryParse(gateway.split('.').first);
      if (!isIpv4Literal(gateway) ||
          firstOctet == null ||
          firstOctet == 0 ||
          firstOctet == 127 ||
          firstOctet >= 224 ||
          gateway == HevSocks5Tunnel.tunAddress ||
          index == null ||
          index <= 0 ||
          routeMetric == null ||
          routeMetric < 0 ||
          interfaceMetric == null ||
          interfaceMetric < 0) {
        continue;
      }
      final candidate = _DefaultRoute(
        gateway,
        index,
        routeMetric + interfaceMetric,
      );
      if (best == null || candidate.metric < best.metric) best = candidate;
    }
    return best;
  }

  Future<int?> _findTunnelInterfaceIndex() async {
    final watch = Stopwatch()..start();
    do {
      final out = await _powershell(
        'Get-NetIPAddress -AddressFamily IPv4 | '
        "Where-Object { \$_.IPAddress -eq '${HevSocks5Tunnel.tunAddress}' } | "
        'Select-Object -ExpandProperty InterfaceIndex',
      );
      for (final value in out.split(RegExp(r'\s+'))) {
        final index = int.tryParse(value);
        if (index != null && index > 0) return index;
      }
      final remaining = tunnelWaitTimeout - watch.elapsed;
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(
        remaining < tunnelPollInterval ? remaining : tunnelPollInterval,
      );
    } while (watch.elapsed < tunnelWaitTimeout);
    return null;
  }

  Future<void> _captureDns(int tunIndex) async {
    final out = await _powershell(
      r'$indices = @(Get-NetIPInterface -AddressFamily IPv4 | '
      r"Where-Object { $_.ConnectionState -eq 'Connected' } | "
      r'Select-Object -ExpandProperty InterfaceIndex); '
      r'$adapters = @(Get-NetAdapter -IncludeHidden); '
      r'$indices = @($indices | Where-Object { $_ -in $adapters.InterfaceIndex }); '
      "\$indices = @((\$indices + @($tunIndex)) | Select-Object -Unique); "
      r'foreach ($index in $indices) { '
      r'$adapter = $adapters | Where-Object { $_.InterfaceIndex -eq $index } | '
      r'Select-Object -First 1; '
      r'if (!$adapter) { throw "Cannot snapshot DNS adapter $index" }; '
      r"$key = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + "
      r"([guid]$adapter.InterfaceGuid).ToString('B'); "
      r'$settings = Get-ItemProperty -LiteralPath $key; '
      r"$property = $settings.PSObject.Properties['NameServer']; "
      r"$nameServer = ''; if ($property) { $nameServer = [string]$property.Value }; "
      r"$mode = 'dhcp'; if ($nameServer.Trim()) { $mode = 'static' }; "
      r'$dns = Get-DnsClientServerAddress -InterfaceIndex $index -AddressFamily IPv4; '
      r'"{0};{1};{2}" -f $index, $mode, ($dns.ServerAddresses -join ",") }',
    );
    final snapshots = <int, _DnsSnapshot>{};
    for (final line in out.split(RegExp(r'\r?\n'))) {
      if (line.trim().isEmpty) continue;
      final parts = line.trim().split(';');
      if (parts.length != 3) throw StateError('Invalid DNS snapshot.');
      final index = int.tryParse(parts[0]);
      final mode = parts[1];
      final servers = parts[2]
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (index == null ||
          index <= 0 ||
          snapshots.containsKey(index) ||
          (mode != 'static' && mode != 'dhcp') ||
          (mode == 'static' && servers.isEmpty) ||
          servers.any((server) => !_isIpLiteral(server))) {
        throw StateError('Invalid DNS snapshot.');
      }
      snapshots[index] = _DnsSnapshot(mode == 'static', servers);
    }
    if (!snapshots.containsKey(tunIndex) ||
        !snapshots.containsKey(_physicalRoute!.interfaceIndex)) {
      throw StateError(
        'DNS snapshot is missing the physical or tunnel interface.',
      );
    }
    _savedDns.addAll(snapshots);
  }

  Future<String> _powershell(String script) async {
    final result = await _processRun('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "\$ErrorActionPreference = 'Stop'; $script",
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'PowerShell failed (${result.exitCode}): '
        '${result.stderr} ${result.stdout}',
      );
    }
    return (result.stdout as String).trim();
  }

  static bool _isIpLiteral(String value) =>
      RegExp(r'^[0-9a-fA-F:.]+$').hasMatch(value) &&
      InternetAddress.tryParse(value) != null;
}

bool isIpv4Literal(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return false;
  return parts.every(
    (part) =>
        part.isNotEmpty &&
        part.length <= 3 &&
        part.codeUnits.every((c) => c >= 48 && c <= 57) &&
        (int.tryParse(part) ?? -1) <= 255,
  );
}
