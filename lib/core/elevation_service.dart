import 'dart:io';

import 'package:flutter/services.dart';

/// Argument the elevated copy receives so it starts the tunnel the user asked
/// for without another click.
const String kElevatedConnectArgument = '--elevated-connect';

/// Reads the UAC elevation state from the Windows runner and starts an
/// elevated copy of the app.
///
/// Failures degrade to "not elevated", which keeps the caller from touching
/// the tunnel rather than blocking the proxy modes.
class ElevationService {
  ElevationService._();

  static final ElevationService instance = ElevationService._();

  static const MethodChannel _channel = MethodChannel('foxyvpn/elevation');

  bool? _elevated;
  List<String>? _startupArguments;

  Future<bool> isElevated() async {
    if (!Platform.isWindows) return true;
    final cached = _elevated;
    if (cached != null) return cached;
    try {
      final elevated = await _channel.invokeMethod<bool>('isElevated') ?? false;
      _elevated = elevated;
      return elevated;
    } catch (_) {
      // No runner channel (tests, early startup): stay on the safe side and
      // let the next call retry instead of caching a failure forever.
      return false;
    }
  }

  Future<List<String>> startupArguments() async {
    if (!Platform.isWindows) return const [];
    final cached = _startupArguments;
    if (cached != null) return cached;
    try {
      final raw = await _channel.invokeMethod<List<Object?>>(
        'startupArguments',
      );
      final arguments = [
        for (final argument in raw ?? const <Object?>[])
          if (argument is String) argument,
      ];
      _startupArguments = arguments;
      return arguments;
    } catch (_) {
      return const [];
    }
  }

  /// Starts this executable through ShellExecute "runas". The return value is
  /// ShellExecute's raw code: above 32 the elevated copy started, 1223 means
  /// the UAC prompt was dismissed.
  Future<int> relaunchElevated(String arguments) async {
    if (!Platform.isWindows) return 0;
    try {
      return await _channel.invokeMethod<int>('relaunchElevated', arguments) ??
          0;
    } catch (_) {
      return 0;
    }
  }
}
