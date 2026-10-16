import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:foxyvpn/vpn/upstream_trust.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Guards the failure mode that broke every edge: pubspec dropped
  // `assets/certs/`, so the bundle was missing and the E46 chain stopped
  // verifying. Network-free so it stays reliable in CI.
  test('the GlobalSign roots ship in the asset bundle', () async {
    final data = await rootBundle.load(UpstreamTrust.bundledRootsAsset);
    final pem = String.fromCharCodes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    expect(RegExp('-----BEGIN CERTIFICATE-----').allMatches(pem).length, 2,
        reason: 'expected Root R46 + Root E46');
  });
}
