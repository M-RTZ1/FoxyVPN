// Standalone verification harness for the VPN tunnel fix.
//
// The environment cannot spawn `cmd.exe` (all named pipes busy), which breaks
// `flutter test` and the dart test runner's native-asset hook compilation.
// These libraries are pure Dart, so we exercise the real production code in a
// single process instead.
//
//   dart run tool/verify_fix.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foxyvpn/data/control_plane_http.dart';
import 'package:foxyvpn/vpn/hev_socks5_tunnel.dart';
import 'package:foxyvpn/vpn/route_manager.dart';

int _passed = 0;
int _failed = 0;

void _check(String name, bool ok, [String? detail]) {
  if (ok) {
    _passed++;
    stdout.writeln('  PASS  $name');
  } else {
    _failed++;
    stdout.writeln('  FAIL  $name${detail == null ? '' : ' — $detail'}');
  }
}

Future<void> _expectThrows(String name, Future<void> Function() body) async {
  try {
    await body();
    _check(name, false, 'expected a throw but none happened');
  } catch (_) {
    _check(name, true);
  }
}

// ---------------------------------------------------------------------------
// 1. RouteManager: a fake route.exe / powershell.exe / DNS-snapshot engine.
// ---------------------------------------------------------------------------

class _Call {
  _Call(this.executable, this.args);
  final String executable;
  final List<String> args;
  bool get isRoute => executable == 'route.exe';
  bool get isPowerShell => executable == 'powershell.exe';
  String get script =>
      isPowerShell ? (args.isNotEmpty ? args.last : '') : args.join(' ');
}

class _Runner {
  _Runner({this.defaultRouteLines, this.tunIndices = const []});

  final List<String>? defaultRouteLines;
  final List<int> tunIndices;

  final List<_Call> calls = [];
  final Set<String> failRouteAdds = {};
  final Set<String> failRouteDeletes = {};
  final Set<String> failPowerShellWhen = {};

  int _tunPoll = 0;

  Future<ProcessResult> call(String exe, List<String> args) async {
    final c = _Call(exe, args);
    calls.add(c);

    if (c.isRoute) {
      final verb = args.isNotEmpty ? args.first : '';
      final ip = args.length > 1 ? args[1] : '';
      final key = '$verb $ip';
      if (verb == 'add' && failRouteAdds.contains(ip)) {
        return ProcessResult(1, 1, '', 'route add failed for $ip');
      }
      if (verb == 'delete' && failRouteDeletes.contains(ip)) {
        return ProcessResult(1, 1, '', 'route delete failed for $ip');
      }
      if (verb == 'add' && !key.contains('0.0.0.0')) {
        // Route add must be scoped to the physical gateway + interface.
        final scoped = args.contains('if');
        if (!scoped) {
          return ProcessResult(1, 1, '', 'route add not scoped to an interface');
        }
      }
      return ProcessResult(1, 0, 'OK', '');
    }

    if (c.isPowerShell) {
      final s = c.script;
      for (final needle in failPowerShellWhen) {
        if (s.contains(needle)) {
          return ProcessResult(1, 1, '', 'powershell failed: $needle');
        }
      }
      if (s.contains('Get-NetRoute') && s.contains('0.0.0.0/0')) {
        final lines = defaultRouteLines ?? ['$_gateway;$_physicalIndex;5;5'];
        return ProcessResult(1, 0, lines.join('\n'), '');
      }
      if (s.contains('Get-NetIPAddress') && s.contains(tunAddress)) {
        final idx = _tunPoll < tunIndices.length ? tunIndices[_tunPoll] : null;
        _tunPoll++;
        return ProcessResult(1, 0, idx == null ? '' : '$idx', '');
      }
      if (s.contains('NameServer') || s.contains('Get-DnsClientServerAddress')) {
        return ProcessResult(1, 0, _defaultDns().join('\n'), '');
      }
      return ProcessResult(1, 0, '', '');
    }
    return ProcessResult(1, 0, '', '');
  }

  List<String> _defaultDns() => [
    '$_physicalIndex;dhcp;',
    '$_tunIndex;dhcp;',
  ];
}

const _gateway = '192.168.1.1';
const _physicalIndex = 7;
const _tunIndex = 42;
const tunAddress = '10.8.0.2';

RouteManager _manager(_Runner r, {Duration wait = const Duration(milliseconds: 1)}) =>
    RouteManager(
      processRun: r.call,
      lookup: (host) async => [InternetAddress('93.184.216.34')],
      tunnelWaitTimeout: wait,
      tunnelPollInterval: wait,
    );

