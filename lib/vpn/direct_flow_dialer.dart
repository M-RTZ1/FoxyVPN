import 'dart:async';
import 'dart:collection';
import 'dart:io';

import '../core/app_logger.dart';
import '../data/split_tunnel_rules.dart';
import 'edge_address_resolver.dart';
import 'route_manager.dart';
import 'upstream_session.dart';

const String _tag = 'DirectFlowDialer';

const Duration _defaultRouteTtl = Duration(minutes: 20);
const int _defaultMaxBypassRoutes = 128;
const Duration _connectTimeout = Duration(seconds: 15);

typedef DirectSocketConnector =
    Future<Socket> Function(String address, int port);
typedef RealAddressResolver = Future<String?> Function(String host);
typedef BypassRouteEnsurer = Future<String?> Function(String host);
typedef BypassRouteRemover = Future<bool> Function(String ip);

/// Dials the flows that a split-tunnel rule sent around the VPN, straight
/// from this machine.
///
/// Under full-VPN takeover that is not as simple as opening a socket: system
/// DNS answers are synthetic and the default route belongs to wintun, so a
/// naive connect would either loop back into the tunnel or reach a fake
/// address. Each bypassed destination therefore needs a real IPv4 (resolved
/// over DNS-over-HTTPS, which leaves through an already-bypassed resolver) and
/// a host route through the physical gateway. Both are cached, both are
/// released when the tunnel comes down.
///
/// Every failure here degrades to the tunnel rather than refusing the flow:
/// the point of the fallback is that a broken bypass can never leak.
class DirectFlowDialer {
  DirectFlowDialer({
    required this.underTunnelTakeover,
    required this.dohEndpointAddresses,
    this.maxBypassRoutes = _defaultMaxBypassRoutes,
    this.routeTtl = _defaultRouteTtl,
    RealAddressResolver? resolveRealAddress,
    BypassRouteEnsurer? ensureBypassRoute,
    BypassRouteRemover? removeBypassRoute,
    DirectSocketConnector? connector,
  }) : _resolveRealAddress =
           resolveRealAddress ??
           ((host) => _resolveReal(host, dohEndpointAddresses)),
       _ensureBypassRoute =
           ensureBypassRoute ?? RouteManager.instance.ensureBypassHost,
       _removeBypassRoute =
           removeBypassRoute ?? RouteManager.instance.removeBypassHost,
       _connect = connector ?? _defaultConnect;

  /// True in full-VPN mode: the default route is the adapter's, so a bypassed
  /// destination needs both a literal address and a host route of its own.
  final bool underTunnelTakeover;
  final List<String> dohEndpointAddresses;
  final int maxBypassRoutes;
  final Duration routeTtl;

  final RealAddressResolver _resolveRealAddress;
  final BypassRouteEnsurer _ensureBypassRoute;
  final BypassRouteRemover _removeBypassRoute;
  final DirectSocketConnector _connect;

  /// Destination IPs this dialer installed a bypass route for, oldest first.
  final LinkedHashMap<String, int> _bypassRoutes = LinkedHashMap();

  int _flows = 0;
  int _failures = 0;
  int _unresolved = 0;
  int _routeFailures = 0;
  int _refusedLocalTargets = 0;
  bool _warnedAboutDoH = false;

  /// Flows that left the machine outside the VPN.
  int get flows => _flows;
  int get failures => _failures;

  /// One-line summary for the disconnect log.
  String get summary =>
      '$_flows flow(s) went direct, $_failures direct dial(s) fell back to '
      'the tunnel'
      '${_unresolved > 0 ? ', $_unresolved unresolved host(s)' : ''}'
      '${_routeFailures > 0 ? ', $_routeFailures route install failure(s)' : ''}'
      '${_refusedLocalTargets > 0 ? ', $_refusedLocalTargets local target(s) refused' : ''}';

  /// Opens a direct connection and wraps it as a [TunneledStream] so the
  /// relay does not care which way the bytes leave. Null means "no direct
  /// path", and the caller must tunnel the flow instead.
  Future<TunneledStream?> dial(String host, int port) async {
    final target = host.trim().toLowerCase();
    if (target.isEmpty) return null;
    if (isLocalOrSpecialAddress(target)) {
      _refusedLocalTargets++;
      AppLogger.d(
        _tag,
        'not dialling $target directly: it is a local or special address',
      );
      return null;
    }

    final address = underTunnelTakeover ? await _physicalAddress(target) : target;
    if (address == null) return null;

    try {
      final socket = await _connect(address, port).timeout(_connectTimeout);
      socket.setOption(SocketOption.tcpNoDelay, true);
      _flows++;
      AppLogger.d(_tag, 'direct dial to $address:$port ($target) established');
      return TunneledStream(
        input: socket,
        output: socket,
        close: () {
          try {
            socket.destroy();
          } catch (_) {}
        },
      );
    } catch (e) {
      _failures++;
      AppLogger.d(_tag, 'direct dial to $address:$port failed: $e');
      return null;
    }
  }

