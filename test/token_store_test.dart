import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/data/models.dart';
import 'package:foxyvpn/data/token_store.dart';

const _keyringChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    // The exact failure seen under WSL: libsecret is present but its keyring
    // cannot be unlocked.
    messenger.setMockMethodCallHandler(_keyringChannel, (call) async {
      throw PlatformException(
        code: 'Libsecret error',
        message: 'Failed to unlock the keyring',
      );
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_keyringChannel, null);
  });

  // Windows keeps the original strict behavior: DPAPI is expected to be there,
  // so a keyring failure still reaches the caller. Only the degraded
  // non-Windows path is exercised here.
  test('a locked keyring keeps the session usable for this run', () async {
    final auth = RuntimeAuth(
      accessToken: 'access',
      refreshToken: 'refresh',
      expiresAtEpochSeconds:
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
    );

    await expectLater(TokenStore.instance.saveAuth(auth), completes);
    expect(TokenStore.instance.hasValidAccessToken(), isTrue);
    expect((await TokenStore.instance.loadAuth())?.accessToken, 'access');

    await expectLater(TokenStore.instance.clear(), completes);
    expect(TokenStore.instance.hasValidAccessToken(), isFalse);
    expect(await TokenStore.instance.loadAuth(), isNull);
  }, skip: Platform.isWindows);
}
