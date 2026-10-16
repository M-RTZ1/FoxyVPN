// Live proof that a dropped handshake comes back on the clock instead of
// hanging: 192.0.2.1 (TEST-NET-1) never answers, so sendDirect must return
// within its budget and leave nothing behind that keeps the VM alive.
//
//   dart --packages=tool/package_config_stub.json tool/verify_dial_timeout.dart
import 'dart:io';

import 'package:foxyvpn/data/control_plane_http.dart';

const String url = 'https://firefox.settings.services.mozilla.com/v1/';

Future<void> main() async {
  final uri = Uri.parse(url);
  var failed = false;
  for (final budget in const [Duration(seconds: 2), Duration(seconds: 4)]) {
    final watch = Stopwatch()..start();
    Object? outcome;
    try {
      await ControlPlaneHttp.sendDirect('GET', uri, '192.0.2.1',
          timeout: budget);
      outcome = 'unexpectedly connected';
      failed = true;
    } catch (error) {
      outcome = error;
    }
    watch.stop();
    stdout.writeln('budget=${budget.inSeconds}s returned in '
        '${watch.elapsedMilliseconds}ms: $outcome');
    if (watch.elapsed > budget * 2) {
      failed = true;
      stdout.writeln('  took far longer than the budget');
    }
  }
  // Reaching this line and exiting promptly is the assertion: a socket left
  // hanging would keep the isolate alive after main returns.
  stdout.writeln(failed ? 'DIAL-TIMEOUT-BAD' : 'DIAL-TIMEOUT-OK');
  if (failed) exitCode = 1;
}
