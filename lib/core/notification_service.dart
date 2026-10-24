import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'app_logger.dart';

const String _tag = 'NotificationService';

/// Windows powering the connect/disconnect toasts through
/// `flutter_local_notifications`. Initialization is lazy and every failure is
/// swallowed: a notification problem must never interfere with the tunnel.
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const int connectedId = 1;
  static const int disconnectedId = 2;

  /// Both are part of the Windows registration and must stay stable across
  /// releases: the package creates the Start Menu shortcut that lets an
  /// unpackaged app raise toasts from them.
  static const String _appName = 'FoxyVPN';
  static const String _appUserModelId = 'FoxyVPN.Desktop';
  static const String _windowsGuid = 'f7a3c2d1-8b64-4e59-a3c7-2d1f9b6e4a80';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  Future<bool>? _ready;

  Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!Platform.isWindows) return;
    try {
      if (!await _ensureReady()) return;
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          windows: WindowsNotificationDetails(),
        ),
      );
    } catch (e) {
      AppLogger.w(_tag, 'could not show a connection notification', e);
    }
  }

  Future<bool> _ensureReady() => _ready ??= _initialize();

  Future<bool> _initialize() async {
    try {
      final initialized = await _plugin.initialize(
        settings: const InitializationSettings(
          windows: WindowsInitializationSettings(
            appName: _appName,
            appUserModelId: _appUserModelId,
            guid: _windowsGuid,
          ),
        ),
      );
      if (initialized == false) {
        AppLogger.w(_tag, 'the notification plugin did not initialize');
      }
      return initialized != false;
    } catch (e) {
      AppLogger.w(_tag, 'the notification plugin could not initialize', e);
      return false;
    }
  }
}
