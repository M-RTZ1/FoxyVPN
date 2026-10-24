import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/data/connection_mode_policy.dart';
import 'package:foxyvpn/data/settings_store.dart';
import 'package:foxyvpn/l10n/generated/app_localizations.dart';
import 'package:foxyvpn/ui/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.instance.init();
  });

  testWidgets('settings are grouped into cards and platform-only options '
      'are gated', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const SettingsScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('General'), findsOneWidget);

    if (ConnectionModePolicy.windowsFeaturesAvailable) {
      final trayToggle = find.text('Minimize to system tray');
      await scrollTo(tester, trayToggle);
      await tester.tap(trayToggle);
      await tester.pump();
      expect(SettingsStore.instance.minimizeToTrayEnabled, isTrue);
    } else {
      expect(find.text('Minimize to system tray'), findsNothing);
    }

    await scrollTo(tester, find.text('Connection'));
    expect(find.text('Connection'), findsOneWidget);
    if (ConnectionModePolicy.windowsFeaturesAvailable) {
      expect(find.text('System proxy'), findsOneWidget);
      expect(find.text('Tunnel'), findsOneWidget);
    } else {
      expect(find.text('System proxy'), findsNothing);
      expect(find.text('Tunnel'), findsNothing);
      expect(find.textContaining('Windows-only'), findsOneWidget);
    }

    await scrollTo(tester, find.text('DNS'));
    expect(find.text('DNS'), findsOneWidget);

    if (ConnectionModePolicy.windowsFeaturesAvailable) {
      await scrollTo(tester, find.text('Split tunneling'));
      await tester.tap(find.text('Split tunneling'));
      await tester.pumpAndSettle();
      expect(find.text('Split tunneling by destination'), findsOneWidget);
    } else {
      expect(find.text('Split tunneling'), findsNothing);
    }

    await scrollTo(tester, find.text('Upstream proxy'));
    await tester.tap(find.text('Upstream proxy'));
    await tester.pumpAndSettle();
    expect(find.text('Use an upstream proxy'), findsOneWidget);

    final advanced = find.text('Advanced');
    await scrollTo(tester, advanced);
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    if (ConnectionModePolicy.windowsFeaturesAvailable) {
      expect(find.text('Tunnel engine'), findsOneWidget);
    } else {
      expect(find.text('Tunnel engine'), findsNothing);
    }
  });
}

/// The expanded cards contain text fields, each with its own scrollable, so
/// the list has to be named explicitly.
Future<void> scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    160,
    scrollable: find.byType(Scrollable).first,
  );
  // Let any leftover momentum stop so the next tap is not swallowed as a
  // scroll gesture.
  await tester.pumpAndSettle();
}
