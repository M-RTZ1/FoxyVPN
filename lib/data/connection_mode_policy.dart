import 'dart:io';

import 'connection_mode.dart';

/// Platform policy for the connection modes that rely on Windows APIs.
///
/// Kept in its own file so Linux support never has to alter the Windows
/// implementations: callers ask this policy instead of branching ad hoc.
class ConnectionModePolicy {
  ConnectionModePolicy._();

  /// System proxy and the Wintun tunnel are implemented against Windows
  /// APIs only; other platforms run the local proxy.
  static bool get windowsFeaturesAvailable => Platform.isWindows;

  static ConnectionMode get defaultMode =>
      windowsFeaturesAvailable ? ConnectionMode.tunnel : ConnectionMode.proxy;

  /// Older builds could have stored a Windows-only mode on another platform;
  /// resolve it to the mode that platform can actually run.
  static ConnectionMode resolve(ConnectionMode stored) {
    if (!windowsFeaturesAvailable && stored != ConnectionMode.proxy) {
      return ConnectionMode.proxy;
    }
    return stored;
  }
}
