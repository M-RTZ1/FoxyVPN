// Live proof of the full Windows connect path on a network whose resolver is
// broken: resolve the edge over DNS-over-HTTPS, dial that address, and finish
// TLS with the real hostname for SNI + validation and the bundled roots.
//
//   dart --packages=tool/package_config_stub.json tool/verify_edge_doh_live.dart
import 'dart:io';

import 'package:foxyvpn/vpn/edge_address_resolver.dart';

const List<String> edges = [
  'p.m1.fastly-masque.net',
  'muc139.m1.fastly-masque.net',
  'faor73.m1.fastly-masque.net',
];

Future<void> main() async {
  final context = SecurityContext(withTrustedRoots: true)
    ..setTrustedCertificatesBytes(
        File('assets/certs/globalsign_roots.pem').readAsBytesSync());

  var connected = 0;
  for (final host in edges) {
    final ip =
        await EdgeAddressResolver.resolve(host, ['1.1.1.1', '8.8.8.8', '9.9.9.9']);
    stdout.write('$host -> ${ip ?? 'no DoH answer'}: ');
    if (ip == null) {
      stdout.writeln('SKIP');
      continue;
    }
    Socket? raw;
    try {
      raw = await Socket.connect(ip, 2499, timeout: const Duration(seconds: 8));
      final secure = await SecureSocket.secure(
        raw,
        host: host,
        context: context,
        supportedProtocols: const ['h2'],
      ).timeout(const Duration(seconds: 8));
      stdout.writeln('TLS-OK alpn=${secure.selectedProtocol}');
      secure.destroy();
      connected++;
    } catch (e) {
      stdout.writeln('FAIL ${e.toString().split('\n').first}');
    } finally {
      raw?.destroy();
    }
  }
  stdout.writeln('edges up: $connected/${edges.length}');
  exitCode = connected == 0 ? 1 : 0;
}
