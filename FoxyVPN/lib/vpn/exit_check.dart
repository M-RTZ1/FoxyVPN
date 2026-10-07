import 'dart:async';
import 'dart:convert';

import '../core/app_logger.dart';
import 'upstream_session.dart';

const String _tag = 'ExitCheck';

const Duration _exitCheckTimeout = Duration(seconds: 15);

/// Port of Android's `ExitCheck`. The Android version fetched
/// cloudflare.com/cdn-cgi/trace over HTTPS through the local SOCKS port;
/// Dart cannot layer TLS over an arbitrary tunneled byte stream, so the
/// check instead runs plain HTTP over a CONNECT stream to ip-api.com.
class ExitCheck {
  Future<String?> verifyExitCountry(
      UpstreamSession session, String? expectedCountryCode) async {
    TunneledStream? tunneled;
    try {
      tunneled = await session
          .openStream('ip-api.com', 80)
          .timeout(_exitCheckTimeout);
    } catch (e) {
      AppLogger.w(_tag, 'exit check failed (non-fatal)', e);
      return null;
    }

    try {
      final request = utf8.encode(
        'GET /line/?fields=countryCode HTTP/1.1\r\n'
        'Host: ip-api.com\r\n'
        'Connection: close\r\n'
        'User-Agent: FoxyVPN-Windows/1.0\r\n'
        '\r\n',
      );
      tunneled.output.add(request);

      final buffer = <int>[];
      final body = await Future.any<String?>([
        _readBody(tunneled, buffer),
        Future<String?>.delayed(_exitCheckTimeout, () => null),
      ]);
      if (body == null || body.isEmpty) {
        AppLogger.w(_tag, 'exit check response did not report a location');
        return null;
      }
      final actualCountry = body.trim();
      if (expectedCountryCode != null &&
          expectedCountryCode.toUpperCase() != 'REC' &&
          actualCountry.toUpperCase() != expectedCountryCode.toUpperCase()) {
        AppLogger.w(_tag,
            'exit country mismatch: expected $expectedCountryCode, '
            'got $actualCountry');
      }
      return actualCountry;
    } catch (e) {
      AppLogger.w(_tag, 'exit check failed (non-fatal)', e);
      return null;
    } finally {
      tunneled.close();
    }
  }

  Future<String> _readBody(TunneledStream tunneled, List<int> buffer) async {
    await for (final chunk in tunneled.input) {
      buffer.addAll(chunk);
      if (buffer.length > 65536) break;
    }
    final text = latin1.decode(buffer, allowInvalid: true);
    final idx = text.indexOf('\r\n\r\n');
    return idx >= 0 ? text.substring(idx + 4) : text;
  }
}
