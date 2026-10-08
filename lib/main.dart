import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'core/app_version.dart';
import 'data/proxy_state_store.dart';
import 'data/settings_store.dart';
import 'data/update_checker.dart';
import 'l10n/generated/app_localizations.dart';
import 'ui/root_screen.dart';
import 'vpn/vpn_controller.dart';

/// Phone-sized window: 9:20 aspect ratio, like the Android app's screen.
const Size phoneWindowSize = Size(360, 800);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await windowManager.ensureInitialized();
  await windowManager.setSize(phoneWindowSize);
  await windowManager.setMinimumSize(phoneWindowSize);
  await windowManager.setMaximumSize(phoneWindowSize);
  await windowManager.setResizable(false);
  await windowManager.setTitle('FoxyVPN');
  await windowManager.center();

  await SettingsStore.instance.init();
  await ProxyStateStore.instance.init();
  await AppVersion.load();

  runApp(const FoxyVpnApp());
  unawaited(UpdateChecker.instance.checkOnStartup());
}

class FoxyVpnApp extends StatefulWidget {
  const FoxyVpnApp({super.key});

  @override
  State<FoxyVpnApp> createState() => _FoxyVpnAppState();
}

class _FoxyVpnAppState extends State<FoxyVpnApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // Tear the tunnel down (wintun adapter, bypass routes) before exiting.
    await VpnController.instance.shutdown();
    if (await windowManager.isPreventClose()) {
      windowManager.setPreventClose(false);
    }
    windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: SettingsStore.instance,
      builder: (context, _) {
        final themeMode = switch (SettingsStore.instance.themeMode) {
          ThemeModeSetting.system => ThemeMode.system,
          ThemeModeSetting.light => ThemeMode.light,
          ThemeModeSetting.dark => ThemeMode.dark,
        };
        final locale = switch (SettingsStore.instance.appLanguage) {
          AppLanguage.system => null,
          AppLanguage.en => const Locale('en'),
          AppLanguage.fa => const Locale('fa'),
        };
        return MaterialApp(
          title: 'FoxyVPN',
          debugShowCheckedModeBanner: false,
          themeMode: themeMode,
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFF7139),
            ),
            useMaterial3: true,
            // Vazirmatn carries Persian, Arabic and Latin glyph sets, so the
            // same family works in both locales.
            fontFamily: 'Vazirmatn',
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFF7139),
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
            fontFamily: 'Vazirmatn',
          ),
          home: const RootScreen(),
        );
      },
    );
  }
}
