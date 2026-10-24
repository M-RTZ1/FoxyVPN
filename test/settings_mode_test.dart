import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/data/connection_mode_policy.dart';
import 'package:foxyvpn/data/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('the default mode is the one the platform implements', () async {
    SharedPreferences.setMockInitialValues({});
    await SettingsStore.instance.init();
    expect(
      SettingsStore.instance.connectionMode,
      ConnectionModePolicy.windowsFeaturesAvailable
          ? ConnectionMode.tunnel
          : ConnectionMode.proxy,
    );
  });

  test('a stored Windows-only mode falls back to proxy elsewhere', () async {
    SharedPreferences.setMockInitialValues({
      'connection_mode': ConnectionMode.tunnel.name,
      'connection_mode_migrated': true,
    });
    await SettingsStore.instance.init();
    expect(
      SettingsStore.instance.connectionMode,
      ConnectionModePolicy.windowsFeaturesAvailable
          ? ConnectionMode.tunnel
          : ConnectionMode.proxy,
    );
  });
}
