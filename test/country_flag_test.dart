import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/ui/country_flag.dart';

void main() {
  test('every country in the bundled server list has a flag', () {
    final body = jsonDecode(File('assets/data/servers_fallback.json')
        .readAsStringSync()) as Map<String, dynamic>;
    final codes = <String>{};
    for (final record in body['data'] as List<dynamic>) {
      final recordMap = record as Map<String, dynamic>;
      final country =
          (recordMap['country'] as Map<String, dynamic>?) ?? recordMap;
      final code = (country['code'] as String? ?? '').toLowerCase();
      if (code.length == 2) codes.add(code);
    }
    expect(codes, isNotEmpty);
    for (final code in codes) {
      expect(bundledFlagCodes, contains(code),
          reason: '$code is in the server list but not bundled');
      expect(File('assets/flags/$code.svg').existsSync(), isTrue,
          reason: 'assets/flags/$code.svg is missing');
    }
  });

  testWidgets('a known code renders an SVG flag', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: CountryFlag(countryCode: 'de')),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsOneWidget);
  });

  testWidgets('an unknown code falls back to a readable badge', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: CountryFlag(countryCode: 'zz')),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(SvgPicture), findsNothing);
    expect(find.text('ZZ'), findsOneWidget);
  });
}
