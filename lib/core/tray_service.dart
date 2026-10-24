import 'dart:io';

import 'package:flutter/services.dart';

/// Controls the runner's notification-area icon.
///
/// Every platform call is best-effort: a tray that cannot be created must
/// never keep the window visible, block minimizing, or block quitting.
class TrayService {
  TrayService._();

  static final TrayService instance = TrayService._();

  static const MethodChannel _channel = MethodChannel('foxyvpn/tray');

  bool _enabled = false;
  String _applied = '';
  Future<void> Function()? _onQuit;
  bool _methodHandlerBound = false;

  /// True only after the native side accepted the icon.
  bool get isEnabled => _enabled;

  /// Registers the action the tray's Quit item runs. Dart owns the shutdown
  /// order (tunnel, routes, system proxy), so the runner asks rather than
  /// closing the window itself.
  void bindQuitHandler(Future<void> Function() handler) {
    _onQuit = handler;
    if (_methodHandlerBound) return;
    _methodHandlerBound = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'quit') await _onQuit?.call();
    });
  }

  /// Adds, updates or removes the icon. The arguments also carry the menu
  /// labels so they follow the app language.
  Future<void> sync({
    required bool enabled,
    required String tooltip,
    required String showLabel,
    required String quitLabel,
  }) async {
    if (!Platform.isWindows) return;
    final desired = '$enabled|$tooltip|$showLabel|$quitLabel';
    if (desired == _applied) return;
    _applied = desired;
    try {
      if (enabled) {
        await _channel.invokeMethod<void>('enable', {
          'tooltip': tooltip,
          'showLabel': showLabel,
          'quitLabel': quitLabel,
        });
        _enabled = true;
      } else {
        await _channel.invokeMethod<void>('disable');
        _enabled = false;
      }
    } catch (_) {
      // No runner channel (tests, other platforms) or a shell failure: stay
      // off so the minimize handler keeps the window reachable, and allow the
      // next sync to retry.
      _enabled = false;
      _applied = '';
    }
  }
}
