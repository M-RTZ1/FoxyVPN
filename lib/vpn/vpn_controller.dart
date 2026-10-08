import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/app_logger.dart';
import '../data/control_plane_http.dart';
import '../data/fxa_auth_repository.dart';
import '../data/guardian_client.dart';
import '../data/models.dart';
import '../data/proxy_state_store.dart';
import '../data/server_list_client.dart';
import '../data/settings_store.dart';
import '../data/token_store.dart';
import 'edge_address_resolver.dart';
import 'exit_check.dart';
import 'h2_upstream_session.dart';
import 'hev_socks5_tunnel.dart';
import 'local_socks5_server.dart';
import 'route_manager.dart';
import 'system_proxy_manager.dart';
import 'upstream_session.dart';

const String _tag = 'VpnController';

const Duration _connectTimeout = Duration(seconds: 20);
const Duration _serverListFetchTimeout = Duration(seconds: 15);

const Duration _watchdogInterval = Duration(seconds: 2);

const int _reconnectFailuresBeforeWarning = 5;
const int _reconnectBackoffBaseMs = 3000;
const int _reconnectBackoffCapMs = 60000;

const int _reconnectFailuresBeforeEdgeRotation = 2;

const int _maxAlternateEdges = 3;

const int _unhealthyRedialCooldownMs = 30000;

const double _proxyPassRenewalFraction = 0.5;
const int _proxyPassRenewalSafetyMarginMs = 30000;
const int _proxyPassRenewalFloorMs = 15000;
const int _proxyPassRenewalCeilingMs = 30 * 60000;
const int _proxyPassRenewalFallbackMs = 4 * 60000;
const int _proxyPassRenewalRetryMs = 30000;

const int _postTunSettleMs = 250;

const int _initialDialSettleMs = 600;
const int _initialDialMaxAttempts = _maxAlternateEdges + 1;
const int _initialDialBackoffBaseMs = 2000;
const int _initialDialBackoffCapMs = 8000;

const int _speedUpdateIntervalMs = 2000;

int _fullJitterBackoffMs(int attempt, int baseMs, int capMs) {
  final exponential = baseMs * (1 << attempt.clamp(0, 10));
  final upperBound = min(exponential, capMs);
  return max((upperBound * Random().nextDouble()).floor(), baseMs ~/ 4);
}

int _proxyPassRenewalDelayMs(int? expiresAtEpochSeconds) {
  if (expiresAtEpochSeconds == null) return _proxyPassRenewalFallbackMs;
  final remainingMs =
      expiresAtEpochSeconds * 1000 - DateTime.now().millisecondsSinceEpoch;
  if (remainingMs <= 0) return _proxyPassRenewalFloorMs;
  final atHalfLife = (remainingMs * _proxyPassRenewalFraction).floor();
  final beforeExpiry = remainingMs - _proxyPassRenewalSafetyMarginMs;
  return min(
    atHalfLife,
    beforeExpiry,
  ).clamp(_proxyPassRenewalFloorMs, _proxyPassRenewalCeilingMs);
}

class _SupersededException implements Exception {
  @override
  String toString() => 'connect was superseded by a newer request';
}

enum VpnStatusKind {
  disconnected,
  connecting,
  waitingForNetwork,
  reconnecting,

  /// [detail] is the exit country name.
  connectedVpn,

  /// [detail] is the local proxy bind address and port.
  proxyActive,
}

/// Windows port of Android's `FoxyVpnService` orchestration: owns the local
/// SOCKS5 frontend, the native tunnel process, the upstream HTTP/2 session,
/// the watchdog, proxy-pass renewal, exit check and speed readout.
class VpnController extends ChangeNotifier {
  VpnController._() {
    SettingsStore.instance.localProxyEndpoint.addListener(
      _onLocalProxyEndpointChanged,
    );
  }

  static final VpnController instance = VpnController._();

  ConnectionState _state = ConnectionState.disconnected;
  ConnectionState get state => _state;

  String? _lastError;
  String? get lastError => _lastError;

  VpnStatusKind _statusKind = VpnStatusKind.disconnected;
  VpnStatusKind get statusKind => _statusKind;

  String _statusDetail = '';

  /// Extra information for the status line: the exit country when the tunnel
  /// is up, the local proxy address in proxy-only mode, otherwise empty.
  String get statusDetail => _statusDetail;

  int _downloadBytesPerSecond = 0;
  int get downloadBytesPerSecond => _downloadBytesPerSecond;

  int _uploadBytesPerSecond = 0;
  int get uploadBytesPerSecond => _uploadBytesPerSecond;

  int? _quotaRemainingBytes;
  int? get quotaRemainingBytes => _quotaRemainingBytes;

  int? _quotaMaxBytes;
  int? get quotaMaxBytes => _quotaMaxBytes;

  int _generation = 0;
  Future<void> _opChain = Future<void>.value();

