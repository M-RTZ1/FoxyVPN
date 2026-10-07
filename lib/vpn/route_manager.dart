import 'dart:io';

import '../core/app_logger.dart';
import 'hev_socks5_tunnel.dart';

const String _tag = 'RouteManager';

class _DefaultRoute {
  const _DefaultRoute(this.gateway, this.interfaceIndex, this.metric);

  final String gateway;
  final int interfaceIndex;
  final int metric;
}

/// Windows equivalent of Android's `VpnService.protect()` plus the host-side
/// half of the tunnel. hev-socks5-tunnel creates the wintun adapter but does
/// NOT modify routes or DNS on Windows, so this class owns that work:
///  * installs /32 bypass routes via the physical gateway for every host the
///    app itself dials (control plane, DoH, edges, upstream proxy) so that
///    traffic never loops back into the tunnel,
///  * moves the IPv4 default route onto the wintun interface once the engine
///    is up,
///  * points system DNS at the engine's mapdns listener (or the user's custom
///    server) and restores the original routes/DNS on teardown.
///
/// Only IPv4 is taken over: the tunnel adapter has no IPv6 address, so the
/// host's IPv6 default route is left untouched.
class RouteManager {
  RouteManager._();

  static final RouteManager instance = RouteManager._();

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

  static const Duration _tunnelWaitTimeout = Duration(seconds: 10);

  final Set<String> _addedRoutes = {};
  final Map<String, String> _hostAddresses = {};
  final Map<int, List<String>> _savedDns = {};
  String? _gateway;
  _DefaultRoute? _savedDefaultRoute;
  int? _tunnelIndex;
  bool _active = false;
  bool _takeoverActive = false;

  bool get isActive => _active;
  bool get takeoverActive => _takeoverActive;

  /// Resolves control-plane (and extra) hostnames and installs host routes.
  /// Must be called BEFORE the tunnel starts, while DNS still works normally.
  Future<void> enable({List<String> extraBypassHosts = const []}) async {
    if (_active) return;
    final route = await _readDefaultRoute();
    if (route == null) {
      AppLogger.w(_tag,
          'could not determine the default gateway; control-plane traffic '
          'may be routed into the tunnel');
      _active = true;
      return;
    }
    _gateway = route.gateway;
    _savedDefaultRoute = route;

    final ips = <String>{...dohLiterals};
    for (final host in [...controlPlaneHosts, ...extraBypassHosts]) {
      final ip = await _resolveRealIpv4(host);
      if (ip == null) continue;
      ips.add(ip);
      // Remember the pre-tunnel answer: after the takeover the OS resolver
      // would only give fake IPs back for these names.
      if (!isIpv4Literal(host)) _hostAddresses[host.toLowerCase()] = ip;
    }

    for (final ip in ips) {
      if (await _addBypass(ip)) _addedRoutes.add(ip);
    }
    _active = true;
    AppLogger.i(_tag,
        'installed ${_addedRoutes.length} control-plane bypass route(s) via '
        '${route.gateway} (if ${route.interfaceIndex})');
  }

  /// Makes sure [host] (a hostname or a literal address) has a /32 bypass
  /// route and returns the real IPv4 to dial, or null when nothing usable is
  /// known. Under the tunnel the OS resolver answers with mapdns fake IPs,
  /// which are rejected here — the caller then falls back to its DoH chain.
  Future<String?> ensureBypassHost(String host) async {
    final gateway = _gateway;
    if (gateway == null) return null;
    final normalized = host.trim().toLowerCase();
    if (normalized.isEmpty) return null;

    var ip = _hostAddresses[normalized];
    ip ??= await _resolveRealIpv4(normalized);
    if (ip == null) return null;
    _hostAddresses[normalized] = ip;
    if (!_addedRoutes.contains(ip) && await _addBypass(ip)) {
      _addedRoutes.add(ip);
      AppLogger.d(_tag, 'bypassed $normalized via $ip');
    }
    return ip;
  }

