import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/app_logger.dart';

const String _tag = 'HevSocks5Tunnel';

/// Windows host of the native hev-socks5-tunnel engine. Unlike Android
/// (JNI + TUN fd), on Windows the engine runs as a child process that
/// creates its own wintun adapter, so this class manages the config file
/// and the process lifetime.
class HevSocks5Tunnel {
  HevSocks5Tunnel._();

  static const String fileName = 'hev-socks5-tunnel.yaml';
  static const String tunAddress = '10.8.0.2';
  static const int tunMtu = 8500;
  static const String mapdnsAddress = '198.18.0.2';

  static Process? _process;
  static StreamSubscription<String>? _stdoutSub;
  static StreamSubscription<String>? _stderrSub;

  static bool get isRunning => _process != null;

  /// True for synthetic mapdns addresses (100.64.0.0/10).
  static bool isFakeDnsAddress(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final octets = <int>[];
    for (final part in parts) {
      if (part.isEmpty || part.length > 3) return false;
      final octet = int.tryParse(part);
      if (octet == null || octet < 0 || octet > 255) return false;
      octets.add(octet);
    }
    return octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127;
  }

  /// Locates the engine binary: explicit setting first, then next to the
  /// app executable, then a bundled `bin/` folder.
  static String? findBinary(String configuredPath) {
    if (configuredPath.isNotEmpty && File(configuredPath).existsSync()) {
      return configuredPath;
    }
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      '$exeDir\\hev-socks5-tunnel.exe',
      '$exeDir\\bin\\hev-socks5-tunnel.exe',
      '$exeDir\\data\\flutter_assets\\assets\\hev-socks5-tunnel.exe',
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static Future<String> writeConfig(
    Directory dir,
    int socksPort,
    String? customDnsServer,
  ) async {
    final mapdnsBlock = customDnsServer == null
        ? '''
mapdns:
  address: '$mapdnsAddress'
  port: 53
  network: '100.64.0.0'
  netmask: '255.192.0.0'
  cache-size: 10000
'''
        : '';

    final yaml = '''
tunnel:
  mtu: $tunMtu
  ipv4: '$tunAddress'
  icmp: 'reply'
socks5:
  port: $socksPort
  address: '127.0.0.1'
  udp: 'udp'
$mapdnsBlock
misc:
  task-stack-size: 86016
  connect-timeout: 20000
  tcp-read-write-timeout: 300000
  udp-read-write-timeout: 60000
  tcp-buffer-size: 65536
  udp-recv-buffer-size: 524288
  udp-copy-buffer-nums: 16
  max-session-count: 0
  limit-nofile: 65535
  log-level: 'warn'
''';
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    await file.writeAsString(yaml);
    return file.path;
  }

  static Future<bool> start(String binaryPath, String configPath) async {
    if (_process != null) return true;
    try {
      final process = await Process.start(
        binaryPath,
        [configPath],
        workingDirectory: File(binaryPath).parent.path,
        runInShell: false,
      );
      _process = process;
      _stdoutSub = process.stdout
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen((String line) => AppLogger.d(_tag, 'hev: $line'));
      _stderrSub = process.stderr
          .transform(const SystemEncoding().decoder)
          .transform(const LineSplitter())
          .listen((String line) => AppLogger.w(_tag, 'hev: $line'));
      unawaited(process.exitCode.then((code) {
        if (identical(_process, process)) {
          AppLogger.w(_tag, 'the tunnel process exited with code $code');
          _process = null;
        }
      }));
      // Give wintun a moment to create the adapter.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (_process == null) {
        AppLogger.e(_tag,
            'the tunnel process exited immediately (is the wintun driver '
            'installed and the app running as administrator?)');
        return false;
      }
      AppLogger.i(_tag, 'tunnel process started (pid ${process.pid})');
      return true;
    } catch (e) {
      AppLogger.e(_tag, 'failed to start hev-socks5-tunnel', e);
      _process = null;
      return false;
    }
  }

  static Future<void> stop() async {
    final process = _process;
    _process = null;
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    if (process != null) {
      try {
        process.kill(ProcessSignal.sigterm);
        await process.exitCode
            .timeout(const Duration(seconds: 3), onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        });
      } catch (e) {
        AppLogger.w(_tag, 'error stopping the tunnel process', e);
      }
      AppLogger.i(_tag, 'tunnel process stopped');
    }
  }
}
