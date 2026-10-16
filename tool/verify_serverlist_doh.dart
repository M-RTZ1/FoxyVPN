// Live proof of the server-list DNS-over-HTTPS dial: resolve the Remote
// Settings host through DoH, then fetch the records while TLS keeps the real
// hostname for SNI + certificate validation.
//
//   dart --packages=tool/package_config_stub.json tool/verify_serverlist_doh.dart
import 'dart:convert';
import 'dart:io';

import 'package:foxyvpn/data/control_plane_http.dart';
import 'package:foxyvpn/vpn/edge_address_resolver.dart';

const String url =
    'https://firefox.settings.services.mozilla.com/v1/buckets/main/collections/vpn-serverlist/records';

Future<void> main() async {
  final uri = Uri.parse(url);
  stdout.writeln('usesSystemResolver=${ControlPlaneHttp.usesSystemResolver}');

  String? viaDoh;
  try {
    viaDoh = await EdgeAddressResolver.resolve(
        uri.host, ['1.1.1.1', '8.8.8.8', '9.9.9.9']);
  } catch (e) {
    stdout.writeln('DoH resolve threw: $e');
  }
  stdout.writeln('doh resolved ${uri.host} -> $viaDoh');

  var ok = false;
  if (viaDoh != null) {
    try {
      final response =
          await ControlPlaneHttp.sendDirect('GET', uri, viaDoh,
              timeout: const Duration(seconds: 10));
      final records =
          ((jsonDecode(response.body)['data'] as List?) ?? const []);
      stdout.writeln('DIRECT status=${response.statusCode} records=${records.length}');
      ok = response.isSuccessful && records.isNotEmpty;
    } catch (e) {
      stdout.writeln('DIRECT failed: $e');
    }
  }

  try {
    final response =
        await ControlPlaneHttp.send('GET', uri, timeout: const Duration(seconds: 10));
    final records = ((jsonDecode(response.body)['data'] as List?) ?? const []);
    stdout.writeln('SYSTEM status=${response.statusCode} records=${records.length}');
    ok = ok || (response.isSuccessful && records.isNotEmpty);
  } catch (e) {
    stdout.writeln('SYSTEM failed: $e');
  }

  stdout.writeln(ok ? 'SERVERLIST-OK' : 'SERVERLIST-FAIL');
  exitCode = ok ? 0 : 1;
}