  /// Points the IPv4 default route and system DNS at the tunnel. Call after
  /// the engine process is up.
  Future<void> takeoverRoutes({String? customDnsServer}) async {
    if (!_active || _takeoverActive) return;
    final saved = _savedDefaultRoute;
    if (saved == null) {
      AppLogger.w(_tag, 'cannot take over: no original default route was saved');
      return;
    }
    final tunIndex = await _findTunnelInterfaceIndex();
    if (tunIndex == null) {
      AppLogger.e(_tag,
          'the wintun adapter (${HevSocks5Tunnel.tunAddress}) never appeared; '
          'traffic will stay on the physical interface');
      return;
    }
    _tunnelIndex = tunIndex;

    await _capturePhysicalDns(tunIndex);
    final removed = await _runRoute(
        ['delete', '0.0.0.0', 'mask', '0.0.0.0', saved.gateway]);
    final added = await _runRoute([
      'add', '0.0.0.0', 'mask', '0.0.0.0', '0.0.0.0', 'metric', '1',
      'if', '$tunIndex',
    ]);
    if (!added) {
      AppLogger.e(_tag,
          'could not move the default route onto the tunnel; if the physical '
          'default route was removed, restoring it now');
      if (removed) {
        await _runRoute([
          'add', '0.0.0.0', 'mask', '0.0.0.0', saved.gateway,
          'metric', '${saved.metric}', 'if', '${saved.interfaceIndex}',
        ]);
      }
      return;
    }
    _takeoverActive = true;

    final dnsServer = customDnsServer ?? HevSocks5Tunnel.mapdnsAddress;
    await _applyDns(dnsServer);
    AppLogger.i(_tag,
        'tunnel owns the default route (if $tunIndex) and DNS ($dnsServer)');
  }

  /// Reverses [takeoverRoutes]: default route back onto the physical
  /// gateway, original DNS servers restored. Call BEFORE stopping the engine
  /// so the on-link tunnel route can still be removed cleanly.
  Future<void> releaseTunnel() async {
    if (!_takeoverActive) return;
    _takeoverActive = false;

    final saved = _savedDefaultRoute;
    if (saved != null) {
      await _runRoute([
        'delete', '0.0.0.0', 'mask', '0.0.0.0', '0.0.0.0',
        'if', '${_tunnelIndex ?? 0}',
      ]);
      await _runRoute([
        'add', '0.0.0.0', 'mask', '0.0.0.0', saved.gateway,
        'metric', '${saved.metric}', 'if', '${saved.interfaceIndex}',
      ]);
    }
    for (final entry in _savedDns.entries) {
      await _powershell(
          "Set-DnsClientServerAddress -InterfaceIndex ${entry.key} "
          "-ServerAddresses ('${entry.value.join("','")}')");
    }
    _savedDns.clear();
    AppLogger.i(_tag, 'released the route and DNS takeover');
  }

  Future<void> disable() async {
    if (!_active) return;
    await releaseTunnel();
    for (final ip in _addedRoutes) {
      await _runRoute(['delete', ip]);
    }
    AppLogger.i(_tag, 'removed ${_addedRoutes.length} bypass route(s)');
    _addedRoutes.clear();
    _hostAddresses.clear();
    _gateway = null;
    _savedDefaultRoute = null;
    _tunnelIndex = null;
    _active = false;
  }

  Future<bool> _addBypass(String ip) => _runRoute(
      ['add', ip, 'mask', '255.255.255.255', _gateway!, 'metric', '1']);

  Future<bool> _runRoute(List<String> args) async {
    try {
      final result = await Process.run('route', args, runInShell: true);
      if (result.exitCode != 0) {
        AppLogger.d(
            _tag, 'route ${args.join(' ')} failed: ${(result.stderr as String).trim()}');
        return false;
      }
      return true;
    } catch (e) {
      AppLogger.w(_tag, 'route ${args.join(' ')} failed', e);
      return false;
    }
  }

