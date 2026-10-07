import 'dart:convert';
import 'dart:math';

import '../core/app_logger.dart';
import 'control_plane_http.dart';
import 'crypto_utils.dart';
import 'fastly_challenge_solver.dart';
import 'models.dart';
import 'token_store.dart';

const String _tag = 'FxaAuthRepository';

const String fxaAuthServer = 'https://api.accounts.firefox.com/v1';
const String firefoxClienId = '5882386c6d801776';
const String oauthScope = 'profile https://identity.mozilla.com/apps/vpn';
const String _protocolVersion = 'identity.mozilla.com/picl/v1/';
const int _pbkdf2Rounds = 1000;
const int _stretchedPwLen = 32;
const int _hkdfLen = 32;
const String _verificationMethodEmail2fa = 'email-2fa';
const int _fxaErrnoInvalidParameter = 107;
const int _fxaMaxChallengeAttempts = 5;
const int _defaultAccessTokenTtlSeconds = 24 * 60 * 60;

class FxaApiError implements Exception {
  FxaApiError(this.message, {this.errno, this.statusCode});

  final String message;
  final int? errno;
  final int? statusCode;

  @override
  String toString() => message;
}

class FxaRefreshFailure implements Exception {
  FxaRefreshFailure(this.message, {required this.permanent, this.cause});

  final String message;
  final bool permanent;
  final Object? cause;

  @override
  String toString() => message;
}

enum SessionStatus { active, needsLogin, unreachable }

class FxaAuthRepository {
  FxaAuthRepository(this.tokenStore, {FastlyChallengeSolver? challengeSolver})
      : challengeSolver =
            challengeSolver ?? FastlyChallengeSolver(ControlPlaneHttp.cookieJar);

  final TokenStore tokenStore;
  final FastlyChallengeSolver challengeSolver;

  String? _pendingSessionToken;

  /// Returns true when a two-factor code is required.
  Future<bool> startLogin(String email, String password) async {
    final data = await _loginAttempt(email, password);
    final sessionToken = data['sessionToken'] as String;
    _pendingSessionToken = sessionToken;
    final verified = data['verified'] == true;
    if (!verified) return true;
    await _completeLogin(sessionToken);
    return false;
  }

  Future<void> submitTwoFactorCode(String code) async {
    final sessionToken = _pendingSessionToken;
    if (sessionToken == null) {
      throw StateError('No pending FxA session. Start sign-in again.');
    }
    await _fxaDo('POST', '/session/verify_code',
        sessionToken: sessionToken, jsonBody: {'code': code});
    await _completeLogin(sessionToken);
  }

  Future<SessionStatus> restoreSession() async {
    final stored = await tokenStore.loadAuth();
    if (stored == null) return SessionStatus.needsLogin;
    if (stored.refreshToken == null && !tokenStore.hasValidAccessToken()) {
      await tokenStore.clear();
      return SessionStatus.needsLogin;
    }
    if (tokenStore.hasValidAccessToken()) return SessionStatus.active;

    try {
      await ensureFreshAccessToken();
      return SessionStatus.active;
    } on FxaRefreshFailure catch (failure) {
      if (failure.permanent) {
        AppLogger.w(_tag, 'FxA rejected the stored session; signing out', failure);
        await tokenStore.clear();
        return SessionStatus.needsLogin;
      }
      AppLogger.w(_tag,
          'could not renew the session right now; staying signed in', failure);
      return SessionStatus.unreachable;
    } catch (unexpected) {
      AppLogger.w(_tag, 'unexpected error while restoring the session', unexpected);
      return SessionStatus.unreachable;
    }
  }

  Future<RuntimeAuth> ensureFreshAccessToken({bool force = false}) async {
    final current = await tokenStore.loadAuth();
    if (current == null) {
      throw FxaRefreshFailure('Not signed in', permanent: true);
    }
    if (!force && tokenStore.hasValidAccessToken()) return current;

    final refreshToken = current.refreshToken;
    if (refreshToken == null) {
      throw FxaRefreshFailure(
          'The stored session has no refresh token; sign in again.',
          permanent: true);
    }

    final body = {
      'client_id': firefoxClienId,
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'scope': oauthScope,
    };

    Map<String, dynamic> tokenData;
    try {
      tokenData = await _fxaDo('POST', '/oauth/token', jsonBody: body);
    } on FxaApiError catch (rejected) {
      throw FxaRefreshFailure(
        rejected.message,
        permanent: _isPermanentRefreshRejection(rejected),
        cause: rejected,
      );
    } catch (transport) {
      throw FxaRefreshFailure(
        transport.toString(),
        permanent: false,
        cause: transport,
      );
    }

    final accessToken = tokenData['access_token'] as String?;
    if (accessToken == null || accessToken.isEmpty) {
      throw FxaRefreshFailure(
          'FxA returned no access token for the refresh grant',
          permanent: false);
    }

    final renewed = RuntimeAuth(
      accessToken: accessToken,
      refreshToken: (tokenData['refresh_token'] as String? ?? '').isNotEmpty
          ? tokenData['refresh_token'] as String
          : refreshToken,
      expiresAtEpochSeconds: _expiryFrom(tokenData),
    );
    try {
      await tokenStore.saveAuth(renewed);
    } catch (e) {
      AppLogger.w(_tag, 'could not persist the renewed token', e);
    }
    return renewed;
  }

  Future<RuntimeAuth?> refreshAccessToken() async {
    try {
      return await ensureFreshAccessToken(force: true);
    } on FxaRefreshFailure catch (failure) {
      AppLogger.w(_tag, 'access token renewal failed', failure);
      return null;
    }
  }

  bool _isPermanentRefreshRejection(FxaApiError error) =>
      error.statusCode == 400 ||
      error.statusCode == 401 ||
      error.statusCode == 403;

