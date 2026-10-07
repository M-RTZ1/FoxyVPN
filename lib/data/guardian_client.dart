import 'dart:convert';

import 'control_plane_http.dart';
import 'fastly_challenge_solver.dart';
import 'models.dart';

const String guardianEndpointDefault = 'https://vpn.mozilla.org';

class GuardianHttpError implements Exception {
  GuardianHttpError(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class QuotaExceededError implements Exception {
  QuotaExceededError(this.message);

  final String message;

  @override
  String toString() => message;
}

class TokenInvalidError implements Exception {
  TokenInvalidError(this.message);

  final String message;

  @override
  String toString() => message;
}

class ProxyPass {
  const ProxyPass({
    required this.token,
    this.expiresAtEpochSeconds,
    this.quotaMax,
    this.quotaRemaining,
    this.quotaReset,
  });

  final String token;
  final int? expiresAtEpochSeconds;
  final int? quotaMax;
  final int? quotaRemaining;
  final int? quotaReset;
}

class GuardianClient {
  GuardianClient({FastlyChallengeSolver? challengeSolver})
      : challengeSolver =
            challengeSolver ?? FastlyChallengeSolver(ControlPlaneHttp.cookieJar);

  final FastlyChallengeSolver challengeSolver;

  Future<ProxyPass> fetchProxyPass(String endpoint, String accessToken) async {
    final url = Uri.parse('${_trimEnd(endpoint)}/api/v1/fpn/token');
    final resp = await _authorizedRequest('GET', url, accessToken);
    switch (resp.statusCode) {
      case 401:
      case 403:
        throw TokenInvalidError('access token was rejected by Guardian');
      case 429:
        throw QuotaExceededError('account proxy quota exceeded');
    }
    final text = resp.body;
    if (resp.statusCode != 200) {
      throw GuardianHttpError(
          'failed to fetch proxy pass: HTTP ${resp.statusCode}: '
          '${text.substring(0, text.length.clamp(0, 2048))}',
          statusCode: resp.statusCode);
    }
    final body = jsonDecode(text) as Map<String, dynamic>;
    final token = body['token'] as String? ?? '';
    if (token.isEmpty) {
      throw GuardianHttpError('proxy pass response did not contain a token');
    }
    final expiresAt = body['expires_at'] as int?;
    return ProxyPass(
      token: token,
      expiresAtEpochSeconds:
          (expiresAt != null && expiresAt > 0) ? expiresAt : jwtExpiryEpochSeconds(token),
      quotaMax: int.tryParse(resp.header('x-quota-limit') ?? ''),
      quotaRemaining: int.tryParse(resp.header('x-quota-remaining') ?? ''),
      quotaReset: int.tryParse(resp.header('x-quota-reset') ?? ''),
    );
  }

  Future<Entitlement> fetchUserInfo(String endpoint, String accessToken) async {
    final url = Uri.parse('${_trimEnd(endpoint)}/api/v1/fpn/status');
    final resp = await _authorizedRequest('GET', url, accessToken);
    final text = resp.body;
    if (resp.statusCode != 200) {
      throw GuardianHttpError(
          'failed to fetch account info: HTTP ${resp.statusCode}: '
          '${text.substring(0, text.length.clamp(0, 2048))}',
          statusCode: resp.statusCode);
    }
    final entitlement =
        _parseEntitlement(jsonDecode(text) as Map<String, dynamic>);

    if (entitlement.limitedBandwidth) {
      try {
        final pass = await fetchProxyPass(endpoint, accessToken);
        return entitlement.copyWith(
            quotaRemaining: pass.quotaRemaining ?? entitlement.quotaRemaining);
      } catch (_) {
        return entitlement;
      }
    }
    return entitlement;
  }

  Future<Entitlement> activateGuardian(String endpoint, String accessToken) async {
    final url = Uri.parse('${_trimEnd(endpoint)}/api/v1/fpn/activate');
    final resp = await _authorizedRequest('POST', url, accessToken);
    final text = resp.body;
    if (resp.statusCode != 200) {
      throw GuardianHttpError(
          'failed to activate guardian entitlement: HTTP ${resp.statusCode}: '
          '${text.substring(0, text.length.clamp(0, 2048))}',
          statusCode: resp.statusCode);
    }
    return _parseEntitlement(jsonDecode(text) as Map<String, dynamic>);
  }

  Entitlement _parseEntitlement(Map<String, dynamic> body) {
    final maxBytes = body['maxBytes'];
    return Entitlement(
      subscribed: body['subscribed'] == true,
      uid: body['uid'] as String? ?? '',
      maxBytes: (maxBytes is int && maxBytes >= 0) ? maxBytes : null,
      limitedBandwidth: body['limited_bandwidth'] == true,
    );
  }

  Future<CpResponse> _authorizedRequest(
      String method, Uri url, String accessToken) async {
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $accessToken',
    };
    var response = await ControlPlaneHttp.send(method, url,
        headers: headers, body: method == 'POST' ? const [] : null);
    if (response.statusCode == 406) {
      await challengeSolver.solveAndInstall();
      response = await ControlPlaneHttp.send(method, url,
          headers: headers, body: method == 'POST' ? const [] : null);
    }
    return response;
  }

  static String _trimEnd(String endpoint) =>
      endpoint.endsWith('/') ? endpoint.substring(0, endpoint.length - 1) : endpoint;
}

int? jwtExpiryEpochSeconds(String token) {
  final parts = token.split('.');
  if (parts.length < 2) return null;
  try {
    var b64 = parts[1];
    while (b64.length % 4 != 0) {
      b64 += '=';
    }
    final payload =
        utf8.decode(base64Url.decode(b64.replaceAll('-', '+').replaceAll('_', '/')));
    final json = jsonDecode(payload) as Map<String, dynamic>;
    final exp = json['exp'];
    if (exp is int && exp > 0) return exp;
  } catch (_) {}
  return null;
}