Future<void> _testRouteManager() async {
  stdout.writeln('\nRouteManager');

  // enable() installs /32 bypasses scoped to the physical gateway+interface.
  {
    final r = _Runner();
    final m = _manager(r);
    await m.enable(extraBypassHosts: ['edge.example.test']);
    final adds = r.calls.where((c) => c.isRoute && c.args.first == 'add');
    _check('enable installs bypass routes', adds.isNotEmpty);
    _check(
      'bypass routes carry gateway + interface scope',
      adds.every((c) => c.args.contains(_gateway) && c.args.contains('$_physicalIndex')),
    );
    _check('enable marks manager active', m.isActive);
  }

  // enable() throws when there is no usable physical default route.
  {
    final r = _Runner(defaultRouteLines: []);
    final m = _manager(r);
    await _expectThrows('enable throws with no physical default route', m.enable);
    _check('failed enable leaves manager inactive', !m.isActive);
  }

  // takeoverRoutes() installs two /1 split routes and applies DNS.
  {
    final r = _Runner(tunIndices: [_tunIndex]);
    final m = _manager(r);
    await m.enable();
    await m.takeoverRoutes();
    final splitAdds = r.calls.where(
      (c) => c.isRoute && c.args.first == 'add' && c.args.contains('128.0.0.0'),
    );
    final destinations = splitAdds.map((c) => c.args[1]).toSet();
    _check(
      'takeover installs both /1 split routes',
      destinations.containsAll({'0.0.0.0', '128.0.0.0'}),
      'got $destinations',
    );
    _check(
      'split routes are scoped to the tunnel interface',
      splitAdds.every((c) => c.args.contains('$_tunIndex')),
    );
    final dnsSet = r.calls.where(
      (c) => c.isPowerShell && c.script.contains('Set-DnsClientServerAddress'),
    );
    _check('takeover applies DNS on captured interfaces', dnsSet.isNotEmpty);
    _check(
      'takeover applies the mapdns address',
      dnsSet.every((c) => c.script.contains(HevSocks5Tunnel.mapdnsAddress)),
    );
    _check('takeover reports active', m.takeoverActive);
  }

  // takeoverRoutes() must never delete the physical default route.
  {
    final r = _Runner(tunIndices: [_tunIndex]);
    final m = _manager(r);
    await m.enable();
    await m.takeoverRoutes();
    final defaultDeletes = r.calls.where(
      (c) => c.isRoute &&
          c.args.first == 'delete' &&
          c.args.length > 1 &&
          c.args[1] == '0.0.0.0' &&
          c.args.contains('255.255.255.255'),
    );
    _check(
      'physical default route is never deleted',
      defaultDeletes.isEmpty,
      'found ${defaultDeletes.length}',
    );
  }

  // takeoverRoutes() rejects a non-literal DNS server.
  {
    final r = _Runner(tunIndices: [_tunIndex]);
    final m = _manager(r);
    await m.enable();
    await _expectThrows(
      'takeover rejects a non-literal custom DNS server',
      () => m.takeoverRoutes(customDnsServer: 'not-an-ip'),
    );
  }

  // A failed split-route add rolls the whole takeover back.
  {
    final r = _Runner(tunIndices: [_tunIndex])..failRouteAdds.add('128.0.0.0');
    final m = _manager(r);
    await m.enable();
    await _expectThrows('failed split add rethrows', m.takeoverRoutes);
    _check('failed takeover releases ownership', !m.takeoverActive);
    // DNS was never applied at this point, so nothing needs restoring — but the
    // split route that DID get added must be deleted again.
    final splitRollback = r.calls.where(
      (c) => c.isRoute &&
          c.args.first == 'delete' &&
          c.args.contains('128.0.0.0') &&
          c.args.contains('$_tunIndex'),
    );
    _check(
      'failed split add removes the already-added split route',
      splitRollback.isNotEmpty,
      'found ${splitRollback.length}',
    );
    _check('failed takeover leaves no pending state', !m.takeoverActive);
  }

  // A failed DNS apply rolls back and restores the captured DNS.
  {
    // The DNS apply cmdlet fails, so takeover must restore what it changed.
    final r = _Runner(tunIndices: [_tunIndex])
      ..failPowerShellWhen.add(HevSocks5Tunnel.mapdnsAddress);
    final m = _manager(r);
    await m.enable();
    await _expectThrows('failed DNS apply rethrows', m.takeoverRoutes);
    _check('failed DNS apply releases ownership', !m.takeoverActive);
    final restores = r.calls.where(
      (c) => c.isPowerShell &&
          c.script.contains('Set-DnsClientServerAddress') &&
          (c.script.contains('-ResetServerAddresses') ||
              c.script.contains("-ServerAddresses @(")),
    );
    _check(
      'failed DNS apply restores the captured DNS',
      restores.isNotEmpty,
      'found ${restores.length}',
    );
    // The installed split routes must also be gone.
    final splitRollback = r.calls.where(
      (c) => c.isRoute && c.args.first == 'delete',
    );
    _check(
      'failed DNS apply removes the split routes',
      splitRollback.length >= 2,
      'found ${splitRollback.length}',
    );
  }

  // releaseTunnel() is retryable: a failed DNS restore keeps pending state.
  {
    final r = _Runner(tunIndices: [_tunIndex]);
    final m = _manager(r);
    await m.enable();
    await m.takeoverRoutes();
    // Make the next DNS restore fail, then succeed.
    r.failPowerShellWhen.add('-ResetServerAddresses');
    await _expectThrows('releaseTunnel throws when a restore fails', m.releaseTunnel);
    _check('failed release stays retryable', m.takeoverActive);
    r.failPowerShellWhen.clear();
    await m.releaseTunnel();
    _check('retry completes the release', !m.takeoverActive);
  }

  // disable() removes only its own bypass routes, scoped by gateway.
  {
    final r = _Runner(tunIndices: [_tunIndex]);
    final m = _manager(r);
    await m.enable(extraBypassHosts: ['edge.example.test']);
    await m.takeoverRoutes();
    await m.releaseTunnel();
    await m.disable();
    final bypassDeletes = r.calls.where(
      (c) => c.isRoute &&
          c.args.first == 'delete' &&
          c.args.contains('255.255.255.255') &&
          c.args.contains(_gateway),
    );
    _check('disable deletes bypass routes scoped by gateway', bypassDeletes.isNotEmpty);
    _check('disable leaves manager inactive', !m.isActive);
  }

  // ensureBypassHost() resolves and installs a route for an on-demand host.
  {
    final r = _Runner();
    final m = _manager(r);
    await m.enable();
    final ip = await m.ensureBypassHost('new.host.example');
    _check('ensureBypassHost returns a literal', ip == '93.184.216.34');
  }

  // ensureBypassHost() returns null when the bypass is not active.
  {
    final r = _Runner();
    final m = _manager(r);
    final ip = await m.ensureBypassHost('new.host.example');
    _check('ensureBypassHost is null before enable', ip == null);
  }

  // ensureBypassHost() refuses to hand back a synthetic (fake-IP) address.
  {
    final r = _Runner();
    final m = RouteManager(
      processRun: r.call,
      lookup: (host) async => [InternetAddress('100.64.0.9')],
      tunnelWaitTimeout: const Duration(milliseconds: 1),
      tunnelPollInterval: const Duration(milliseconds: 1),
    );
    await m.enable();
    final ip = await m.ensureBypassHost('fake.dns.example');
    _check('ensureBypassHost rejects fake-IP answers', ip == null, 'got $ip');
  }
}

