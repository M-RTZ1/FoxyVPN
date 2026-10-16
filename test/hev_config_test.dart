import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/vpn/hev_socks5_tunnel.dart';

Future<String> _write(int socksPort, String? customDns) async {
  final dir = await Directory.systemTemp.createTemp('hev_config_test');
  return HevSocks5Tunnel.writeConfig(dir, socksPort, customDns);
}

Future<String> _yaml(String path) => File(path).readAsString();

void main() {
  test('the tunnel section names the wintun adapter', () async {
    // Without a name, hev-socks5-tunnel crashes with an access violation
    // (0xC0000005) instead of bringing the adapter up.
    final config = await _yaml(await _write(21080, null));
    final tunnel = config.split('socks5:').first;
    expect(tunnel, contains("name: '${HevSocks5Tunnel.tunName}'"));
    expect(tunnel, contains('mtu: ${HevSocks5Tunnel.tunMtu}'));
    expect(tunnel, contains("ipv4: '${HevSocks5Tunnel.tunAddress}'"));
  });

  test('the socks port and the mapdns block follow the arguments', () async {
    final withMapdns = await _yaml(await _write(21080, null));
    expect(withMapdns, contains('port: 21080'));
    expect(withMapdns, contains("address: '${HevSocks5Tunnel.mapdnsAddress}'"));

    final customDns = await _yaml(await _write(21081, '9.9.9.9'));
    expect(customDns, contains('port: 21081'));
    expect(customDns, isNot(contains('mapdns:')));
  });

  test('a fake DNS address is recognised by its 100.64.0.0/10 range', () {
    expect(HevSocks5Tunnel.isFakeDnsAddress('100.64.0.1'), isTrue);
    expect(HevSocks5Tunnel.isFakeDnsAddress('100.127.255.254'), isTrue);
    expect(HevSocks5Tunnel.isFakeDnsAddress('100.128.0.1'), isFalse);
    expect(HevSocks5Tunnel.isFakeDnsAddress('example.com'), isFalse);
  });
}
