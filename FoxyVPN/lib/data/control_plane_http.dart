import 'dart:convert';
import 'dart:io' as io;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' as io_client;

const String mozillaVpnUserAgent = 'MozillaVPN/2.35.0 (sys:linux; iap:true)';

class CpResponse {
  CpResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8ListLike bodyBytes;

  String get body => utf8.decode(bodyBytes, allowMalformed: true);

  bool get isSuccessful => statusCode >= 200 && statusCode < 300;

  String? header(String name) => headers[name.toLowerCase()];
}

/// Alias so the intent is clear at call sites.
typedef Uint8ListLike = List<int>;

class SimpleCookie {
  SimpleCookie({
    required this.name,
    required this.value,
    required this.domain,
    this.expiresAtMillis,
  });

  final String name;
  final String value;
  final String domain;

  /// null == session cookie (kept for the process lifetime).
  final int? expiresAtMillis;

  bool get isExpired =>
      expiresAtMillis != null &&
      DateTime.now().millisecondsSinceEpoch > expiresAtMillis!;
}

class SimpleCookieJar {
  final Map<String, Map<String, SimpleCookie>> _byDomain = {};

  void saveFromResponse(Uri url, List<String> setCookieHeaders) {
    for (final raw in setCookieHeaders) {
      final cookie = _parse(raw, url.host);
      if (cookie == null) continue;
      final bucket = _byDomain.putIfAbsent(cookie.domain, () => {});
      bucket[cookie.name] = cookie;
    }
  }

  String? cookieHeaderFor(Uri url) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final parts = <String>[];
    for (final entry in _byDomain.entries) {
      final domain = entry.key;
      if (url.host == domain || url.host.endsWith('.$domain')) {
        for (final cookie in entry.value.values) {
          if (cookie.expiresAtMillis == null || cookie.expiresAtMillis! > now) {
            parts.add('${cookie.name}=${cookie.value}');
          }
        }
      }
    }
    return parts.isEmpty ? null : parts.join('; ');
  }

  void set(String name, String value, String domain) {
    final bucket = _byDomain.putIfAbsent(domain, () => {});
    bucket[name] = SimpleCookie(
        name: name, value: value, domain: domain);
  }

  List<SimpleCookie> snapshotAll() =>
      _byDomain.values.expand((m) => m.values).toList();

  static SimpleCookie? _parse(String raw, String requestHost) {
    final segments = raw.split(';');
    if (segments.isEmpty) return null;
    final nameValue = segments.first.trim();
    final eq = nameValue.indexOf('=');
    if (eq <= 0) return null;
    final name = nameValue.substring(0, eq).trim();
    final value = nameValue.substring(eq + 1).trim();
    if (name.isEmpty) return null;

    String domain = requestHost;
    int? expiresAt;
    for (final attr in segments.skip(1)) {
      final trimmed = attr.trim();
      final lower = trimmed.toLowerCase();
      if (lower.startsWith('domain=')) {
        var d = trimmed.substring(7).trim();
        if (d.startsWith('.')) d = d.substring(1);
        if (d.isNotEmpty) domain = d;
      } else if (lower.startsWith('max-age=')) {
        final seconds = int.tryParse(trimmed.substring(8).trim());
        if (seconds != null) {
          expiresAt =
              DateTime.now().add(Duration(seconds: seconds)).millisecondsSinceEpoch;
        }
      } else if (lower.startsWith('expires=')) {
        final date = _parseHttpDate(trimmed.substring(8).trim());
        if (date != null) expiresAt = date.millisecondsSinceEpoch;
      }
    }
    return SimpleCookie(
        name: name, value: value, domain: domain, expiresAtMillis: expiresAt);
  }

  static DateTime? _parseHttpDate(String value) {
    try {
      return HttpDate.parse(value);
    } catch (_) {
      return null;
    }
  }
}

/// Mirrors Android's `ControlPlaneHttp`: one shared client with a cookie jar
/// and the spoofed Mozilla VPN headers. Socket protection (tunnel bypass) is
/// handled on Windows by `RouteManager` host routes instead.
///
/// When the user configured an upstream chaining proxy, the whole control
/// plane (FxA, Guardian, server list, DoH) must reach the network through it
/// too, otherwise the app is useless on networks that require one. Credentials
/// are not supported here (dart:io's findProxy has no proxy auth); the
/// tunnel-side chaining in `H2UpstreamSession` does support them.
class ControlPlaneHttp {
  ControlPlaneHttp._();

