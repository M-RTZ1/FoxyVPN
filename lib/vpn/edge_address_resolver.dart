import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/app_logger.dart';
import '../data/control_plane_http.dart';

const String _tag = 'EdgeAddressResolver';

const String _dnsMessageContentType = 'application/dns-message';
const String _dohPath = '/dns-query';

const int _dnsTypeA = 1;
const int _dnsTypeAaaa = 28;
const int _maxResponseBytes = 4096;

const Duration _callTimeout = Duration(seconds: 3);
const Duration _cacheTtl = Duration(minutes: 5);
const Duration _failureBackoff = Duration(minutes: 30);

/// Port of Android's `EdgeAddressResolver`: resolves the edge hostname over
/// DNS-over-HTTPS *before* dialling, so the first packet of the session does
/// not leak a DNS query for the VPN server itself. Falls back to null
/// (system resolver) whenever DoH is unavailable.
class EdgeAddressResolver {
  EdgeAddressResolver._();

  static final Map<String, _CacheEntry> _cache = {};
  static final Map<String, int> _suppressedUntilMs = {};

  static Future<String?> resolve(
      String hostname, List<String> endpointAddresses) async {
    if (endpointAddresses.isEmpty) return null;
    final host = hostname.trim().toLowerCase();
    if (host.isEmpty) return null;
    if (host.codeUnits.any((c) => c >= 128)) return null;
    if (isAddressLiteral(host)) return null;

    final cached = _cache[host];
    if (cached != null &&
        DateTime.now().millisecondsSinceEpoch - cached.resolvedAtMs <
            _cacheTtl.inMilliseconds) {
      return cached.addresses.isNotEmpty ? cached.addresses.first : null;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final endpoints = endpointAddresses
        .map(endpointUrlFor)
        .whereType<String>()
        .toSet()
        .where((e) => (_suppressedUntilMs[e] ?? 0) <= now)
        .toList();
    if (endpoints.isEmpty) {
      AppLogger.d(_tag,
          'skipping DNS-over-HTTPS for $host; every configured endpoint is '
          'in backoff');
      return null;
    }

    final addresses = await _queryEndpoints(host, endpoints);
    if (addresses.isEmpty) {
      AppLogger.i(_tag,
          'could not resolve $host over DNS-over-HTTPS (tried '
          '${endpoints.length} endpoint(s)); dialling by hostname via the '
          'system resolver');
      return null;
    }
    _cache[host] = _CacheEntry(addresses, DateTime.now().millisecondsSinceEpoch);
    return addresses.first;
  }

  static void invalidate() => _cache.clear();

  static Future<List<String>> _queryEndpoints(
      String host, List<String> endpoints) async {
    final queryV4 = buildQuery(host, _dnsTypeA);
    final queryV6 = buildQuery(host, _dnsTypeAaaa);
    if (queryV4 == null || queryV6 == null) return const [];

    final winner = Completer<List<String>?>();
    var outstanding = endpoints.length;

    for (final endpoint in endpoints) {
      unawaited(() async {
        try {
          final addresses = await _queryOne(endpoint, queryV4, queryV6);
          if (addresses == null) {
            _suppressedUntilMs[endpoint] =
                DateTime.now().add(_failureBackoff).millisecondsSinceEpoch;
          } else if (addresses.isNotEmpty) {
            _suppressedUntilMs.remove(endpoint);
            if (!winner.isCompleted) {
              AppLogger.i(_tag,
                  'resolved $host over DNS-over-HTTPS via $endpoint '
                  '(${addresses.length} address(es))');
              winner.complete(addresses);
            }
            return;
          }
        } catch (_) {
          _suppressedUntilMs[endpoint] =
              DateTime.now().add(_failureBackoff).millisecondsSinceEpoch;
        }
        if (--outstanding == 0 && !winner.isCompleted) {
          winner.complete(null);
        }
      }());
    }

    final result = await winner.future;
    return result ?? const [];
  }

  static Future<List<String>?> _queryOne(
      String endpoint, Uint8List queryV4, Uint8List queryV6) async {
    final v4Response = await _post(endpoint, queryV4);
    if (v4Response == null) return null;
    final v4 = parseAddresses(v4Response, _dnsTypeA);
    if (v4.isNotEmpty) return v4;
    final v6Response = await _post(endpoint, queryV6);
    if (v6Response == null) return const [];
    return parseAddresses(v6Response, _dnsTypeAaaa);
  }

  static Future<List<int>?> _post(String endpoint, Uint8List query) async {
    try {
      final response = await ControlPlaneHttp.send(
        'POST',
        Uri.parse(endpoint),
        headers: {'Accept': _dnsMessageContentType},
        body: query,
        timeout: _callTimeout,
      );
      if (!response.isSuccessful) {
        AppLogger.d(_tag,
            'DoH endpoint $endpoint answered HTTP ${response.statusCode}');
        return null;
      }
      if (response.bodyBytes.length > _maxResponseBytes) return null;
      return response.bodyBytes;
    } catch (e) {
      AppLogger.d(_tag, 'DoH endpoint $endpoint unusable: $e');
      return null;
    }
  }

  static String? endpointUrlFor(String address) {
    final host = address.trim().toLowerCase();
    if (!isAddressLiteral(host)) return null;
    final authority = host.contains(':') ? '[$host]' : host;
    return 'https://$authority$_dohPath';
  }
}

class _CacheEntry {
  _CacheEntry(this.addresses, this.resolvedAtMs);