  /// The address a bypassed flow must dial under full-VPN takeover, having
  /// made sure a physical host route exists for it.
  Future<String?> _physicalAddress(String host) async {
    if (_isIpv4Literal(host)) return _routeForLiteral(host);
    if (host.contains(':')) {
      // IPv6 is never taken over — the adapter is IPv4-only — so a literal
      // v6 address already leaves through the physical interface.
      return host;
    }

    final literal = await _resolveRealAddress(host);
    if (literal == null || literal.isEmpty) {
      if (!_warnedAboutDoH && dohEndpointAddresses.isEmpty) {
        _warnedAboutDoH = true;
        AppLogger.w(
          _tag,
          'domain bypasses cannot resolve real addresses while DNS is '
          'hijacked and no DNS-over-HTTPS provider is selected; those flows '
          'are tunnelled instead',
        );
      }
      _unresolved++;
      return null;
    }
    if (isLocalOrSpecialAddress(literal)) {
      _refusedLocalTargets++;
      AppLogger.d(
        _tag,
        '$host resolves to $literal, which is a local or special address',
      );
      return null;
    }
    if (literal.contains(':')) return literal;
    return _routeForLiteral(literal);
  }

  Future<String?> _routeForLiteral(String ip) async {
    _purgeExpiredRoutes();
    final routed = await _ensureBypassRoute(ip);
    if (routed == null || routed.isEmpty) {
      _routeFailures++;
      AppLogger.d(_tag, 'no physical bypass route for $ip; tunnelled instead');
      return null;
    }
    _bypassRoutes.remove(routed);
    _bypassRoutes[routed] =
        DateTime.now().millisecondsSinceEpoch + routeTtl.inMilliseconds;
    await _evictOverCap();
    return routed;
  }

  void _purgeExpiredRoutes() {
    if (_bypassRoutes.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in _bypassRoutes.entries.toList()) {
      if (entry.value > now) continue;
      _bypassRoutes.remove(entry.key);
      unawaited(_dropRoute(entry.key));
    }
  }

  Future<void> _evictOverCap() async {
    while (_bypassRoutes.length > maxBypassRoutes) {
      final oldest = _bypassRoutes.keys.first;
      _bypassRoutes.remove(oldest);
      // Not awaited: a fresh dial should not queue behind route.exe teardown.
      unawaited(_dropRoute(oldest));
    }
  }

  Future<void> _dropRoute(String ip) async {
    try {
      await _removeBypassRoute(ip);
    } catch (e) {
      AppLogger.d(_tag, 'could not remove the bypass route for $ip: $e');
    }
  }

  /// Drops the bookkeeping when the connection ends. The host routes are left
  /// for [RouteManager.disable], which owns them and removes them in one pass
  /// — deleting them here as well would mean a route.exe per destination.
  Future<void> close() async {
    _bypassRoutes.clear();
  }

  static Future<Socket> _defaultConnect(String address, int port) =>
      Socket.connect(address, port, timeout: _connectTimeout);

  /// A real IPv4 for a hostname while the tunnel owns the network: the
  /// DNS-over-HTTPS answer first (the bypassed resolver, so never a synthetic
  /// one), then the system resolver with synthetic and local answers dropped —
  /// that is the path a custom DNS server takes.
  static Future<String?> _resolveReal(String host, List<String> doh) async {
    final viaDoh = await EdgeAddressResolver.resolve(host, doh);
    if (viaDoh != null && viaDoh.isNotEmpty) return viaDoh;
    try {
      for (final answer in await InternetAddress.lookup(host)) {
        if (answer.type != InternetAddressType.IPv4) continue;
        if (isLocalOrSpecialAddress(answer.address)) continue;
        return answer.address;
      }
    } catch (_) {
      // No answer at all; the caller tunnels the flow instead.
    }
    return null;
  }
}

bool _isIpv4Literal(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return false;
  return parts.every(
    (part) =>
        part.isNotEmpty &&
        part.length <= 3 &&
        part.codeUnits.every((c) => c >= 48 && c <= 57) &&
        (int.tryParse(part) ?? -1) <= 255,
  );
}