  LocalSocks5Server? _socksServer;
  UpstreamSession? _upstreamSession;
  Timer? _speedTimer;

  /// The endpoint [_socksServer] is meant to be listening on. Kept separate
  /// from the server because the speed sampler holds the same instance and
  /// Dart will not infer non-null from a boolean.
  (String, int)? _localProxyEndpoint;

  int _lastUnhealthyRedialAt = 0;

  void _set({
    ConnectionState? state,
    VpnStatusKind? statusKind,
    String? statusDetail,
    String? lastError,
    bool clearError = false,
  }) {
    if (state != null) _state = state;
    if (statusKind != null) _statusKind = statusKind;
    if (statusDetail != null) _statusDetail = statusDetail;
    if (clearError) {
      _lastError = null;
    } else if (lastError != null) {
      _lastError = lastError;
    }
    notifyListeners();
  }

  /// Serialises connect/teardown so they never interleave.
  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _opChain.then((_) => operation());
    _opChain = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  Future<void> connect() async {
    if (_state != ConnectionState.disconnected) {
      AppLogger.d(_tag, 'ignoring duplicate connect request while $_state');
      return;
    }
    _set(
      state: ConnectionState.connecting,
      statusKind: VpnStatusKind.connecting,
      clearError: true,
    );
    try {
      await _enqueue(_connect);
    } catch (_) {
      // Errors are surfaced through _lastError by _connect itself.
    }
  }

  Future<void> disconnect([String reason = 'requested by the user']) async {
    final idle = _state == ConnectionState.disconnected;
    AppLogger.i(_tag, 'disconnect: $reason');
    final endedGeneration = ++_generation;
    _speedTimer?.cancel();
    _speedTimer = null;
    _downloadBytesPerSecond = 0;
    _uploadBytesPerSecond = 0;
    _set(
      state: ConnectionState.disconnected,
      statusKind: VpnStatusKind.disconnected,
      statusDetail: '',
    );
    if (idle) return;
    await _enqueue(() => _releaseResources(endedGeneration));
  }

  /// Called when the app window is closing so wintun routes are cleaned up.
  Future<void> shutdown() => disconnect('the application is exiting');

  /// A Settings edit moved the local frontend's address or port. In
  /// proxy-only mode rebind it live; in full-VPN mode
  /// hev-socks5-tunnel was launched with the old port baked into its config,
  /// so the change lands on the next connect.
  void _onLocalProxyEndpointChanged() {
    if (_state != ConnectionState.connected) return;
    final endpoint = SettingsStore.instance.localProxyEndpoint.value;
    if (_localProxyEndpoint == endpoint) return;
    if (!SettingsStore.instance.proxyOnlyMode) {
      AppLogger.i(
        _tag,
        'local proxy endpoint moved to ${endpoint.$1}:${endpoint.$2}; '
        'full-VPN mode applies it on the next connect',
      );
      return;
    }
    unawaited(_enqueue(_rebindLocalProxy));
  }

  LocalSocks5Server _newLocalProxy(String bindAddress, int port) =>
      LocalSocks5Server(
        bindAddress: bindAddress,
        port: port,
        // Proxy-only mode runs no mapdns, so there are no fake IPs to reject.
        rejectFakeDnsAddresses: false,
        sessionProvider: () => _upstreamSession,
        onSessionUnhealthy: _onUpstreamSessionUnhealthy,
      );

  Future<void> _rebindLocalProxy() async {
    if (_state != ConnectionState.connected) return;
    final settings = SettingsStore.instance;
    final endpoint = settings.localProxyEndpoint.value;
    final (address, port) = endpoint;
    if (_localProxyEndpoint == endpoint) return;
    AppLogger.i(_tag, 'rebinding the local proxy to $address:$port');

    // Two listeners cannot share one port, so when only the address changes
    // the old one must go first; otherwise bind the new listener before
    // closing the old so a failed rebind never strands connected apps.
    final movingToTheSamePort = _localProxyEndpoint?.$2 == port;
    if (movingToTheSamePort) await _stopLocalProxy();

    final replacement = _newLocalProxy(address, port);
    try {
      await replacement.start();
    } catch (e) {
      AppLogger.w(
        _tag,
        'the local proxy could not listen on $address:$port',
        e,
      );
      if (movingToTheSamePort) {
        // Nothing is listening now: put the previous endpoint back rather
        // than leave already-configured apps with a dead port.
        final (oldAddress, oldPort) = _localProxyEndpoint!;
        final rollback = _newLocalProxy(oldAddress, oldPort);
        try {
          await rollback.start();
          _socksServer = rollback;
        } catch (_) {
          _socksServer = null;
        }
      }
      _set(
        lastError:
            'the local proxy could not listen on $address:$port — is that port '
            'already taken?',
      );
      return;
    }
    if (!movingToTheSamePort) await _stopLocalProxy();
    _socksServer = replacement;
    _localProxyEndpoint = endpoint;

    if (settings.systemProxyEnabled) {
      await SystemProxyManager.instance.updateServer('127.0.0.1:$port');
    }
    _startSpeedUpdates(replacement);
    _set(
      statusKind: VpnStatusKind.proxyActive,
      statusDetail: '$address:$port',
      clearError: true,
    );
  }

