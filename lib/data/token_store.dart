import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/app_logger.dart';
import 'models.dart';

const String _tag = 'TokenStore';

/// Encrypted-at-rest token storage (DPAPI on Windows via flutter_secure_storage).
class TokenStore {
  TokenStore._();

  static final TokenStore instance = TokenStore._();

  static const String _keyAuth = 'foxyvpn_auth';
  static const int _clockSkewToleranceSeconds = 60;

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    wOptions: WindowsOptions(),
  );

  RuntimeAuth? _cached;

  Future<void> saveAuth(RuntimeAuth auth) async {
    _cached = auth;
    await _storage.write(
      key: _keyAuth,
      value: jsonEncode({
        'access_token': auth.accessToken,
        'refresh_token': auth.refreshToken,
        'expires_at': auth.expiresAtEpochSeconds,
      }),
    );
  }

  Future<RuntimeAuth?> loadAuth() async {
    if (_cached != null) return _cached;
    try {
      final raw = await _storage.read(key: _keyAuth);
      if (raw == null || raw.isEmpty) return null;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final access = json['access_token'] as String?;
      if (access == null || access.isEmpty) return null;
      final refresh = json['refresh_token'] as String?;
      final expiresAt = json['expires_at'] as int? ?? 0;
      final auth = RuntimeAuth(
        accessToken: access,
        refreshToken: (refresh != null && refresh.isNotEmpty) ? refresh : null,
        expiresAtEpochSeconds: expiresAt,
      );
      _cached = auth;
      return auth;
    } catch (e) {
      AppLogger.w(_tag, 'could not read the stored session', e);
      return null;
    }
  }

  bool hasValidAccessToken() {
    final auth = _cached;
    if (auth == null) return false;
    if (auth.expiresAtEpochSeconds <= 0) return false;
    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return auth.expiresAtEpochSeconds - nowSeconds > _clockSkewToleranceSeconds;
  }

  /// Must be called after loadAuth() to populate the synchronous cache.
  Future<bool> hasStoredSession() async => (await loadAuth()) != null;

  Future<void> clear() async {
    _cached = null;
    await _storage.delete(key: _keyAuth);
  }
}
