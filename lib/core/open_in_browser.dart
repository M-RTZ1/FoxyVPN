import 'dart:io';

import 'app_logger.dart';

/// Opens a link in the user's default browser.
///
/// `rundll32 url.dll,FileProtocolHandler` is called with an argument list, so
/// the URL never passes through a shell — `cmd /c start <url>` would let a
/// quote or `&` in the link inject extra commands.
Future<bool> openInBrowser(String url) async {
  if (!Platform.isWindows) return false;
  try {
    final result = await Process.run('rundll32.exe', [
      'url.dll,FileProtocolHandler',
      url,
    ], runInShell: false);
    if (result.exitCode != 0) {
      AppLogger.w(
        'Browser',
        'rundll32 exited ${result.exitCode}: ${result.stderr}'.trim(),
      );
    }
    return result.exitCode == 0;
  } catch (e) {
    AppLogger.w('Browser', 'could not open $url', e);
    return false;
  }
}