  final List<String> addresses;
  final int resolvedAtMs;
}

Uint8List? buildQuery(String hostname, int type) {
  final labels = hostname.split('.').where((l) => l.isNotEmpty).toList();
  if (labels.isEmpty) return null;

  var encodedNameBytes = 1;
  for (final label in labels) {
    final bytes = label.codeUnits;
    if (bytes.isEmpty || bytes.length > 63) return null;
    if (bytes.any((c) => c >= 128)) return null;
    encodedNameBytes += 1 + bytes.length;
  }
  if (encodedNameBytes > 255) return null;

  final out = BytesBuilder();
  void writeShort(int value) {
    out.add([(value >> 8) & 0xFF, value & 0xFF]);
  }

  writeShort(0); // query id
  writeShort(0x0100); // recursion desired
  writeShort(1); // qdcount
  writeShort(0);
  writeShort(0);
  writeShort(0);
  for (final label in labels) {
    final bytes = label.codeUnits;
    out.addByte(bytes.length);
    out.add(bytes);
  }
  out.addByte(0);
  writeShort(type);
  writeShort(1); // class IN
  return out.toBytes();
}

List<String> parseAddresses(List<int> response, int wantType) {
  if (response.length < 12) return const [];
  int u8(int index) => response[index] & 0xFF;
  int u16(int index) => (u8(index) << 8) | u8(index + 1);

  if (u8(3) & 0x0F != 0) return const [];
  final questionCount = u16(4);
  final answerCount = u16(6);
  if (answerCount == 0) return const [];

  var offset = 12;
  for (var i = 0; i < questionCount; i++) {
    final next = _skipName(response, offset);
    if (next == null) return const [];
    offset = next + 4;
  }

  final expectedRdLength = wantType == _dnsTypeA ? 4 : 16;
  final addresses = <String>[];
  for (var i = 0; i < answerCount; i++) {
    final afterName = _skipName(response, offset);
    if (afterName == null) return addresses;
    offset = afterName;
    if (offset + 10 > response.length) return addresses;
    final type = u16(offset);
    final rdLength = u16(offset + 8);
    offset += 10;
    if (offset + rdLength > response.length) return addresses;
    if (type == wantType && rdLength == expectedRdLength) {
      try {
        addresses.add(InternetAddress.fromRawAddress(
                Uint8List.fromList(response.sublist(offset, offset + rdLength)))
            .address);
      } catch (_) {}
    }
    offset += rdLength;
  }
  return addresses;
}

int? _skipName(List<int> message, int start) {
  var offset = start;
  var consumed = 0;
  while (offset < message.length) {
    final length = message[offset] & 0xFF;
    if (length == 0) return offset + 1;
    if (length & 0xC0 == 0xC0) {
      return offset + 2 <= message.length ? offset + 2 : null;
    }
    if (length > 63) return null;
    offset += 1 + length;
    consumed += 1 + length;
    if (consumed > 255) return null;
  }
  return null;
}

bool isAddressLiteral(String host) {
  if (host.contains(':')) return true;
  final parts = host.split('.');
  if (parts.length != 4) return false;
  return parts.every((part) =>
      part.isNotEmpty &&
      part.length <= 3 &&
      part.split('').every((c) => c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57) &&
      (int.tryParse(part) ?? -1) <= 255);
}