// ---------------------------------------------------------------------------
// 2. ControlPlaneHttp: bypass transport semantics against a loopback server.
// ---------------------------------------------------------------------------

Future<void> _testControlPlane() async {
  stdout.writeln('\nControlPlaneHttp');

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final serverIp = server.address.address;
  final serverPort = server.port;
  final seenHosts = <String>[];
  final seenPaths = <String>[];
  final subscription = server.listen((request) async {
    seenHosts.add(request.headers.host ?? '');
    seenPaths.add(request.uri.path);
    await utf8.decoder.bind(request).join();
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'ok': true}));
    await request.response.close();
  });

  final dialedHosts = <String>[];
  final dialedAddresses = <String>[];

  // A resolver result is dialled while the logical URI host is preserved.
  {
    // Reach the real HttpClient so the connectionFactory is observable.
    final httpClient = HttpClient();
    ControlPlaneHttp.createIoClient(
      bypassResolver: (host) async {
        dialedHosts.add(host);
        return serverIp;
      },
      httpClient: httpClient,
      startConnect: (address, port) {
        dialedAddresses.add(address.address);
        return Socket.startConnect(address, port);
      },
    );
    final request = await httpClient.getUrl(
      Uri.parse('http://bypass.example.test:$serverPort/hello'),
    );
    final response = await request.close();
    await response.drain<void>();
    _check('bypassed request reaches the server', response.statusCode == 200);
    _check(
      'resolver is consulted for the logical host',
      dialedHosts.contains('bypass.example.test'),
      'saw $dialedHosts',
    );
    _check(
      'the resolver literal is the dial target',
      dialedAddresses.contains(serverIp),
      'saw $dialedAddresses',
    );
    _check(
      'the HTTP Host header keeps the logical host, not the bypass IP',
      seenHosts.any((h) => h == 'bypass.example.test' ||
          h == 'bypass.example.test:$serverPort'),
      'saw $seenHosts',
    );
    _check('the request path is preserved', seenPaths.contains('/hello'));
    httpClient.close(force: true);
  }

  // A null resolver result must throw, never fall back to system DNS.
  {
    final dialsBefore = dialedAddresses.length;
    final httpClient = HttpClient();
    ControlPlaneHttp.createIoClient(
      bypassResolver: (host) async => null,
      httpClient: httpClient,
      startConnect: (address, port) {
        dialedAddresses.add(address.address);
        return Socket.startConnect(address, port);
      },
    );
    var threw = false;
    try {
      final request = await httpClient.getUrl(
        Uri.parse('http://bypass.example.test/'),
      );
      await request.close();
    } catch (_) {
      threw = true;
    }
    _check('a resolver miss throws instead of using system DNS', threw);
    _check(
      'a resolver miss never dials',
      dialedAddresses.length == dialsBefore,
      'extra dials: ${dialedAddresses.length - dialsBefore}',
    );
    httpClient.close(force: true);
  }

  // Direct http uses the bypass dial and adds no TLS of its own.
  {
    var secureCalls = 0;
    final httpClient = HttpClient();
    ControlPlaneHttp.createIoClient(
      bypassResolver: (host) async => serverIp,
      httpClient: httpClient,
      startConnect: (address, port) => Socket.startConnect(address, port),
      secureSocket: (socket, {required String host}) {
        secureCalls++;
        return SecureSocket.secure(socket, host: host);
      },
    );
    final request = await httpClient.getUrl(
      Uri.parse('http://bypass.example.test:$serverPort/'),
    );
    final response = await request.close();
    await response.drain<void>();
    _check('direct http request succeeds', response.statusCode == 200);
    _check('direct http adds no TLS in the factory', secureCalls == 0);
    httpClient.close(force: true);
  }

  // Direct https performs the TLS handshake inside the factory, using the
  // logical host for SNI (the loopback server is not TLS, so it must fail —
  // the point is that the factory attempted the handshake at all).
  {
    var secureCalls = 0;
    String? sniHost;
    final httpClient = HttpClient();
    ControlPlaneHttp.createIoClient(
      bypassResolver: (host) async => serverIp,
      httpClient: httpClient,
      startConnect: (address, port) => Socket.startConnect(address, port),
      secureSocket: (socket, {required String host}) {
        secureCalls++;
        sniHost = host;
        return SecureSocket.secure(socket, host: host);
      },
    );
    try {
      final request = await httpClient.getUrl(
        Uri.parse('https://bypass.example.test:$serverPort/'),
      );
      await request.close();
    } catch (_) {}
    _check('direct https triggers a TLS handshake in the factory', secureCalls >= 1);
    _check(
      'direct https uses the logical host for SNI',
      sniHost == 'bypass.example.test',
      'sni=$sniHost',
    );
    httpClient.close(force: true);
  }

  // With a proxy configured, the factory dials the proxy and hands back a raw
  // socket; the TLS to the origin is the proxy client's job, not the factory's.
  {
    var secureCalls = 0;
    final proxyHosts = <String>[];
    final httpClient = HttpClient();
    ControlPlaneHttp.createIoClient(
      proxySignature: 'http://127.0.0.1:$serverPort',
      bypassResolver: (host) async {
        proxyHosts.add(host);
        return serverIp;
      },
      httpClient: httpClient,
      startConnect: (address, port) => Socket.startConnect(address, port),
      secureSocket: (socket, {required String host}) {
        secureCalls++;
        return SecureSocket.secure(socket, host: host);
      },
    );
    // The loopback "proxy" is a plain HTTP server, so a proxied https CONNECT
    // fails — but the factory must have dialled the proxy without adding TLS.
    try {
      final request = await httpClient.getUrl(
        Uri.parse('https://bypass.example.test/'),
      );
      await request.close();
    } catch (_) {}
    _check(
      'proxied https resolves and dials the proxy host',
      proxyHosts.any((h) => h == '127.0.0.1'),
      'saw $proxyHosts',
    );
    _check(
      'proxied https adds no TLS inside the factory',
      secureCalls == 0,
      'secureCalls=$secureCalls',
    );
    httpClient.close(force: true);
  }

  await subscription.cancel();
  await server.close(force: true);
}

Future<void> main() async {
  await _testRouteManager();
  await _testControlPlane();
  stdout.writeln('\n$_passed passed, $_failed failed');
  exitCode = _failed == 0 ? 0 : 1;
}