  /// Returns the first real (non mapdns-fake) IPv4 for [host]; [host] itself
  /// is returned unchanged when it is already an IPv4 literal.
  Future<String?> _resolveRealIpv4(String host) async {
    if (isIpv4Literal(host)) return host;
    if (host.contains(':')) return null;
    try {
      final addresses = await InternetAddress.lookup(host);
      for (final addr in addresses) {
        if (addr.type != InternetAddressType.IPv4) continue;
        if (HevSocks5Tunnel.isFakeDnsAddress(addr.address)) continue;
        return addr.address;
      }
      // Only fake answers: try the next resolution round before giving up.
      return null;
    } catch (e) {
      AppLogger.w(_tag, 'could not resolve $host for a bypass route', e);
      return null;
    }
  }

  Future<_DefaultRoute?> _readDefaultRoute() async {
    final out = await _powershell(
      r"$r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 "
      r"-ErrorAction SilentlyContinue | Sort-Object RouteMetric | "
      r"Select-Object -First 1; "
      r"if ($r) { '{0};{1};{2}' -f $r.NextHop, $r.InterfaceIndex, $r.RouteMetric }",
    );
    if (out == null) return null;
    final parts = out.split(';');
    if (parts.length != 3) return null;
    final gateway = parts[0].trim();
    final index = int.tryParse(parts[1].trim());
    final metric = int.tryParse(parts[2].trim());
    if (!isIpv4Literal(gateway) || index == null || metric == null) return null;
    return _DefaultRoute(gateway, index, metric);
  }

  Future<int?> _findTunnelInterfaceIndex() async {
    final deadline = DateTime.now().add(_tunnelWaitTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final out = await _powershell(
        "Get-NetIPAddress -IPAddress '${HevSocks5Tunnel.tunAddress}' "
        "-AddressFamily IPv4 -ErrorAction SilentlyContinue | "
        "Select-Object -ExpandProperty InterfaceIndex",
      );
      final index = out == null ? null : int.tryParse(out.trim().split(RegExp(r'\s+')).first);
      if (index != null) return index;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return null;
  }

  Future<void> _capturePhysicalDns(int tunIndex) async {
    final out = await _powershell(
      r'Get-DnsClientServerAddress -AddressFamily IPv4 '
      r'-ErrorAction SilentlyContinue | ForEach-Object '
      r'{ "$($_.InterfaceIndex);$(($_.DnsServerAddress -join ","))" }',
    );
    if (out == null) return;
    for (final line in out.split(RegExp(r'\r?\n'))) {
      final parts = line.trim().split(';');
      if (parts.length != 2) continue;
      final index = int.tryParse(parts[0]);
      if (index == null || index == tunIndex) continue;
      final servers =
          parts[1].split(',').where((s) => s.trim().isNotEmpty).toList();
      if (servers.isNotEmpty) _savedDns[index] = servers;
    }
  }

  Future<void> _applyDns(String server) async {
    for (final index in _savedDns.keys) {
      await _powershell('Set-DnsClientServerAddress -InterfaceIndex $index '
          "-ServerAddresses '$server'");
    }
    final tunIndex = _tunnelIndex;
    if (tunIndex != null) {
      await _powershell('Set-DnsClientServerAddress -InterfaceIndex $tunIndex '
          "-ServerAddresses '$server'");
    }
  }

  Future<String?> _powershell(String script) async {
    try {
      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-Command', script],
        runInShell: true,
      );
      if (result.exitCode != 0) {
        AppLogger.d(_tag,
            'powershell failed: ${(result.stderr as String).trim()}');
        return null;
      }
      final out = (result.stdout as String).trim();
      return out.isEmpty ? null : out;
    } catch (e) {
      AppLogger.w(_tag, 'powershell invocation failed', e);
      return null;
    }
  }
}

bool isIpv4Literal(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return false;
  return parts.every((part) =>
      part.isNotEmpty &&
      part.length <= 3 &&
      part.codeUnits.every((c) => c >= 48 && c <= 57) &&
      (int.tryParse(part) ?? -1) <= 255);
}
