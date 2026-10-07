import 'package:flutter_test/flutter_test.dart';
import 'package:fluttewind/vpn/system_proxy_manager.dart';

void main() {
  group('ProxyServer registry value parsing', () {
    test('plain host:port', () {
      expect(SystemProxyManager.parseServerValue('127.0.0.1:8888'),
          ('127.0.0.1', 8888));
    });

    test('per-scheme list prefers https then http', () {
      expect(SystemProxyManager.parseServerValue('http=1.2.3.4:80;https=1.2.3.4:8080'),
          ('1.2.3.4', 8080));
      expect(SystemProxyManager.parseServerValue('http=1.2.3.4:80;ftp=1.2.3.4:21'),
          ('1.2.3.4', 80));
    });

    test('scheme-prefixed single value', () {
      expect(SystemProxyManager.parseServerValue('http://proxy.corp:3128'),
          ('proxy.corp', 3128));
    });

    test('empty or portless returns null', () {
      expect(SystemProxyManager.parseServerValue(''), isNull);
      expect(SystemProxyManager.parseServerValue('proxy.corp'), isNull);
    });
  });

  test('wininet notify seam does not throw off-platform', () {
    // On Windows this exercises the real FFI lookup; elsewhere it must
    // cleanly report false rather than crashing.
    expect(SystemProxyManager.testNotify(), anyOf(isTrue, isFalse));
  });
}