  Future<void> _stopLocalProxy() async {
    final server = _socksServer;
    if (server == null) return;
    try {
      await server.stop();
    } catch (e) {
      AppLogger.w(_tag, 'error stopping the previous local proxy', e);
    }
  }

  void _ensureGenerationCurrent(int myGeneration) {
    if (myGeneration != _generation) throw _SupersededException();
  }

  bool _isFatalUpstreamError(Object error) =>
      error is TokenInvalidError || error is QuotaExceededError;

  void _onUpstreamSessionUnhealthy() {
    if (_state != ConnectionState.connected) return;
    final session = _upstreamSession;
    if (session == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final sinceLast = now - _lastUnhealthyRedialAt;
    if (_lastUnhealthyRedialAt != 0 && sinceLast < _unhealthyRedialCooldownMs) {
      AppLogger.d(
        _tag,
        'ignoring an unhealthy-session verdict ${sinceLast}ms after the '
        'last rebuild (cooldown ${_unhealthyRedialCooldownMs}ms)',
      );
      return;
    }
    _lastUnhealthyRedialAt = now;
    AppLogger.w(
      _tag,
      'the local proxy reports the upstream session is failing as a whole '
      'rather than for one destination; closing it so the watchdog redials',
    );
    try {
      session.close();
    } catch (e) {
      AppLogger.w(_tag, 'error closing the unhealthy session', e);
    }
  }

  Future<void> _connect() async {
    final myGeneration = ++_generation;
    _lastUnhealthyRedialAt = 0;
    EdgeAddressResolver.invalidate();

    try {
      AppLogger.i(_tag, 'connect: starting');
      final tokenStore = TokenStore.instance;
      if (await tokenStore.loadAuth() == null) {
        throw StateError('Not signed in');
      }
      final proxyStateStore = ProxyStateStore.instance;
      final settingsStore = SettingsStore.instance;

      // Built before anything hits the network: the server-list fetch and
      // every other control-plane call must chain through it too.
      final upstreamProxyConfig = await _buildUpstreamProxyConfig(
        settingsStore,
      );
      ControlPlaneHttp.useProxy(
        socks5: upstreamProxyConfig?.type == UpstreamProxyType.socks5,
        host: upstreamProxyConfig?.host ?? '',
        port: upstreamProxyConfig?.port ?? 0,
      );
      if (upstreamProxyConfig != null) {
        AppLogger.i(
          _tag,
          'control-plane requests will chain through the '
          '${upstreamProxyConfig.type.name} proxy '
          '${upstreamProxyConfig.address}',
        );
      }

      final primaryCandidate = await _resolveConnectCandidate(
        proxyStateStore,
        myGeneration,
      );
      _ensureGenerationCurrent(myGeneration);

      var candidates = <ProxyCandidate>[primaryCandidate];
      var candidateIndex = 0;
      var alternatesDiscovered = false;

      ProxyCandidate activeCandidate() =>
          candidates[candidateIndex.clamp(0, candidates.length - 1)];

      Future<bool> rotateCandidate() async {
        if (candidateIndex + 1 >= candidates.length && !alternatesDiscovered) {
          alternatesDiscovered = true;
          final fresh = (await _discoverAlternateCandidates(primaryCandidate))
              .where(
                (discovered) => candidates.every(
                  (known) => known.authority != discovered.authority,
                ),
              )
              .take(_maxAlternateEdges)
              .toList();
          if (fresh.isNotEmpty) {
            candidates = candidates + fresh;
            AppLogger.i(
              _tag,
              'found ${fresh.length} alternate edge(s) in '
              '${primaryCandidate.countryCode} to fail over to',
            );
          }
        }
        if (candidateIndex + 1 >= candidates.length) return false;
        candidateIndex++;
        AppLogger.i(
          _tag,
          'failing over to edge ${activeCandidate().authority} '
          '(${candidateIndex + 1} of ${candidates.length})',
        );
        return true;
      }

      final chainSuffix = upstreamProxyConfig != null
          ? ' via ${upstreamProxyConfig.type.name} proxy '
                '${upstreamProxyConfig.address}'
          : '';

      final customEdgeAddress = settingsStore.effectiveCustomEdgeAddress;
      final edgeSuffix = customEdgeAddress != null
          ? ' via pinned edge $customEdgeAddress:${primaryCandidate.port}'
          : '';

      final dohEndpointAddresses = settingsStore.dohProvider.addresses;

      AppLogger.i(
        _tag,
        'connect: target=${primaryCandidate.authority} '
        'country=${primaryCandidate.countryCode}$chainSuffix$edgeSuffix',
      );

      final socksPort = settingsStore.socksPort;
      final socksBindAddress = settingsStore.socksBindAddress;
      final proxyOnlyMode = settingsStore.proxyOnlyMode;
      final customDnsServer = settingsStore.effectiveCustomDnsServer;

      ({VpnStatusKind kind, String detail}) connectedLabel() {
        if (proxyOnlyMode) {
          // Read the live frontend: a Settings edit can rebind it to another
          // address or port after this closure was created.
          final (address, port) =
              _localProxyEndpoint ?? (socksBindAddress, socksPort);
          return (kind: VpnStatusKind.proxyActive, detail: '$address:$port');
        }
        final target = activeCandidate();
        final country = target.countryName.isNotEmpty
            ? target.countryName
            : target.countryCode;
        return (kind: VpnStatusKind.connectedVpn, detail: country);
      }

      final mapdnsActive = !proxyOnlyMode && customDnsServer == null;
      final socks = LocalSocks5Server(
        bindAddress: socksBindAddress,
        port: socksPort,
        rejectFakeDnsAddresses: mapdnsActive,
        sessionProvider: () => _upstreamSession,
        onSessionUnhealthy: _onUpstreamSessionUnhealthy,
      );
      await socks.start();
      _socksServer = socks;
      _localProxyEndpoint = (socksBindAddress, socks.boundPort);

      if (settingsStore.systemProxyEnabled) {
        // Windows' system proxy speaks HTTP only, which the local port
        // answers alongside SOCKS5.
        await SystemProxyManager.instance.apply('127.0.0.1:$socksPort');
      }
      _ensureGenerationCurrent(myGeneration);

      if (proxyOnlyMode) {
        AppLogger.i(
          _tag,
          'connect: proxy-only mode enabled, skipping the wintun tunnel; '
          'local proxy at $socksBindAddress:$socksPort',
        );
      } else {
        // Bypass routes must be installed BEFORE wintun takes the default
        // route: the app's own control-plane, edge and upstream-proxy dials
        // must leave through the physical gateway, not loop into the tunnel.
        await RouteManager.instance.enable(
          extraBypassHosts: [
            primaryCandidate.host,
            ?customEdgeAddress,
            if (upstreamProxyConfig != null) upstreamProxyConfig.host,
          ],
        );
        _ensureGenerationCurrent(myGeneration);

        final binary = HevSocks5Tunnel.findBinary(
          settingsStore.hevTunnelBinaryPath,
        );
        if (binary == null) {
          throw StateError(
            'hev-socks5-tunnel.exe was not found. Place it next to the app '
            'executable or set its path in Settings.',
          );
        }
        final configPath = await HevSocks5Tunnel.writeConfig(
          Directory.systemTemp,
          socksPort,
          customDnsServer,
        );
        final started = await HevSocks5Tunnel.start(binary, configPath);
        if (!started) {
          throw StateError(
            'Failed to start the tun2socks tunnel (hev-socks5-tunnel). '
            'Run the app as administrator.',
          );
        }
        AppLogger.i(_tag, 'connect: wintun tunnel started');
        await Future<void>.delayed(
          const Duration(milliseconds: _postTunSettleMs),
        );

        // The engine creates the adapter but does not route or DNS into it;
        // the host side of the takeover lives in RouteManager.
        await RouteManager.instance.takeoverRoutes(
          customDnsServer: customDnsServer,
        );
        _ensureGenerationCurrent(myGeneration);
      }
      _ensureGenerationCurrent(myGeneration);

      var currentPassExpiry = _currentPassExpiry;

      Future<H2UpstreamSession> dialUpstream() async {
        final target = activeCandidate();
        final pass = await _mintProxyPass();
        _currentPassExpiry = pass.expiresAtEpochSeconds;
        currentPassExpiry = pass.expiresAtEpochSeconds;
        _updateQuota(pass);
        final lifetimeNote = pass.expiresAtEpochSeconds != null
            ? ' (valid for '
                  '${(pass.expiresAtEpochSeconds! * 1000 - DateTime.now().millisecondsSinceEpoch) ~/ 1000}s)'
            : ' (lifetime not stated)';
        AppLogger.i(_tag, 'connect: acquired Guardian proxy pass$lifetimeNote');

        var edgeAddress =
            customEdgeAddress ??
            await _resolveEdgeAddress(
              target.host,
              upstreamProxyConfig,
              dohEndpointAddresses,
            );

        if (!proxyOnlyMode && upstreamProxyConfig == null) {
          // Under the tunnel the edge dial itself must bypass wintun and must
          // use a literal address: resolving by hostname would answer a
          // mapdns fake IP and loop the upstream connection back into the
          // tunnel.
          final literal = await RouteManager.instance.ensureBypassHost(
            edgeAddress ?? target.host,
          );
          if (literal != null) edgeAddress = literal;
        }

        if (!proxyOnlyMode) {
          // Under the tunnel the edge dial itself must bypass wintun, and a
          // hostname could resolve to a mapdns fake IP — force a real,
          // bypass-routed literal whenever one is discoverable.
          final literal = await RouteManager.instance.ensureBypassHost(
            edgeAddress ?? target.host,
          );
          if (literal != null) edgeAddress = literal;
        }

        final session = H2UpstreamSession(
          target.host,
          target.port,
          pass.token,
          upstreamProxy: upstreamProxyConfig,
          edgeAddress: edgeAddress,
        );
        try {
          await session.connect().timeout(_connectTimeout);
        } catch (failure) {
          try {
            await session.close();
          } catch (_) {}
          rethrow;
        }
        AppLogger.i(
          _tag,
          'connect: upstream HTTP/2 tunnel established to ${target.authority}',
        );
        return session;
      }

      var dialAttempt = 0;
      Object? lastDialFailure;
      while (true) {
        dialAttempt++;
        _ensureGenerationCurrent(myGeneration);
        final target = activeCandidate();

        H2UpstreamSession? session;
        try {
          session = await dialUpstream();
        } on TimeoutException catch (e) {
          lastDialFailure = e;
          AppLogger.w(
            _tag,
            'dial to ${target.authority} timed out (attempt $dialAttempt)',
          );
        } catch (error) {
          if (_isFatalUpstreamError(error)) rethrow;
          lastDialFailure = error;
          AppLogger.w(
            _tag,
            'dial to ${target.authority} failed (attempt $dialAttempt): $error',
          );
        }

        if (session != null) {
          if (myGeneration != _generation) {
            try {
              await session.close();
            } catch (_) {}
            _ensureGenerationCurrent(myGeneration);
          }
          _upstreamSession = session;
          await Future<void>.delayed(
            const Duration(milliseconds: _initialDialSettleMs),
          );
          if (_upstreamSession?.isConnected ?? false) break;
          AppLogger.w(
            _tag,
            'upstream tunnel to ${target.authority} died immediately after '
            'connecting (attempt $dialAttempt/$_initialDialMaxAttempts)',
          );
          try {
            await _upstreamSession?.close();
          } catch (_) {}
          _upstreamSession = null;
          lastDialFailure = null;
        }

        if (dialAttempt >= _initialDialMaxAttempts) {
          final (failures, cleared) = proxyStateStore.recordFailure();
          if (cleared) {
            AppLogger.w(
              _tag,
              'the saved location failed $failures connects in a row; '
              'clearing it so the next connect auto-selects a location',
            );
          }
          if (lastDialFailure != null) {
            throw StateError(
              'Could not reach a VPN server after $dialAttempt attempts '
              'across ${candidates.length} server(s). Last error: '
              '${_friendlyErrorMessage(lastDialFailure)}',
            );
          }
          throw StateError(
            'The VPN server closed the connection immediately, $dialAttempt '
            'times in a row. Try again shortly or pick a different location.',
          );
        }

        await rotateCandidate();
        await Future<void>.delayed(
          Duration(
            milliseconds: _fullJitterBackoffMs(
              dialAttempt - 1,
              _initialDialBackoffBaseMs,
              _initialDialBackoffCapMs,
            ),
          ),
        );
      }

      _ensureGenerationCurrent(myGeneration);

      final establishedCandidate = activeCandidate();
      if (establishedCandidate.authority == primaryCandidate.authority) {
        proxyStateStore.save(primaryCandidate);
      }

      final label = connectedLabel();
      _set(
        state: ConnectionState.connected,
        statusKind: label.kind,
        statusDetail: label.detail,
      );
      AppLogger.i(
        _tag,
        'connect: CONNECTED via ${establishedCandidate.authority}',
      );

      unawaited(_proxyPassRenewalLoop(myGeneration, currentPassExpiry));

      if (settingsStore.exitCheckEnabled) {
        unawaited(() async {
          final session = _upstreamSession;
          if (session == null) return;
          final observed = await ExitCheck().verifyExitCountry(
            session,
            establishedCandidate.countryCode,
          );
          if (observed != null && myGeneration == _generation) {
            AppLogger.i(_tag, 'exit check: observed country=$observed');
          }
        }());
      }

      if (!proxyOnlyMode) {
        _startSpeedUpdates(socks);
      }

      unawaited(
        _watchdogLoop(
          myGeneration,
          dialUpstream,
          rotateCandidate,
          connectedLabel,
        ),
      );
    } on _SupersededException {
      AppLogger.i(
        _tag,
        'connect: aborted because the connection was cancelled',
      );
    } catch (failure) {
      if (_generation == myGeneration) {
        final message = failure is TimeoutException
            ? 'Connection timed out. Check your network and try again.'
            : _friendlyErrorMessage(failure);
        AppLogger.e(_tag, 'connect failed', failure);
        _lastError = message;
        await _teardownAfterFailure();
      }
    }
  }

  int? _currentPassExpiry;

  void _updateQuota(ProxyPass pass) {
    _quotaRemainingBytes = pass.quotaRemaining;
    _quotaMaxBytes = pass.quotaMax;
  }

  Future<void> _proxyPassRenewalLoop(
    int myGeneration,
    int? initialExpiry,
  ) async {
    var expiry = initialExpiry;
    AppLogger.i(
      _tag,
      'proxy pass renewal scheduled in '
      '${_proxyPassRenewalDelayMs(expiry) ~/ 1000}s '
      '${expiry == null ? "(pass lifetime unknown; using a fixed interval)" : "(at half of its remaining life)"}',
    );
    while (_generation == myGeneration) {
      await Future<void>.delayed(
        Duration(milliseconds: _proxyPassRenewalDelayMs(expiry)),
      );
      if (_generation != myGeneration) return;

      final session = _upstreamSession;
      if (session == null || !session.isConnected) {
        AppLogger.d(
          _tag,
          'skipping proxy pass renewal: no live session (the watchdog\'s '
          'redial mints its own)',
        );
        continue;
      }

      ProxyPass? pass;
      try {
        pass = await _mintProxyPass();
      } catch (error) {
        if (_isFatalUpstreamError(error)) {
          AppLogger.e(
            _tag,
            'proxy pass renewal failed for a reason retrying cannot fix; '
            'leaving the session to the watchdog',
            error,
          );
          return;
        }
        AppLogger.w(
          _tag,
          'proxy pass renewal failed; retrying shortly: $error',
        );
        expiry = null;
        await Future<void>.delayed(
          const Duration(milliseconds: _proxyPassRenewalRetryMs),
        );
        continue;
      }

      if (_generation != myGeneration) return;
      _updateQuota(pass);

      final live = _upstreamSession;
      if (live == null || !live.isConnected) {
        AppLogger.d(
          _tag,
          'minted a fresh proxy pass but the session went down meanwhile; '
          'the watchdog\'s redial will mint its own',
        );
        expiry = pass.expiresAtEpochSeconds;
        continue;
      }

      final lifetimeNote = pass.expiresAtEpochSeconds != null
          ? ' (valid for '
                '${(pass.expiresAtEpochSeconds! * 1000 - DateTime.now().millisecondsSinceEpoch) ~/ 1000}s)'
          : ' (lifetime not stated)';
      live.updateBearerToken(pass.token);
      AppLogger.i(
        _tag,
        'proxy pass renewed in place$lifetimeNote; the tunnel was not rebuilt',
      );
      expiry = pass.expiresAtEpochSeconds;
      notifyListeners();
    }
  }

  Future<void> _watchdogLoop(
    int myGeneration,
    Future<H2UpstreamSession> Function() dialUpstream,
    Future<bool> Function() rotateCandidate,
    ({VpnStatusKind kind, String detail}) Function() connectedLabel,
  ) async {
    var consecutiveFailures = 0;
    var waitingForNetwork = false;

    while (_generation == myGeneration) {
      await Future<void>.delayed(_watchdogInterval);
      if (_generation != myGeneration) return;

      final current = _upstreamSession;
      if (current != null && current.isConnected) {
        if (consecutiveFailures > 0 || waitingForNetwork) {
          AppLogger.i(_tag, 'upstream tunnel is healthy again');
          final label = connectedLabel();
          _set(
            statusKind: label.kind,
            statusDetail: label.detail,
            clearError: true,
          );
        }
        consecutiveFailures = 0;
        waitingForNetwork = false;
        continue;
      }

      if (!await _hasUsableNetwork()) {
        if (!waitingForNetwork) {
          AppLogger.i(
            _tag,
            'no usable network; holding the session and waiting for connectivity',
          );
          waitingForNetwork = true;
          _set(statusKind: VpnStatusKind.waitingForNetwork);
        }
        consecutiveFailures = 0;
        continue;
      }
      if (waitingForNetwork) {
        AppLogger.i(_tag, 'network is back; redialing the upstream tunnel');
        waitingForNetwork = false;
      }

      AppLogger.w(_tag, 'upstream tunnel is down; attempting to reconnect');
      try {
        await current?.close();
      } catch (_) {}
      _set(statusKind: VpnStatusKind.reconnecting);

      H2UpstreamSession? fresh;
      try {
        fresh = await dialUpstream();
      } on TimeoutException {
        consecutiveFailures++;
        AppLogger.w(
          _tag,
          'upstream reconnect attempt $consecutiveFailures timed out',
        );
      } catch (error) {
        if (_isFatalUpstreamError(error)) {
          AppLogger.e(
            _tag,
            'unrecoverable upstream failure; disconnecting: '
            '${_friendlyErrorMessage(error)}',
          );
          _lastError = _friendlyErrorMessage(error);
          ++_generation;
          await _releaseResources(myGeneration);
          _set(
            state: ConnectionState.disconnected,
            statusKind: VpnStatusKind.disconnected,
            statusDetail: '',
          );
          return;
        }
        consecutiveFailures++;
        AppLogger.w(
          _tag,
          'upstream reconnect attempt $consecutiveFailures failed: $error',
        );
      }

      if (fresh == null) {
        if (consecutiveFailures % _reconnectFailuresBeforeEdgeRotation == 0) {
          await rotateCandidate();
        }
        if (consecutiveFailures == _reconnectFailuresBeforeWarning) {
          _set(
            lastError:
                'Still trying to reconnect to the VPN server. Use Disconnect to stop.',
          );
          AppLogger.e(
            _tag,
            '$consecutiveFailures consecutive reconnect failures; continuing '
            'to retry with backoff (capped at '
            '${_reconnectBackoffCapMs ~/ 1000}s between attempts)',
          );
        }
        await Future<void>.delayed(
          Duration(
            milliseconds: _fullJitterBackoffMs(
              consecutiveFailures - 1,
              _reconnectBackoffBaseMs,
              _reconnectBackoffCapMs,
            ),
          ),
        );
        continue;
      }

      if (_generation != myGeneration) {
        AppLogger.i(
          _tag,
          'discarding stale reconnect from a torn-down session generation',
        );
        try {
          await fresh.close();
        } catch (_) {}
        return;
      }
      _upstreamSession = fresh;
      consecutiveFailures = 0;
      final label = connectedLabel();
      _set(
        statusKind: label.kind,
        statusDetail: label.detail,
        clearError: true,
      );
      AppLogger.i(_tag, 'upstream tunnel reconnected');

      unawaited(_proxyPassRenewalLoop(myGeneration, _currentPassExpiry));
    }
  }

  Future<bool> _hasUsableNetwork() async {
    try {
      await InternetAddress.lookup(
        RouteManager.controlPlaneHosts.first,
      ).timeout(const Duration(seconds: 3));
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    } catch (_) {
      return true;
    }
  }

  void _startSpeedUpdates(LocalSocks5Server socks) {
    _speedTimer?.cancel();
    var lastDownload = socks.downloadBytes;
    var lastUpload = socks.uploadBytes;
    var lastSampleAt = DateTime.now().millisecondsSinceEpoch;
    _speedTimer = Timer.periodic(
      const Duration(milliseconds: _speedUpdateIntervalMs),
      (_) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final elapsedSeconds = max(now - lastSampleAt, 1) / 1000.0;
        _downloadBytesPerSecond =
            max(socks.downloadBytes - lastDownload, 0) ~/ elapsedSeconds;
        _uploadBytesPerSecond =
            max(socks.uploadBytes - lastUpload, 0) ~/ elapsedSeconds;
        lastDownload = socks.downloadBytes;
        lastUpload = socks.uploadBytes;
        lastSampleAt = now;
        if (_state == ConnectionState.connected) notifyListeners();
      },
    );
  }

