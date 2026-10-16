import 'dart:async';
import 'dart:io';

import '../core/app_logger.dart';
import '../data/settings_store.dart';
import 'edge_address_resolver.dart';

const String _tag = 'PingUtil';

/// Port of Android's `vpn/PingUtil.kt`: measure TCP-connect latency to a
/// server. Returns elapsed milliseconds, or null on timeout/failure.
///
/// On Windows this is a plain TCP connect (no `VpnService.protect()`
/// equivalent is needed, and ICMP would require administrator rights).
class PingUtil {
  PingUtil._();

  static const Duration timeout = Duration(milliseconds: 1500);

  static Future<int?> measureTcpLatencyMs(String host, int port) async {
    if (host.isEmpty || port <= 0 || port > 65535) return null;
    final address = await _dialAddress(host);
    final stopwatch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(address, port, timeout: timeout);
      stopwatch.stop();
      return stopwatch.elapsedMilliseconds;
    } catch (e) {
      stopwatch.stop();
      AppLogger.d(_tag, 'ping failed to $host:$port: $e');
      return null;
    } finally {
      socket?.destroy();
    }
  }

  /// A forged answer for the edge hostname would make every server look
  /// unreachable, so the edge is addressed over DNS-over-HTTPS and the
  /// network's own resolver is only the fallback. Resolution is deliberately
  /// outside the measured window.
  static Future<String> _dialAddress(String host) async {
    final endpoints = SettingsStore.instance.dohProvider.addresses;
    if (endpoints.isEmpty) return host;
    return await EdgeAddressResolver.resolve(host, endpoints) ?? host;
  }
}