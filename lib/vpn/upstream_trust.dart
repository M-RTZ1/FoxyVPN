import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../core/app_logger.dart';

const String _tag = 'UpstreamTrust';

/// Port of Android's `vpn/upstream/UpstreamTrust`.
///
/// Fastly rotated the VPN edges to `GlobalSign GCC E46 OV TLS CA 2025`, whose
/// anchor `GlobalSign Root E46` is absent from Dart's built-in root store, so
/// every edge handshake failed with CERTIFICATE_VERIFY_FAILED. Merging the
/// bundled roots into a context that already carries the built-in ones fixes
/// that while leaving certificate validation on.
class UpstreamTrust {
  UpstreamTrust._();

  static const String bundledRootsAsset = 'assets/certs/globalsign_roots.pem';

  static Future<SecurityContext?>? _cached;

  /// Null means "fall back to the default trust store". A missing or
  /// unparseable bundle must never block a connection that would work anyway.
  static Future<SecurityContext?> trustedContext() => _cached ??= _build();

  static Future<SecurityContext?> _build() async {
    try {
      final data = await rootBundle.load(bundledRootsAsset);
      final context = SecurityContext(withTrustedRoots: true);
      context.setTrustedCertificatesBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      AppLogger.i(_tag, 'upstream TLS trust: built-in roots + bundled '
          'GlobalSign roots');
      return context;
    } catch (error) {
      AppLogger.w(_tag, 'could not build the merged trust store; using the '
          'default roots', error);
      return null;
    }
  }
}
