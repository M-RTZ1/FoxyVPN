// Live proof that ControlPlaneHttp's factory adds TLS correctly for direct
// https: the bypass resolver returns a literal IP, the factory dials it, and
// the TLS handshake uses the real hostname for SNI + cert validation.
//
//   dart --packages=tool/package_config_stub.json tool/verify_tls_live.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:foxyvpn/data/control_plane_http.dart';

Future<void> main() async {
  // Resolve the target ourselves (outside the app) to get a literal.
  final addresses = await InternetAddress.lookup('example.com');
  final ipv4 = addresses.firstWhere(
    (a) => a.type == InternetAddressType.IPv4,
    orElse: () => addresses.first,
  );
  stdout.writeln('resolved example.com -> ${ipv4.address}');

  final dialed = <String>[];
  final httpClient = HttpClient();
  ControlPlaneHttp.createIoClient(
    bypassResolver: (host) async {
      stdout.writeln('  resolver called for "$host"');
      return ipv4.address;
    },
    httpClient: httpClient,
    startConnect: (address, port) {
      dialed.add('${address.address}:$port');
      return Socket.startConnect(address, port);
    },
  );

  final request = await httpClient.getUrl(Uri.parse('https://example.com/'));
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();

  stdout.writeln('status=${response.statusCode}');
  stdout.writeln('dialed=$dialed');
  final preview = body.length > 60 ? body.substring(0, 60) : body;
  stdout.writeln('body starts: $preview');
  final ok = response.statusCode == 200 &&
      dialed.any((d) => d.startsWith(ipv4.address)) &&
      body.toLowerCase().contains('example');
  stdout.writeln(ok ? 'TLS-OK' : 'TLS-FAIL');
  httpClient.close(force: true);
  exitCode = ok ? 0 : 1;
}