  Future<ProxyPass> _mintProxyPass() async {
    final tokenStore = TokenStore.instance;
    var auth = await tokenStore.loadAuth();
    if (auth == null) throw TokenInvalidError('Not signed in');

    if (!tokenStore.hasValidAccessToken()) {
      final renewed = await FxaAuthRepository(tokenStore).refreshAccessToken();
      if (renewed != null) {
        auth = renewed;
        AppLogger.i(
          _tag,
          "the account's access token had expired and was renewed",
        );
      } else {
        AppLogger.w(
          _tag,
          "the account's access token is past its expiry and could not be "
          'renewed automatically; you may need to sign in again',
        );
      }
    }
    final guardian = GuardianClient();
    try {
      return await guardian.fetchProxyPass(
        guardianEndpointDefault,
        auth.accessToken,
      );
    } on TokenInvalidError catch (invalid) {
      AppLogger.w(
        _tag,
        'proxy pass rejected, activating Guardian entitlement and retrying',
        invalid,
      );
      await guardian.activateGuardian(
        guardianEndpointDefault,
        auth.accessToken,
      );
      return guardian.fetchProxyPass(guardianEndpointDefault, auth.accessToken);
    }
  }

  Future<ProxyCandidate> _resolveConnectCandidate(
    ProxyStateStore proxyStateStore,
    int myGeneration,
  ) async {
    final saved = proxyStateStore.load();
    if (saved != null) return saved;
    AppLogger.i(
      _tag,
      'connect: no server previously selected; auto-selecting recommended location',
    );
    final countries = await ServerListClient().fetchCountries().timeout(
      _serverListFetchTimeout,
    );
    _ensureGenerationCurrent(myGeneration);
    final random = Random();
    final recommended = ServerListClient.candidatesForCountry(
      countries,
      recommendedCountryCode,
    );
    var chosen = recommended.isNotEmpty
        ? recommended[random.nextInt(recommended.length)]
        : null;
    if (chosen == null) {
      for (final country in countries) {
        if (country.code.isEmpty) continue;
        final pool = ServerListClient.candidatesForCountry(
          countries,
          country.code,
        );
        if (pool.isNotEmpty) {
          chosen = pool[random.nextInt(pool.length)];
          break;
        }
      }
    }
    if (chosen == null) {
      throw StateError(
        'No server selected and no servers are available. Choose a location first.',
      );
    }
    proxyStateStore.save(chosen);
    AppLogger.i(
      _tag,
      'connect: auto-selected ${chosen.authority} country=${chosen.countryCode}',
    );
    return chosen;
  }

