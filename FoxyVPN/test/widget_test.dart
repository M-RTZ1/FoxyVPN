import 'package:flutter_test/flutter_test.dart';
import 'package:fluttewind/data/models.dart';

void main() {
  test('ProxyCandidate JSON round-trips', () {
    const candidate = ProxyCandidate(
      host: 'example.fastly.net',
      port: 443,
      countryCode: 'NL',
      countryName: 'Netherlands',
      cityCode: 'ams',
    );
    final restored = ProxyCandidate.fromJson(candidate.toJson());
    expect(restored, isNotNull);
    expect(restored!.authority, candidate.authority);
    expect(restored.cityCode, 'ams');
  });

  test('ProxyCandidate rejects incomplete JSON', () {
    expect(ProxyCandidate.fromJson({'host': '', 'port': 443}), isNull);
    expect(ProxyCandidate.fromJson({'host': 'h', 'port': 0}), isNull);
  });
}
