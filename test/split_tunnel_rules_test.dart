import 'package:foxyvpn/data/split_tunnel_rules.dart';
import 'package:flutter_test/flutter_test.dart';

SplitTunnelRule? _rule(
  String input, {
  SplitTunnelAction action = SplitTunnelAction.direct,
}) => SplitTunnelRule.parse(input, action: action);

SplitTunnelPolicy _policy(
  List<String> patterns, {
  SplitTunnelAction defaultAction = SplitTunnelAction.tunnel,
  SplitTunnelAction action = SplitTunnelAction.direct,
  bool enabled = true,
}) => SplitTunnelPolicy(
  rules: [
    for (final pattern in patterns) _rule(pattern, action: action)!,
  ],
  defaultAction: defaultAction,
  enabled: enabled,
);

void main() {
  group('pattern parsing', () {
    test('accepts the shapes people actually type', () {
      for (final input in [
        'ir',
        '.ir',
        ' .IR ',
        'example.com',
        '.example.com.',
        '*.example.com',
        'https://Example.com/path?q=1',
        '203.0.113.7',
        '192.168.0.0/16',
        'co.ir',
        'example.co.uk',
      ]) {
        final rule = _rule(input);
        expect(rule, isNotNull, reason: input);
      }
      expect(_rule('.ir')!.pattern, 'ir');
      expect(_rule('*.example.com')!.pattern, 'example.com');
      expect(_rule('https://Example.com/path')!.pattern, 'example.com');
      expect(_rule('192.168.0.0/0016')!.pattern, '192.168.0.0/16');
    });

    test('classifies domain and address patterns', () {
      expect(_rule('.ir')!.kind, SplitTunnelPatternKind.domain);
      expect(_rule('example.com')!.kind, SplitTunnelPatternKind.domain);
      expect(_rule('203.0.113.7')!.kind, SplitTunnelPatternKind.address);
      expect(_rule('192.168.0.0/16')!.kind, SplitTunnelPatternKind.address);
    });

    test('rejects anything that cannot match a flow', () {
      for (final input in <String>[
        '',
        '   ',
        'not a domain',
        'exa mple.com',
        'example..com',
        '.example-.com',
        '-example.com',
        'example-.com',
        '203.0.113.256',
        '192.168.0.0/33',
        '192.168.0.0/x',
        'http://',
        'user@example.com',
        '[2001:db8::1]',
        '2001:db8::1',
        'fe80::1/64',
        'xn'.padRight(254, 'x'),
      ]) {
        expect(_rule(input), isNull, reason: '"$input" should be rejected');
      }
    });

    test('display keeps the suffix meaning visible', () {
      expect(_rule('.ir')!.display, '.ir');
      expect(_rule('example.com')!.display, '.example.com');
      expect(_rule('192.168.0.0/16')!.display, '192.168.0.0/16');
    });
  });

  group('domain rules', () {
    test('a TLD rule matches every host under it', () {
      final policy = _policy(['.ir']);
      for (final host in ['site.ir', 'a.site.ir', 'www.google.ir', 'X.IR']) {
        expect(
          policy.decide(host)!.action,
          SplitTunnelAction.direct,
          reason: host,
        );
      }
    });

    test('a TLD rule never matches a look-alike', () {
      final policy = _policy(['.ir']);
      for (final host in [
        'notir.com',
        'iran.com',
        'site.ir.com',
        'myir',
        'example.org',
      ]) {
        expect(
          policy.decide(host)!.action,
          SplitTunnelAction.tunnel,
          reason: host,
        );
      }
    });

    test('a hostname rule covers the host and its subdomains', () {
      final policy = _policy(['example.com']);
      expect(policy.decide('example.com')!.bypassesTunnel, isTrue);
      expect(policy.decide('mail.example.com')!.bypassesTunnel, isTrue);
      expect(policy.decide('deep.sub.example.com')!.bypassesTunnel, isTrue);
      expect(policy.decide('notexample.com')!.bypassesTunnel, isFalse);
      expect(policy.decide('example.com.evil.net')!.bypassesTunnel, isFalse);
    });

    test('trailing dots and brackets are normalised before matching', () {
      final policy = _policy(['.ir']);
      expect(policy.decide('site.ir.')!.bypassesTunnel, isTrue);
      expect(policy.decide('  Site.IR  ')!.bypassesTunnel, isTrue);
      expect(policy.decide('[2001:db8::1]'), isNotNull);
    });

    test('the most specific rule wins', () {
      final policy = _policy(['.com', 'example.com'], action: SplitTunnelAction.direct);
      // Both bypass, so prove specificity through the matched rule instead.
      expect(policy.decide('other.com')!.rule!.pattern, 'com');
      expect(policy.decide('example.com')!.rule!.pattern, 'example.com');
      expect(policy.decide('a.example.com')!.rule!.pattern, 'example.com');
    });

    test('a specific tunnel rule overrides a broad bypass rule', () {
      final policy = SplitTunnelPolicy(enabled: true, rules: [
        _rule('.com', action: SplitTunnelAction.direct)!,
        _rule('bank.com', action: SplitTunnelAction.tunnel)!,
      ]);
      expect(policy.decide('shop.com')!.bypassesTunnel, isTrue);
      expect(policy.decide('bank.com')!.bypassesTunnel, isFalse);
      expect(policy.decide('pay.bank.com')!.bypassesTunnel, isFalse);
    });

    test('an equal-specificity clash resolves to the tunnel', () {
      final policy = SplitTunnelPolicy(enabled: true, rules: [
        _rule('example.com', action: SplitTunnelAction.direct)!,
        _rule('example.com', action: SplitTunnelAction.tunnel)!,
      ]);
      expect(policy.decide('example.com')!.action, SplitTunnelAction.tunnel);
    });

    test('disabled rules are ignored', () {
      final policy = SplitTunnelPolicy(enabled: true, rules: [
        SplitTunnelRule(
          pattern: 'ir',
          kind: SplitTunnelPatternKind.domain,
          action: SplitTunnelAction.direct,
          enabled: false,
        ),
      ]);
      expect(policy.enabledRuleCount, 0);
      expect(policy.decide('site.ir')!.action, SplitTunnelAction.tunnel);
    });
  });

  group('address rules', () {
    test('a CIDR rule matches inside its range only', () {
      final policy = _policy(['192.168.0.0/16']);
      for (final ip in [
        '192.168.0.1',
        '192.168.10.20',
        '192.168.255.255',
      ]) {
        expect(
          policy.decide(ip)!.action,
          SplitTunnelAction.direct,
          reason: ip,
        );
      }
      for (final ip in ['192.167.255.255', '192.169.0.1', '192.168.0.0/16']) {
        expect(
          policy.decide(ip)!.action,
          SplitTunnelAction.tunnel,
          reason: ip,
        );
      }
    });

    test('a /24 boundary is honoured', () {
      final policy = _policy(['10.3.2.0/24']);
      expect(policy.decide('10.3.2.255')!.bypassesTunnel, isTrue);
      expect(policy.decide('10.3.3.0')!.bypassesTunnel, isFalse);
    });

    test('a bare address matches only itself', () {
      final policy = _policy(['203.0.113.7']);
      expect(policy.decide('203.0.113.7')!.bypassesTunnel, isTrue);
      expect(policy.decide('203.0.113.8')!.bypassesTunnel, isFalse);
    });

    test('address rules do not apply to hostnames and the other way round', () {
      final policy = _policy(['.ir', '203.0.113.7']);
      expect(policy.decide('203.0.113.7')!.rule!.display, '203.0.113.7');
      expect(policy.decide('site.ir')!.rule!.display, '.ir');
      // A host whose name looks like a TLD is not an address.
      expect(policy.decide('dns.google')!.action, SplitTunnelAction.tunnel);
    });
  });

  group('fallback and enablement', () {
    test('unmatched traffic follows the configured default', () {
      expect(
        _policy(['.ir']).decide('example.com')!.action,
        SplitTunnelAction.tunnel,
      );
      expect(
        _policy(['.ir'], defaultAction: SplitTunnelAction.direct).decide(
          'example.com',
        )!.action,
        SplitTunnelAction.direct,
      );
    });

    test('the default decision carries no rule', () {
      final decision = _policy(['.ir']).decide('example.com')!;
      expect(decision.rule, isNull);
      expect(decision.label, 'vpn (default)');
      expect(
        _policy(['.ir'], defaultAction: SplitTunnelAction.direct)
            .decide('example.com')!
            .label,
        'bypass (default)',
      );
    });

    test('a disabled engine decides nothing', () {
      final policy = _policy(['.ir'], enabled: false);
      expect(policy.decide('site.ir'), isNull);
    });

    test('an empty target decides nothing', () {
      final policy = _policy(['.ir']);
      expect(policy.decide(''), isNull);
      expect(policy.decide('  .  '), isNull);
    });

    test('decision labels name the rule that fired', () {
      final policy = _policy(['.ir']);
      expect(policy.decide('site.ir')!.label, 'bypass .ir');
      expect(
        _policy(['.ir'], action: SplitTunnelAction.tunnel).decide('site.ir')!
            .label,
        'vpn .ir',
      );
    });
  });

  group('persistence', () {
    test('rules survive a round trip', () {
      final rules = [
        _rule('.ir')!,
        _rule('example.com', action: SplitTunnelAction.tunnel)!,
        _rule('192.168.0.0/16')!,
        SplitTunnelRule(
          pattern: 'off.ir',
          kind: SplitTunnelPatternKind.domain,
          action: SplitTunnelAction.direct,
          enabled: false,
        ),
      ];
      final decoded = SplitTunnelPolicy.decodeRules(
        SplitTunnelPolicy.encodeRules(rules),
      );
      expect(decoded, rules);
    });

    test('corrupt or hostile stored data decodes to nothing', () {
      for (final stored in [
        null,
        '',
        'not json',
        '{"p":"ir"}',
        '[]',
        '[{"p":"../etc"}]',
        '[{"p":"ir"}]',
        '[{"p":"ir","k":"domain","a":"sideways"}]',
      ]) {
        final rules = SplitTunnelPolicy.decodeRules(stored);
        if (stored == '[{"p":"ir","k":"domain","a":"sideways"}]') {
          // An unknown action must fall back to the safe one, not be dropped.
          expect(rules.single.action, SplitTunnelAction.tunnel);
          continue;
        }
        expect(rules, isEmpty, reason: '$stored');
      }
    });

    test('a policy built from decoded text behaves the same', () {
      final rules = SplitTunnelPolicy.decodeRules(
        SplitTunnelPolicy.encodeRules([_rule('.ir')!]),
      );
      final policy = SplitTunnelPolicy(enabled: true, rules: rules);
      expect(policy.decide('site.ir')!.bypassesTunnel, isTrue);
    });
  });

  group('local and special addresses', () {
    test('ranges a direct dial must never reach', () {
      for (final address in [
        '0.0.0.0',
        '127.0.0.1',
        '127.5.5.5',
        '10.1.2.3',
        '172.16.0.1',
        '172.31.255.255',
        '192.168.1.1',
        '169.254.1.1',
        '100.64.0.1',
        '100.127.255.255',
        '198.18.0.2',
        '224.0.0.5',
        '239.1.1.1',
        '255.255.255.255',
        '::',
        '::1',
        'fe80::1',
        'fc00::1',
        'ff02::1',
        '[fe80::1]',
        '::ffff:127.0.0.1',
        '::ffff:10.0.0.1',
      ]) {
        expect(
          isLocalOrSpecialAddress(address),
          isTrue,
          reason: address,
        );
      }
    });

    test('public addresses are dialable', () {
      for (final address in [
        '1.1.1.1',
        '8.8.8.8',
        '172.15.0.1',
        '172.32.0.1',
        '100.63.0.1',
        '100.128.0.1',
        '198.17.0.1',
        '203.0.113.7',
        '223.255.255.255',
        '2600:1400:2::1',
      ]) {
        expect(
          isLocalOrSpecialAddress(address),
          isFalse,
          reason: address,
        );
      }
    });

    test('hostnames are not addresses', () {
      expect(isLocalOrSpecialAddress('localhost'), isFalse);
      expect(isLocalOrSpecialAddress('site.ir'), isFalse);
    });
  });

  group('tld presets', () {
    test('every preset parses as a domain suffix', () {
      for (final tld in splitTunnelTldPresets) {
        final rule = _rule('.$tld');
        expect(rule, isNotNull, reason: tld);
        expect(rule!.kind, SplitTunnelPatternKind.domain);
        expect(rule.display, '.$tld');
      }
      expect(splitTunnelTldPresets, contains('ir'));
    });
  });
}