  Future<List<ProxyCandidate>> _discoverAlternateCandidates(
    ProxyCandidate primary,
  ) async {
    try {
      final countries = await ServerListClient().fetchCountries().timeout(
        _serverListFetchTimeout,
      );
      final sameCity = ServerListClient.candidatesForCity(
        countries,
        primary.countryCode,
        primary.cityCode,
      );
      final sameCountry = ServerListClient.candidatesForCountry(
        countries,
        primary.countryCode,
      );
      final seen = <String>{};
      return [...sameCity, ...sameCountry]
          .where(
            (c) => c.authority != primary.authority && seen.add(c.authority),
          )
          .toList();
    } catch (failure) {
      AppLogger.w(
        _tag,
        'could not fetch alternate edges; staying with ${primary.authority}',
        failure,
      );
      return [];
    }
  }

  Future<String?> _resolveEdgeAddress(
    String host,
    UpstreamProxyConfig? upstreamProxy,
    List<String> dohEndpointAddresses,
  ) async {
    if (upstreamProxy != null) return null;
    if (dohEndpointAddresses.isEmpty) return null;
    return EdgeAddressResolver.resolve(host, dohEndpointAddresses);
  }

  Future<UpstreamProxyConfig?> _buildUpstreamProxyConfig(
    SettingsStore settingsStore,
  ) async {
    if (!settingsStore.upstreamProxyEnabled ||
        settingsStore.upstreamProxyHost.trim().isEmpty) {
      return null;
    }
    final username = await settingsStore.upstreamProxyUsername;
    final password = await settingsStore.upstreamProxyPassword;
    return UpstreamProxyConfig(
      type: settingsStore.upstreamProxyType,
      host: settingsStore.upstreamProxyHost,
      port: settingsStore.upstreamProxyPort,
      username: username.isEmpty ? null : username,
      password: password.isEmpty ? null : password,
    );
  }

