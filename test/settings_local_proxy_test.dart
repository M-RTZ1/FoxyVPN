import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:foxyvpn/data/settings_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the endpoint notifier follows the port the user typed', () async {
    final settings = SettingsStore.instance;
    await settings.init();
    expect(settings.socksPort, SettingsStore.defaultSocksPort);
    expect(settings.localProxyEndpoint.value,
        (SettingsStore.defaultSockBindAddress, SettingsStore.defaultSocksPort));

    settings.socksPort = 28080;
    expect(settings.socksPort, 28080);
    expect(settings.localProxyEndpoint.value, ('127.0.0.1', 28080));

    settings.socksBindAddress = '0.0.0.0';
    expect(settings.localProxyEndpoint.value, ('0.0.0.0', 28080));
  });

  test('an out-of-range port is clamped into the notifier', () async {
    final settings = SettingsStore.instance;
    await settings.init();
    settings.socksPort = 70000;
    expect(settings.socksPort, 65535);
    expect(settings.localProxyEndpoint.value.$2, 65535);
  });

  test('a stored legacy port migrates once', () async {
    SharedPreferences.setMockInitialValues({'socks_port': 1080});
    final settings = SettingsStore.instance;
    await settings.init();
    expect(settings.socksPort, SettingsStore.defaultSocksPort);

    // A deliberate choice of the old port later on is respected.
    settings.socksPort = 1080;
    await SettingsStore.instance.init();
    expect(settings.socksPort, 1080);
  });
}
