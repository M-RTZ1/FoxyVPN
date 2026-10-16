import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:foxyvpn/data/server_list_client.dart';
import 'package:foxyvpn/data/server_list_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The fallback only helps if it survives the build: pubspec must keep
  // listing assets/data/, and the snapshot must still parse into edges the
  // connection code can dial. Network-free so it stays reliable offline.
  test('the bundled server list parses into dialable edges', () async {
    final text = await rootBundle.loadString(bundledServerListAsset);
    final countries = ServerListClient()
        .parseCountries(jsonDecode(text) as Map<String, dynamic>);

    expect(countries, isNotEmpty);
    expect(countries.map((c) => c.name), isNot(contains('CatchAll Anycast')));
    for (final country in countries) {
      expect(
        ServerListClient.candidatesForCountry(countries, country.code),
        isNotEmpty,
        reason: '${country.code} has no dialable server',
      );
    }

    expect(
      ServerListClient.candidatesForCountry(countries, recommendedCountryCode)
          .map((c) => c.authority),
      contains('p.m1.fastly-masque.net:2499'),
    );
  });

  // A blocked resolver must not be able to leave the picker, or the connect
  // path, waiting on a request: the store answers from the snapshot alone.
  test('the store answers from the snapshot without any request', () async {
    final countries = await ServerListStore.instance.forConnect();

    expect(countries, isNotEmpty);
    expect(ServerListStore.instance.origin, ServerListOrigin.bundled);
    expect(
      ServerListClient.candidatesForCountry(
              countries, recommendedCountryCode)
          .map((c) => c.authority),
      contains('p.m1.fastly-masque.net:2499'),
    );
  });
}
