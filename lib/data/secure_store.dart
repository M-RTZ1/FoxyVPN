import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/app_logger.dart';

/// OS-keyring access shared by the session token and proxy credentials.
///
/// Windows keeps the strict behavior of the original code: a failed DPAPI
/// call reaches the caller. Other platforms (notably Linux, where libsecret
/// may be missing or locked) use best-effort persistence so an unavailable
/// keyring cannot block login or connect.
class SecureStore {
  SecureStore._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    wOptions: WindowsOptions(),
  );

  static bool get _strict => Platform.isWindows;

  static Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      if (_strict) rethrow;
      AppLogger.w('SecureStore', 'could not read $key from the keyring', e);
      return null;
    }
  }

  static Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      if (_strict) rethrow;
      AppLogger.w('SecureStore', 'could not write $key to the keyring', e);
    }
  }

  static Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      if (_strict) rethrow;
      AppLogger.w('SecureStore', 'could not delete $key from the keyring', e);
    }
  }
}
