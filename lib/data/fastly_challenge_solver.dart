import 'dart:convert';

import 'control_plane_http.dart';
import 'crypto_utils.dart';

class FastlyChallengeError implements Exception {
  FastlyChallengeError(this.message);

  final String message;

  @override
  String toString() => message;
}

class _NoChallengePage implements Exception {}

const String _solverUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0 Safari/537.36';

const String _powAlphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

const String _htmlAccept =
    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';

final RegExp _challengePrefixRegex = RegExp(r'/_fs-ch-[A-Za-z0-9]+');
final RegExp _initCallRegex =
    RegExp(r'init\((\[[^\]]*\]),\s*"([^"]+)",\s*"([^"]+)"');

/// Headless solver for Fastly's "Client Challenge" bot pages (HTTP 406).
/// Faithful port of the Android `FastlyChallengeSolver`.
class FastlyChallengeSolver {
  FastlyChallengeSolver(this.cookieJar);

  final SimpleCookieJar cookieJar;

  static const _solveTimeout = Duration(seconds: 60);
  static const int _maxPostBackRounds = 3;

  Future<void> solveAndInstall() async {
    FastlyChallengeError? lastError;
    for (final base in [
      'https://api.accounts.firefox.com',
      'https://accounts.firefox.com',
    ]) {
      try {
        await _solveOnHost(base);
        return;
      } on _NoChallengePage {
        continue;
      } on FastlyChallengeError catch (e) {
        lastError = e;
      }
    }
    throw lastError ??
        FastlyChallengeError('host did not serve a Fastly challenge page');
  }

