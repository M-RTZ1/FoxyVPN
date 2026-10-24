import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/vpn/tunnel_probe.dart';

void main() {
  test('parseTrace reads the exit address and country', () {
    final parsed = TunnelProbe.parseTrace(
      'fl=123abc\nh=www.cloudflare.com\n'
      'ip=203.0.113.9\nts=123.4\nvisit_scheme=https\n'
      'uag=FoxyVPN\ncolo=MUC\nsliver=none\n'
      'http=http/2\nloc=de\ntls=TLSv1.3\n',
    );
    expect(parsed.ip, '203.0.113.9');
    expect(parsed.countryCode, 'DE');
  });

  test('parseTrace ignores malformed and unrelated lines', () {
    final parsed = TunnelProbe.parseTrace('warp=off\nloc=\nip=\n=broken\n');
    expect(parsed.ip, isNull);
    expect(parsed.countryCode, isNull);
  });

  test('proxyDirective brackets IPv6 literals', () {
    expect(TunnelProbe.proxyDirective('127.0.0.1', 21080),
        'PROXY 127.0.0.1:21080');
    expect(TunnelProbe.proxyDirective('::1', 21080), 'PROXY [::1]:21080');
  });

  test('connectHost turns a wildcard bind into a destination', () {
    expect(TunnelProbe.connectHost('0.0.0.0'), '127.0.0.1');
    expect(TunnelProbe.connectHost(''), '127.0.0.1');
    expect(TunnelProbe.connectHost('::'), '::1');
    expect(TunnelProbe.connectHost('127.0.0.1'), '127.0.0.1');
  });

  test('describeError keeps failures short', () {
    expect(TunnelProbe.describeError('x' * 400).length, 161);
    expect(TunnelProbe.describeError(StateError('boom')), contains('boom'));
  });
}
