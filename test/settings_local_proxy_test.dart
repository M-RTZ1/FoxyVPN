import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:foxyvpn/data/settings_store.dart';
import 'package:foxyvpn/data/split_tunnel_rules.dart';

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

  group('split tunneling settings', () {
    test('starts disabled with a tunnel-safe default', () async {
      final settings = SettingsStore.instance;
      await settings.init();
      expect(settings.splitTunnelEnabled, isFalse);
      expect(settings.splitTunnelPolicy(), isNull);
      expect(settings.splitTunnelDefaultAction, SplitTunnelAction.tunnel);
      expect(settings.splitTunnelRules, isEmpty);
    });

    test('enabling publishes the rules to the live policy', () async {
      final settings = SettingsStore.instance;
      await settings.init();
      settings.splitTunnelRules = [
        SplitTunnelRule.parse('.ir', action: SplitTunnelAction.direct)!,
        SplitTunnelRule.parse('bank.com', action: SplitTunnelAction.tunnel)!,
      ];
      settings.splitTunnelEnabled = true;

      final policy = settings.splitTunnelPolicy()!;
      expect(policy.enabledRuleCount, 2);
      expect(policy.decide('site.ir')!.bypassesTunnel, isTrue);
      expect(policy.decide('bank.com')!.bypassesTunnel, isFalse);
      expect(policy.decide('example.com')!.action, SplitTunnelAction.tunnel);

      settings.splitTunnelDefaultAction = SplitTunnelAction.direct;
      expect(
        settings.splitTunnelPolicy()!.decide('example.com')!.bypassesTunnel,
        isTrue,
      );

      settings.splitTunnelEnabled = false;
      expect(settings.splitTunnelPolicy(), isNull);
    });

    test('rules survive a reload of the stored settings', () async {
      final settings = SettingsStore.instance;
      await settings.init();
      settings.splitTunnelRules = [
        SplitTunnelRule.parse('192.168.0.0/16', action: SplitTunnelAction.direct)!,
      ];
      await SettingsStore.instance.init();
      final restored = SettingsStore.instance.splitTunnelRules;
      expect(restored.single.pattern, '192.168.0.0/16');
      expect(restored.single.action, SplitTunnelAction.direct);
    });

    test('the policy is memoised until the rules actually change', () async {
      final settings = SettingsStore.instance;
      await settings.init();
      settings.splitTunnelEnabled = true;
      settings.splitTunnelRules = [
        SplitTunnelRule.parse('.ir', action: SplitTunnelAction.direct)!,
      ];

      final first = settings.splitTunnelPolicy();
      expect(identical(first, settings.splitTunnelPolicy()), isTrue);

      settings.splitTunnelRules = [
        ...settings.splitTunnelRules,
        SplitTunnelRule.parse('.net', action: SplitTunnelAction.direct)!,
      ];
      final second = settings.splitTunnelPolicy();
      expect(identical(first, second), isFalse);
      expect(second!.decide('site.net')!.bypassesTunnel, isTrue);
    });

    test('pattern validation matches the engine', () {
      expect(SettingsStore.isValidSplitTunnelPattern('.ir'), isTrue);
      expect(SettingsStore.isValidSplitTunnelPattern('203.0.113.7'), isTrue);
      expect(SettingsStore.isValidSplitTunnelPattern('not a domain'), isFalse);
      expect(SettingsStore.isValidSplitTunnelPattern(''), isFalse);
    });
  });
}