  Future<void> _solveOnHost(String base) async {
    final solverJar = SimpleCookieJar();
    final pageUrl = Uri.parse('$base/');
    final page = await _fetchText(solverJar, pageUrl);
    if (!page.contains('/_fs-ch-') || !page.contains('Client Challenge')) {
      throw _NoChallengePage();
    }

    final prefixMatch = _challengePrefixRegex.firstMatch(page);
    if (prefixMatch == null) {
      throw FastlyChallengeError('challenge asset prefix not found on $base');
    }
    final prefixUrl = base + prefixMatch.group(0)!;
    final baseOrigin = _baseOrigin(prefixUrl);

    final script = await _fetchText(
        solverJar, Uri.parse('$prefixUrl/script.js?reload=true'));
    var parsed = _parseChallengeInit(script);
    var challenges = parsed.$1;
    var token = parsed.$2;

    for (var round = 0; round < _maxPostBackRounds; round++) {
      final answers = <Map<String, dynamic>>[];
      for (final challenge in challenges) {
        answers.add(await _answerChallenge(
            solverJar, prefixUrl, baseOrigin, token, challenge));
      }
      final postBody = jsonEncode({'token': token, 'data': answers});
      final response = await ControlPlaneHttp.send(
        'POST',
        Uri.parse('$prefixUrl/fst-post-back'),
        headers: {
          'Accept': 'application/json',
          'User-Agent': _solverUserAgent,
          'Origin': baseOrigin,
          if (solverJar.cookieHeaderFor(Uri.parse(prefixUrl)) != null)
            'Cookie': solverJar.cookieHeaderFor(Uri.parse(prefixUrl))!,
        },
        body: utf8.encode(postBody),
        contentType: 'application/json',
        timeout: _solveTimeout,
      );
      _absorbCookies(solverJar, response, Uri.parse(prefixUrl));
      if (!response.isSuccessful) {
        throw FastlyChallengeError(
            'challenge post-back returned HTTP ${response.statusCode}');
      }
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['status'] == 'success') {
        final verifyPage = await _fetchText(solverJar, pageUrl);
        if (verifyPage.contains('/_fs-ch-') &&
            verifyPage.contains('Client Challenge')) {
          throw FastlyChallengeError(
              'challenge cookie not accepted on this exit IP');
        }
        _installChallengeCookies(solverJar);
        return;
      }
      final nextChallenges = body['ch'] as List<dynamic>?;
      final nextToken = body['tok'] as String? ?? '';
      if (nextChallenges == null ||
          nextChallenges.isEmpty ||
          nextToken.isEmpty) {
        throw FastlyChallengeError('unexpected post-back response: $body');
      }
      challenges = nextChallenges.cast<Map<String, dynamic>>();
      token = nextToken;
    }
    throw FastlyChallengeError(
        'Fastly challenge did not complete within $_maxPostBackRounds rounds');
  }

  String _baseOrigin(String prefixUrl) {
    final idx = prefixUrl.indexOf('/_fs-ch-');
    return idx > 0 ? prefixUrl.substring(0, idx) : prefixUrl;
  }

  Future<String> _fetchText(SimpleCookieJar jar, Uri url,
      [String accept = _htmlAccept]) async {
    final cookieHeader = jar.cookieHeaderFor(url);
    final response = await ControlPlaneHttp.send('GET', url, headers: {
      'User-Agent': _solverUserAgent,
      'Accept': accept,
      'Cookie': ?cookieHeader,
    }, timeout: _solveTimeout);
    _absorbCookies(jar, response, url);
    if (!response.isSuccessful) {
      throw FastlyChallengeError(
          'GET $url returned HTTP ${response.statusCode}');
    }
    return response.body;
  }

  void _absorbCookies(SimpleCookieJar jar, CpResponse response, Uri url) {
    final setCookie = response.header('set-cookie');
    if (setCookie != null && setCookie.isNotEmpty) {
      jar.saveFromResponse(url, [setCookie]);
    }
  }

  (List<Map<String, dynamic>>, String) _parseChallengeInit(String script) {
    final matches = _initCallRegex.allMatches(script).toList();
    if (matches.isEmpty) {
      throw FastlyChallengeError('challenge init() call not found in script');
    }
    final last = matches.last;
    final List<dynamic> challenges;
    try {
      challenges = jsonDecode(last.group(1)!) as List<dynamic>;
    } catch (e) {
      throw FastlyChallengeError('could not parse challenge list: $e');
    }
    if (challenges.isEmpty) throw FastlyChallengeError('empty challenge list');
    return (challenges.cast<Map<String, dynamic>>(), last.group(2)!);
  }

  Future<String> _fetchPat(
      SimpleCookieJar jar, String prefixUrl, String baseOrigin, String token) async {
    final patUrl = Uri.parse(
        '$prefixUrl/pat?token=${Uri.encodeComponent(token)}');
    final cookieHeader = jar.cookieHeaderFor(patUrl);
    final response = await ControlPlaneHttp.send('POST', patUrl, headers: {
      'Accept': 'text/plain',
      'User-Agent': _solverUserAgent,
      'Origin': baseOrigin,
      'Cookie': ?cookieHeader,
    }, timeout: _solveTimeout);
    _absorbCookies(jar, response, patUrl);
    if (response.statusCode == 400 || response.statusCode == 401) return '';
    if (!response.isSuccessful) {
      throw FastlyChallengeError(
          'PAT request returned HTTP ${response.statusCode}');
    }
    Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      throw FastlyChallengeError('could not parse PAT response: $e');
    }
    final auth = json['auth'] as String? ?? '';
    if (auth.isEmpty) throw FastlyChallengeError('empty PAT auth token');
    return auth;
  }

  Map<String, dynamic> _clientMetricsAnswer() => {
        'ty': 'clientmetrics',
        'webdriver': false,
        'bot_detection_result': {
          'bot_detected': false,
          'bot_kind': null,
        },
        'browser_metrics': {
          'client_data': '{}',
          'error_trace': null,
        },
        'detector_results': <String, dynamic>{},
        'v': 2,
      };

  Future<Map<String, dynamic>> _answerChallenge(
    SimpleCookieJar jar,
    String prefixUrl,
    String baseOrigin,
    String token,
    Map<String, dynamic> challenge,
  ) async {
    final data = (challenge['data'] as Map<String, dynamic>?) ?? {};
    switch (challenge['ty'] as String? ?? '') {
      case 'pow':
        final base = data['base'] as String? ?? '';
        final answer = _solvePow(base, data['hash'] as String? ?? '');
        if (answer == null) {
          throw FastlyChallengeError(
              'no proof-of-work solution found for base $base');
        }
        return {
          'ty': 'pow',
          'base': base,
          'answer': answer,
          'hmac': data['hmac'] ?? '',
          'expires': data['expires'] ?? '',
        };
      case 'pat':
        return {'ty': 'pat', 'auth': await _fetchPat(jar, prefixUrl, baseOrigin, token)};
      case 'clientmetrics':
        return _clientMetricsAnswer();
      default:
        throw FastlyChallengeError(
            "unsupported Fastly challenge type '${challenge['ty']}' "
            '(captcha cannot be solved automatically)');
    }
  }

  String? _solvePow(String base, String targetHex) {
    List<int> target;
    try {
      target = hexToBytes(targetHex);
    } catch (_) {
      return null;
    }
    if (target.length != 32) return null;
    for (final a in _powAlphabet.codeUnits) {
      for (final b in _powAlphabet.codeUnits) {
        final suffix = String.fromCharCodes([a, b]);
        final hash = sha256Bytes(utf8.encode(base + suffix));
        if (_equals(hash, target)) return suffix;
      }
    }
    return null;
  }

  static bool _equals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _installChallengeCookies(SimpleCookieJar solverJar) {
    final cookies = solverJar.snapshotAll();
    if (cookies.isEmpty) {
      throw FastlyChallengeError('challenge completed but no cookies were issued');
    }
    for (final cookie in cookies) {
      cookieJar.set(cookie.name, cookie.value, 'firefox.com');
    }
  }
}
