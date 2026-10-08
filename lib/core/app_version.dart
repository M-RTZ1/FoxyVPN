import 'package:flutter/services.dart' show rootBundle;

import 'app_logger.dart';

/// The running build's version, read from the bundled `pubspec.yaml`.
///
/// Taking it from the pubspec instead of repeating a literal in Dart keeps one
/// source of truth for the release tag, the exe version info in `Runner.rc`
/// and the GitHub update check.
class AppVersion {
  AppVersion._();

  static const String _fallback = '0.0.0';

  /// pubspec's `version:` field, e.g. `1.0.0+3`.
  static String _full = _fallback;

  /// `1.0.0+3`
  static String get full => _full;

  /// `1.0.0` — what a GitHub release tag is compared against.
  static String get number => _full.split('+').first;

  /// Reads the bundled pubspec; call it before `runApp`. Until it completes
  /// the getters report `0.0.0`.
  static Future<void> load() async {
    try {
      final manifest = await rootBundle.loadString(
        'pubspec.yaml',
        cache: false,
      );
      final match = RegExp(
        r'^version:[ \t]*(\S+)[ \t]*$',
        multiLine: true,
      ).firstMatch(manifest);
      final version = match?.group(1);
      if (version != null && version.isNotEmpty) _full = version;
    } catch (e) {
      AppLogger.w(
        'AppVersion',
        'pubspec.yaml is not bundled; version unknown',
        e,
      );
    }
  }
}
