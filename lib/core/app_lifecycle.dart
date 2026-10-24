import 'package:window_manager/window_manager.dart';

import '../vpn/vpn_controller.dart';
import 'tray_service.dart';

bool _shutdownStarted = false;

/// The one exit path: both the window's close button and the tray's Quit item
/// go through it, so the wintun adapter, split routes and DNS hijack are never
/// left behind. The tunnel handoff uses it too after UAC accepted the relaunch.
Future<void> shutdownAndExit() async {
  // Closing can be asked for twice (impatient clicks, tray Quit while the
  // window close is still tearing down); the second request must not race the
  // first one's teardown.
  if (_shutdownStarted) return;
  _shutdownStarted = true;
  // Vanish first: restoring DNS and routes means waiting on PowerShell and the
  // tunnel process, and a close button must not look frozen meanwhile. The
  // icon goes too, or "Show" would bring back a window that is already dying.
  try {
    await windowManager.hide();
    await TrayService.instance.sync(
      enabled: false,
      tooltip: '',
      showLabel: '',
      quitLabel: '',
    );
  } catch (_) {}
  try {
    await VpnController.instance.shutdown();
  } finally {
    if (await windowManager.isPreventClose()) {
      await windowManager.setPreventClose(false);
    }
    await windowManager.destroy();
  }
}