  static final SimpleCookieJar cookieJar = SimpleCookieJar();
  static http.Client? _client;

  static String? _proxySignature;

  /// Point the control plane at a SOCKS5/HTTP proxy, or back to direct
  /// connections with null. Safe to call repeatedly.
  static void useProxy({
    required bool socks5,
    String host = '',
    int port = 0,
  }) {
    final signature = host.isEmpty
        ? null
        : '${socks5 ? 'socks5' : 'http'}://$host:$port';
    if (signature == _proxySignature) return;
    _proxySignature = signature;
    final old = _client;
    _client = null;
    old?.close();
  }

  static http.Client get _active {
    final existing = _client;
    if (existing != null) return existing;
    final signature = _proxySignature;
    final http.Client created;
    if (signature == null) {
      created = http.Client();
    } else {
      final uri = Uri.parse(signature);
      final scheme = uri.scheme == 'socks5' ? 'SOCKS5' : 'PROXY';
      final endpoint = '${uri.host}:${uri.port}';
      final ioClient = io.HttpClient()
        ..findProxy = (target) =>
            target.host.isEmpty ? 'DIRECT' : '$scheme $endpoint';
      created = io_client.IOClient(ioClient);
    }
    _client = created;
    return created;
  }

  static Future<CpResponse> send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
    String? contentType,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final request = http.Request(method, url);
    request.headers['User-Agent'] = mozillaVpnUserAgent;
    request.headers['Accept'] = 'application/json';
    if (contentType != null) {
      request.headers['Content-Type'] = contentType;
    }
    headers?.forEach((k, v) => request.headers[k] = v);
    final cookieHeader = cookieJar.cookieHeaderFor(url);
    if (cookieHeader != null) {
      request.headers['Cookie'] = cookieHeader;
    }
    if (body != null) {
      request.bodyBytes = body;
    }

    final streamed = await _active.send(request).timeout(timeout);
    final bytes = await streamed.stream.toBytes();
    final responseHeaders = <String, String>{};
    streamed.headers.forEach((k, v) => responseHeaders[k.toLowerCase()] = v);

    final setCookies = _extractSetCookies(streamed.headers);
    if (setCookies.isNotEmpty) {
      cookieJar.saveFromResponse(url, setCookies);
    }
    return CpResponse(
      statusCode: streamed.statusCode,
      headers: responseHeaders,
      bodyBytes: bytes,
    );
  }

  /// package:http joins duplicate headers with commas; cookie values contain
  /// commas inside Expires dates, so split only where a new `name=` begins.
  static List<String> _extractSetCookies(Map<String, String> headers) {
    final combined = headers['set-cookie'];
    if (combined == null || combined.isEmpty) return const [];
    final parts = combined.split(RegExp(r",(?=\s*[A-Za-z0-9!#$%&'*+\-.^_`|~]+=)"));
    return parts.map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
  }
}

/// Convenience for JSON bodies.
List<int> jsonBody(Object? value) => utf8.encode(jsonEncode(value));

class HttpDate {
  static DateTime parse(String value) {
    // DateTime.parse handles ISO; HTTP dates need manual handling.
    return _httpDateParse(value);
  }
}

DateTime _httpDateParse(String value) {
  // Try RFC 1123 / 1036 / asctime via DateUtil-like manual parse.
  const months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };
  final cleaned = value
      .replaceAll(RegExp(r'(Mon|Tue|Wed|Thu|Fri|Sat|Sun),?\s*'), '')
      .trim();
  // Expected: "01 Nov 2026 12:00:00 GMT"
  final match = RegExp(r'(\d{1,2})\s+(\w{3})\w*\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})')
      .firstMatch(cleaned);
  if (match == null) throw FormatException('Invalid HTTP date', value);
  final month = months[match.group(2)!.toLowerCase()];
  if (month == null) throw FormatException('Invalid HTTP date', value);
  return DateTime.utc(
    int.parse(match.group(3)!),
    month,
    int.parse(match.group(1)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6)!),
  );
}