  String _friendlyErrorMessage(Object error) {
    if (error is QuotaExceededError) {
      return 'Your VPN quota is exhausted. Try again later.';
    }
    if (error is TokenInvalidError) {
      return 'Your session was rejected. Please sign in again.';
    }
    if (error is TimeoutException) return 'the connection timed out';
    if (error is StateError) return error.message;
    return error.toString();
  }

  Future<void> _teardownAfterFailure() async {
    final endedGeneration = _generation;
    _speedTimer?.cancel();
    _speedTimer = null;
    _downloadBytesPerSecond = 0;
    _uploadBytesPerSecond = 0;
    await _releaseResources(endedGeneration);
    _set(
      state: ConnectionState.disconnected,
      statusKind: VpnStatusKind.disconnected,
      statusDetail: '',
    );
  }

  /// Stops the native tunnel, removes bypass routes, closes the SOCKS
  /// frontend and the upstream session. Safe to call twice.
  Future<void> _releaseResources(int endedGeneration) async {
    _currentPassExpiry = null;

    final socks = _socksServer;
    _socksServer = null;
    _localProxyEndpoint = null;
    final session = _upstreamSession;
    _upstreamSession = null;

    // Only stop the OS-level pieces if no newer connect took over meanwhile.
    final stillOurs =
        _generation == endedGeneration ||
        _state == ConnectionState.disconnected;

    if (session != null) {
      try {
        await session.close();
      } catch (e) {
        AppLogger.w(_tag, 'error closing the upstream session', e);
      }
    }
    if (socks != null) {
      try {
        await socks.stop();
      } catch (e) {
        AppLogger.w(_tag, 'error stopping the local SOCKS5 server', e);
      }
    }
    if (stillOurs) {
      try {
        await SystemProxyManager.instance.restore();
      } catch (e) {
        AppLogger.w(_tag, 'error restoring the Windows system proxy', e);
      }
      ControlPlaneHttp.useProxy(socks5: false);
      // Undo the OS takeover while the wintun adapter still exists, then
      // stop the engine, then drop the bypass routes.
      try {
        await RouteManager.instance.releaseTunnel();
      } catch (e) {
        AppLogger.w(_tag, 'error releasing route/DNS takeover', e);
      }
      try {
        await HevSocks5Tunnel.stop();
      } catch (e) {
        AppLogger.w(_tag, 'error stopping the tun2socks tunnel', e);
      }
      try {
        await RouteManager.instance.disable();
      } catch (e) {
        AppLogger.w(_tag, 'error removing bypass routes', e);
      }
    }
  }
}
