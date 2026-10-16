import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

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

  /// Ceiling for establishing one connection, TLS handshake included. A
  /// healthy one is up in well under a second, so this only decides how long
  /// an attempt nobody is waiting for keeps its socket.
  static const Duration _defaultConnectTimeout = Duration(seconds: 15);

  static String? _proxySignature;
  static Future<String?> Function(String)? _bypassResolver;

  /// Resolve dial hosts without using tunnel DNS. Null restores ordinary DNS.
  static void useBypassResolver(Future<String?> Function(String)? resolver) {
    if (identical(resolver, _bypassResolver)) return;
    _bypassResolver = resolver;
    _resetClient();
  }

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
    _resetClient();
  }

  /// True while the shared client dials hosts through the system resolver.
  ///
  /// A caller wanting its own DNS-over-HTTPS answer must check this first:
  /// mid-tunnel the bypass /32 routes exist for the addresses *RouteManager*
  /// resolved, so dialing a differently-resolved IP would loop into the
  /// tunnel, and with an upstream proxy configured the proxy already does
  /// the remote DNS.
  static bool get usesSystemResolver =>
      _bypassResolver == null && _proxySignature == null;

  static void _resetClient() {
    final old = _client;
    _client = null;
    old?.close();
  }

  static http.Client get _active {
    final existing = _client;
    if (existing != null) return existing;
    final created = createIoClient(
      proxySignature: _proxySignature,
      bypassResolver: _bypassResolver,
    );
    _client = created;
    return created;
  }

  /// Create an independent client; optional transport hooks support local tests.
  ///
  /// [connectTimeout] bounds each half of the handshake separately — the TCP
  /// connect and the TLS negotiation — because a middlebox that silently drops
  /// those packets leaves the socket open and the request otherwise waits on
  /// nothing.
  static io_client.IOClient createIoClient({
    String? proxySignature,
    Future<String?> Function(String)? bypassResolver,
    Duration? connectTimeout,
    io.HttpClient? httpClient,
    Future<io.ConnectionTask<io.Socket>> Function(io.InternetAddress, int)?
        startConnect,
    Future<io.SecureSocket> Function(io.Socket, {required String host})?
        secureSocket,
  }) {
    final client = httpClient ?? io.HttpClient();
    // dart:io only gives up on a socket when its own timer fires; without this,
    // an attempt the caller abandoned after three seconds was still sitting
    // there for over two minutes.
    client.connectionTimeout = connectTimeout ?? _defaultConnectTimeout;
    if (proxySignature == null) {
      // Never inherit the local system/environment proxy after VPN takeover.
      client.findProxy = (_) => 'DIRECT';
    } else {
      final uri = Uri.parse(proxySignature);
      final scheme = uri.scheme == 'socks5' ? 'SOCKS5' : 'PROXY';
      final endpoint = '${uri.host}:${uri.port}';
      client.findProxy = (target) =>
          target.host.isEmpty ? 'DIRECT' : '$scheme $endpoint';
    }

    if (bypassResolver != null) {
      final stepBudget = connectTimeout ?? _defaultConnectTimeout;
      final dial = startConnect ?? io.Socket.startConnect;
      final secure = secureSocket ??
          (io.Socket socket, {required String host}) =>
              io.SecureSocket.secure(socket, host: host);
      client.connectionFactory = (url, proxyHost, proxyPort) {
        final result = Completer<io.Socket>();
        io.ConnectionTask<io.Socket>? rawTask;
        io.Socket? rawSocket;
        io.SecureSocket? tlsSocket;
        var cancelled = false;

        Future<void> connect() async {
          try {
            final dialHost = proxyHost ?? url.host;
            final port = proxyPort ?? url.port;
            final resolved = await bypassResolver(dialHost);
            if (cancelled) return;
            final address = resolved == null
                ? null
                : io.InternetAddress.tryParse(resolved);
            if (address == null) {
              throw io.SocketException(
                'Bypass resolution failed for $dialHost',
                port: port,
              );
            }
            final task = await dial(address, port);
            rawTask = task;
            if (cancelled) task.cancel();
            final raw = await task.socket.timeout(stepBudget);
            rawSocket = raw;
            if (cancelled) {
              raw.destroy();
              return;
            }
            if (proxyHost == null && url.scheme == 'https') {
              // HttpClient does not add TLS to a custom direct connection.
              // Keep the URI host for SNI and normal certificate validation.
              final tls =
                  await secure(raw, host: url.host).timeout(stepBudget);
              tlsSocket = tls;
              if (cancelled) {
                tls.destroy();
                return;
              }
              result.complete(tls);
            } else {
              // HTTPS proxies need a raw socket for HttpClient's CONNECT/TLS.
              result.complete(raw);
            }
          } catch (error, stackTrace) {
            cancelled = true;
            rawTask?.cancel();
            rawSocket?.destroy();
            tlsSocket?.destroy();
            if (!result.isCompleted) result.completeError(error, stackTrace);
          }
        }

        unawaited(connect());
        return Future.value(io.ConnectionTask.fromSocket(result.future, () {
          if (cancelled) return;
          cancelled = true;
          rawTask?.cancel();
          rawSocket?.destroy();
          tlsSocket?.destroy();
          if (!result.isCompleted) {
            result.completeError(
              const io.SocketException('Connection attempt cancelled'),
            );
          }
        }));
      };
    }
    return io_client.IOClient(client);
  }

  static Future<CpResponse> send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
    String? contentType,
    Duration timeout = const Duration(seconds: 30),
  }) => _send(_active, method, url,
      headers: headers, body: body, contentType: contentType, timeout: timeout);

  /// One request through a private client that dials [address] instead of
  /// resolving [url]'s host, while TLS still uses the real hostname for SNI
  /// and certificate validation. Used when the network's own resolver cannot
  /// be trusted to answer for that host; closing the client keeps the shared
  /// one, and its system-resolver behaviour, untouched.
  static Future<CpResponse> sendDirect(
    String method,
    Uri url,
    String address, {
    Map<String, String>? headers,
    List<int>? body,
    String? contentType,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final transport = io.HttpClient();
    final client = createIoClient(
      httpClient: transport,
      bypassResolver: (_) async => address,
      connectTimeout: timeout,
    );
    try {
      return await _send(client, method, url,
          headers: headers,
          body: body,
          contentType: contentType,
          timeout: timeout);
    } finally {
      client.close();
      // `force`, because IOClient's own close leaves a handshake a firewall is
      // quietly dropping sitting in the pool with its socket half open.
      transport.close(force: true);
    }
  }

  static Future<CpResponse> _send(
    http.Client client,
    String method,
    Uri url, {
    Map<String, String>? headers,
    List<int>? body,
    String? contentType,
    required Duration timeout,
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

    final watch = Stopwatch()..start();
    final streamed = await client.send(request).timeout(timeout);
    // Headers arriving says nothing about the body: a server that stops
    // mid-response would otherwise keep the caller, and its own timeout,
    // waiting forever. The idle limit cancels the subscription on the way out,
    // so the socket is released instead of draining in the background.
    final builder = BytesBuilder(copy: false);
    await for (final chunk in streamed.stream
        .timeout(_remaining(watch, timeout))) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
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

/// Time still available out of [budget], floored at one millisecond because a
/// zero-length timeout is rejected rather than honoured.
Duration _remaining(Stopwatch watch, Duration budget) {
  final left = budget - watch.elapsed;
  return left > const Duration(milliseconds: 1)
      ? left
      : const Duration(milliseconds: 1);
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