  int _expiryFrom(Map<String, dynamic> tokenData) {
    final expiresIn = tokenData['expires_in'] as int?;
    final ttl = (expiresIn != null && expiresIn > 0)
        ? expiresIn
        : _defaultAccessTokenTtlSeconds;
    return DateTime.now().millisecondsSinceEpoch ~/ 1000 + ttl;
  }

  Future<void> _completeLogin(String sessionToken) async {
    final tokenData = await _oauthToken(sessionToken);
    await tokenStore.saveAuth(RuntimeAuth(
      accessToken: tokenData['access_token'] as String,
      refreshToken: (tokenData['refresh_token'] as String? ?? '').isNotEmpty
          ? tokenData['refresh_token'] as String?
          : null,
      expiresAtEpochSeconds: _expiryFrom(tokenData),
    ));
    _pendingSessionToken = null;
  }

  Future<Map<String, dynamic>> _loginAttempt(String email, String password,
      {bool withVerificationMethod = true}) async {
    final body = <String, dynamic>{
      'email': email,
      'authPW': _deriveAuthPw(email, password),
      if (withVerificationMethod)
        'verificationMethod': _verificationMethodEmail2fa,
    };
    try {
      return await _fxaDo('POST', '/account/login', jsonBody: body);
    } on FxaApiError catch (e) {
      if (e.errno == _fxaErrnoInvalidParameter && withVerificationMethod) {
        return _loginAttempt(email, password, withVerificationMethod: false);
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _oauthToken(String sessionToken) {
    return _fxaDo('POST', '/oauth/token', sessionToken: sessionToken, jsonBody: {
      'client_id': firefoxClienId,
      'grant_type': 'fxa-credentials',
      'scope': oauthScope,
      'access_type': 'offline',
    });
  }

  Future<Map<String, dynamic>> _fxaDo(
    String method,
    String path, {
    String? sessionToken,
    required Map<String, dynamic> jsonBody,
  }) async {
    final url = Uri.parse('$fxaAuthServer$path');
    final bodyBytes = utf8.encode(json.encode(jsonBody));

    String? tokenId;
    List<int>? hawkKey;
    if (sessionToken != null) {
      final creds = _deriveHawkCredentials(sessionToken);
      tokenId = creds.$1;
      hawkKey = creds.$2;
    }

    Map<String, String> buildHeaders() {
      final headers = <String, String>{'Content-Type': 'application/json'};
      if (sessionToken != null) {
        headers['Authorization'] =
            _hawkHeader(method, url, tokenId!, hawkKey!, bodyBytes);
      }
      return headers;
    }

    var response = await ControlPlaneHttp.send(method, url,
        headers: buildHeaders(), body: bodyBytes);
    var attempts = 1;
    while (response.statusCode == 406 && attempts < _fxaMaxChallengeAttempts) {
      await challengeSolver.solveAndInstall();
      response = await ControlPlaneHttp.send(method, url,
          headers: buildHeaders(), body: bodyBytes);
      attempts++;
    }

    final text = response.body;
    if (response.statusCode >= 400) {
      Map<String, dynamic> errorBody = {};
      try {
        errorBody = jsonDecode(text) as Map<String, dynamic>;
      } catch (_) {}
      final errno = errorBody['errno'] as int?;
      final message = (errorBody['message'] as String?) ??
          (text.isEmpty ? 'HTTP ${response.statusCode}' : text);
      throw FxaApiError(message, errno: errno, statusCode: response.statusCode);
    }
    if (text.isEmpty) return {};
    return jsonDecode(text) as Map<String, dynamic>;
  }

  List<int> _deriveQuickStretch(String email, String password) {
    final salt = utf8.encode('${_protocolVersion}quickStretch:$email');
    return pbkdf2HmacSha256(
        utf8.encode(password), salt, _pbkdf2Rounds, _stretchedPwLen);
  }

  String _deriveAuthPw(String email, String password) {
    final quickStretched = _deriveQuickStretch(email, password);
    return bytesToHex(hkdf(quickStretched, '${_protocolVersion}authPW', _hkdfLen));
  }

  (String, List<int>) _deriveHawkCredentials(String sessionTokenHex) {
    final sessionToken = hexToBytes(sessionTokenHex);
    final expanded = hkdf(sessionToken, '${_protocolVersion}sessionToken', 64);
    return (bytesToHex(expanded.sublist(0, 32)), expanded.sublist(32, 64));
  }

  String _hawkHeader(
      String method, Uri url, String tokenId, List<int> hmacKey, List<int> body) {
    final ts = (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString();
    final random = Random.secure();
    final nonceBytes = List<int>.generate(6, (_) => random.nextInt(256));
    final nonce = base64Url.encode(nonceBytes).replaceAll('=', '');
    final path = url.path + (url.query.isNotEmpty ? '?${url.query}' : '');

    String payloadHash = '';
    if (body.isNotEmpty) {
      final digestInput = <int>[
        ...utf8.encode('hawk.1.payload\napplication/json\n'),
        ...body,
        ...utf8.encode('\n'),
      ];
      payloadHash = base64.encode(sha256Bytes(digestInput));
    }

    final normalized =
        'hawk.1.header\n$ts\n$nonce\n${method.toUpperCase()}\n$path\n'
        '${url.host}\n${url.port}\n$payloadHash\n\n';
    final macB64 = base64.encode(hmacSha256(hmacKey, utf8.encode(normalized)));

    var header = 'Hawk id="$tokenId", ts="$ts", nonce="$nonce", mac="$macB64"';
    if (payloadHash.isNotEmpty) header += ', hash="$payloadHash"';
    return header;
  }
}
