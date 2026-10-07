import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/app_logger.dart';
import 'hev_socks5_tunnel.dart';
import 'socket_byte_reader.dart';
import 'socks5_udp_dns_relay.dart';
import 'upstream_health_tracker.dart';
import 'upstream_session.dart';

const String _tag = 'LocalSocks5Server';

const Duration _sessionWaitTimeout = Duration(seconds: 4);
const Duration _sessionWaitPollInterval = Duration(milliseconds: 100);
const Duration _openStreamTimeout = Duration(seconds: 30);
const Duration _handshakeTimeout = Duration(seconds: 10);
const int _maxConcurrentClientConnections = 512;
const int _unreachableTargetTtlMs = 30 * 1000;
const int _unreachableTargetTtlCapMs = 10 * 60 * 1000;
const int _refusalsBeforeTreatingAsPolicy = 3;
const int _unreachableTargetCacheCap = 256;

class _RefusalRecord {
  int strikes = 0;
  int expiresAt = 0;
}

/// Port of Android's `LocalSocks5Server`: the local frontend that
/// hev-socks5-tunnel (or a proxy-only client) talks to. Every CONNECT
/// becomes one HTTP/2 stream on the upstream session. The port is mixed:
/// SOCKS5 when the first byte is 0x05, otherwise plain HTTP proxying
/// (CONNECT and absolute-URI requests) so the Windows *system* proxy — which
/// only understands HTTP — can point at it too.
class LocalSocks5Server {
  LocalSocks5Server({
    required this.bindAddress,
    required this.port,
    required this.rejectFakeDnsAddresses,
    required this.sessionProvider,
    this.onSessionUnhealthy,
  });

  final String bindAddress;
  final int port;
  final bool rejectFakeDnsAddresses;
  final UpstreamSession? Function() sessionProvider;
  final void Function()? onSessionUnhealthy;

  ServerSocket? _serverSocket;
  int _activeConnections = 0;
  bool _stopping = false;

  /// The port actually bound (port 0 in the constructor means OS-chosen).
  int get boundPort => _serverSocket?.port ?? port;

  final UpstreamHealthTracker _health = UpstreamHealthTracker();
  final LinkedHashMap<String, _RefusalRecord> _unreachableTargets =
      LinkedHashMap<String, _RefusalRecord>();

  UpstreamSession? _unauthenticatedSession;

  int _upstreamFailures = 0;
  int _lastFailureSummaryAt = DateTime.now().millisecondsSinceEpoch;
  int _staleFakeIpRejections = 0;
  int _localNetworkRejections = 0;
  int _cachedRefusalRejections = 0;
  int _declinedDestinations = 0;
  int _sessionAuthRejections = 0;

  /// Traffic counters (used for the speed readout; hev's native stats are
  /// not reachable from Dart on Windows).
  int downloadBytes = 0;
  int uploadBytes = 0;

  Future<void> start() async {
    final server = await ServerSocket.bind(
        InternetAddress(bindAddress), port, backlog: 256);
    _serverSocket = server;
    AppLogger.i(_tag,
        'listening on $bindAddress:$port (SOCKS5 + HTTP proxy)');
    server.listen(
      (client) {
        if (_stopping) {
          client.destroy();
          return;
        }
        if (_activeConnections >= _maxConcurrentClientConnections) {
          AppLogger.w(_tag,
              'rejecting SOCKS5 client: connection limit '
              '($_maxConcurrentClientConnections) reached');
          client.destroy();
          return;
        }
        _activeConnections++;
        _handleClient(client).whenComplete(() => _activeConnections--);
      },
      onError: (Object e) {
        if (!_stopping) AppLogger.w(_tag, 'accept() failed', e);
      },
    );
  }

  Future<void> stop() async {
    _stopping = true;
    try {
      await _serverSocket?.close();
    } catch (_) {}
    _serverSocket = null;
    _unreachableTargets.clear();
    _health.reset();
    _unauthenticatedSession = null;

    if (_staleFakeIpRejections > 0) {
      AppLogger.i(_tag,
          '$_staleFakeIpRejections connection(s) were refused because they '
          'targeted a synthetic DNS address with no live mapping');
    }
    if (_localNetworkRejections > 0) {
      AppLogger.i(_tag,
          '$_localNetworkRejections connection(s) to local-network addresses '
          'were refused on-device');
    }
    if (_cachedRefusalRejections > 0) {
      AppLogger.d(_tag,
          '$_cachedRefusalRejections connection(s) were refused immediately '
          'because the edge had recently refused the same destination');
    }
    if (_declinedDestinations > 0) {
      AppLogger.d(_tag,
          '$_declinedDestinations connection(s) were declined by the edge '
          '(an edge policy, not a tunnel fault)');
    }
    if (_sessionAuthRejections > 0) {
      AppLogger.i(_tag,
          '$_sessionAuthRejections connection(s) were refused while the '
          'tunnel\'s proxy pass was being rejected by the edge');
    }
    if (_upstreamFailures > 0) {
      AppLogger.w(_tag,
          '$_upstreamFailures connection(s) failed upstream in this session');
    }
  }

  Future<UpstreamSession?> _awaitUsableSession() async {
    final deadline =
        DateTime.now().add(_sessionWaitTimeout).millisecondsSinceEpoch;
    while (true) {
      final session = sessionProvider();
      if (session != null && session.isConnected) return session;
      if (DateTime.now().millisecondsSinceEpoch >= deadline) return null;
      await Future<void>.delayed(_sessionWaitPollInterval);
    }
  }

  Future<void> _handleClient(Socket client) async {
    client.setOption(SocketOption.tcpNoDelay, true);
    try {
      await _handleClientOrThrow(client);
    } on SocketException catch (e) {
      AppLogger.d(_tag, 'SOCKS5 client socket closed: ${e.message}');
    } catch (e) {
      AppLogger.d(_tag, 'error handling SOCKS5 client: $e');
    } finally {
      try {
        client.destroy();
      } catch (_) {}
    }
  }

  Future<void> _handleClientOrThrow(Socket client) async {
    final reader = SocketByteReader(client);
    final first = await reader.readUnsignedByte().timeout(_handshakeTimeout);
    if (first == 0x05) {
      await _handleSocksClient(client, reader);
    } else if (_isHttpMethodByte(first)) {
      await _handleHttpClient(client, reader, first);
    } else {
      AppLogger.d(_tag, 'rejecting client: unsupported protocol byte $first');
    }
  }

  /// G P H C D O T U N M — first letters of GET/POST/HEAD/CONNECT/DELETE/
  /// OPTIONS/TRACE/PUT; never 0x05 (SOCKS5 version).
  static bool _isHttpMethodByte(int byte) =>
      byte >= 0x41 && byte <= 0x5A && const {
            0x47, 0x50, 0x48, 0x43, 0x44, 0x4F, 0x54, 0x55, 0x4E, 0x4D,
          }.contains(byte);

  Future<void> _handleSocksClient(Socket client, SocketByteReader reader) async {
    Future<void> writeReply(int replyCode,
        {List<int>? boundAddress, int boundPort = 0}) async {
      client.add(socksReply(replyCode,
          boundAddress: boundAddress, boundPort: boundPort));
      await client.flush();
    }

    final nMethods = await reader.readUnsignedByte();
    final methods = nMethods > 0 ? await reader.readBytes(nMethods) : <int>[];
    if (!methods.contains(0x00)) {
      await writeReply(0xFF);
      return;
    }
    client.add([0x05, 0x00]);
    await client.flush();

    final reqVer = await reader.readUnsignedByte();
    if (reqVer != 0x05) {
      await writeReply(0x07);
      return;
    }
    final cmd = await reader.readUnsignedByte();
    await reader.readUnsignedByte(); // reserved

    switch (cmd) {
      case 0x01:
        await _handleConnect(client, reader, writeReply);
      case 0x03:
        await _handleUdpAssociate(client, reader, writeReply);
      default:
        await writeReply(0x07);
    }
  }

  Future<void> _handleConnect(
    Socket client,
    SocketByteReader reader,
    Future<void> Function(int, {List<int>? boundAddress, int boundPort})
        writeReply,
  ) async {
    _Socks5Target? target;
    try {
      target = await _readTargetAddress(reader);
    } catch (_) {
      await writeReply(0x08);
      return;
    }

    final attempt = await _openUpstreamStream(target.host, target.port,
        sourceLiteral: target.literal);
    switch (attempt.deny) {
      case _Deny.fakeDns:
        await writeReply(0x04);
        return;
      case _Deny.localNetwork:
        await writeReply(0x02);
        return;
      case _Deny.cachedUnreachable:
        await writeReply(0x04);
        return;
      case _Deny.noSession:
        await writeReply(0x05);
        return;
      case _Deny.authLatched:
        await writeReply(0x01);
        return;
      case null:
        break;
    }

    final tunneled = attempt.stream;
    if (tunneled == null) {
      await writeReply(_replyCodeFor(attempt.cause));
      return;
    }

    await writeReply(0x00,
        boundAddress: _addressBytes(client.address),
        boundPort: client.port);
    await _relay(client, reader, tunneled);
  }

  // ---- HTTP proxy frontend (system proxy) ---------------------------------

  Future<void> _handleHttpClient(
      Socket client, SocketByteReader reader, int firstByte) async {
    reader.unreadBytes([firstByte]);
    final String headText;
    try {
      headText = await reader.readUntilHeaderEnd().timeout(_handshakeTimeout);
    } catch (_) {
      return;
    }
    final lines = headText.split('\r\n');
    final parts = lines.first.split(' ');
    if (parts.length < 3) {
      await _httpReply(client, 400, 'Bad Request');
      return;
    }
    final method = parts[0].toUpperCase();
    final rawTarget = parts[1];

    final String host;
    final int port;
    final bool connectMode;
    Uri? absolute;
    if (method == 'CONNECT') {
      final split = _splitHostPort(rawTarget);
      if (split == null) {
        await _httpReply(client, 400, 'Bad Request');
        return;
      }
      host = split.$1;
      port = split.$2;
      connectMode = true;
    } else if (rawTarget.startsWith('http://') ||
        rawTarget.startsWith('HTTP://')) {
      absolute = Uri.tryParse(rawTarget);
      if (absolute == null || absolute.host.isEmpty) {
        await _httpReply(client, 400, 'Bad Request');
        return;
      }
      host = absolute.host;
      port = absolute.port;
      connectMode = false;
    } else {
      // Origin-form request: the client thinks this is a transparent proxy.
      await _httpReply(client, 400, 'Bad Request');
      return;
    }

    final attempt = await _openUpstreamStream(host, port);
    final tunneled = attempt.stream;
    if (tunneled == null) {
      final forbidden = attempt.deny == _Deny.fakeDns ||
          attempt.deny == _Deny.localNetwork;
      await _httpReply(client, forbidden ? 403 : 502,
          forbidden ? 'Forbidden' : 'Bad Gateway');
      return;
    }

    if (connectMode) {
      await _httpReply(client, 200, 'Connection Established');
      await _relay(client, reader, tunneled);
      return;
    }

    // Absolute-URI request: rewrite to origin-form for the destination and
    // drop proxy-hop headers before forwarding.
    final path = absolute!.path.isEmpty ? '/' : absolute.path;
    final query = absolute.query.isEmpty ? '' : '?${absolute.query}';
    final rewritten = <String>[
      '${parts[0]} $path$query ${parts[2]}',
      for (final header in lines.skip(1))
        if (!header.toLowerCase().startsWith('proxy-authorization:')) header,
    ];
    await _relay(client, reader, tunneled,
        forwardFirst: utf8.encode('${rewritten.join('\r\n')}\r\n\r\n'));
  }

  Future<void> _httpReply(Socket client, int status, String reason) async {
    client.add(utf8.encode('HTTP/1.1 $status $reason\r\n'
        'Content-Length: 0\r\nConnection: close\r\n\r\n'));
    await client.flush();
  }

  static (String, int)? _splitHostPort(String authority) {
    final colon = authority.lastIndexOf(':');
    if (colon <= 0) return null;
    final port = int.tryParse(authority.substring(colon + 1));
    if (port == null || port <= 0 || port > 65535) return null;
    var host = authority.substring(0, colon);
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    return (host, port);
  }

  // ---- shared upstream plumbing ------------------------------------------

  Future<_StreamAttempt> _openUpstreamStream(
    String targetHost,
    int targetPort, {
    InternetAddress? sourceLiteral,
  }) async {
    final targetKey = '$targetHost:$targetPort';

    if (rejectFakeDnsAddresses &&
        HevSocks5Tunnel.isFakeDnsAddress(targetHost)) {
      _staleFakeIpRejections++;
      AppLogger.d(_tag,
          'refusing $targetKey: synthetic DNS address with no live mapping');
      return const _StreamAttempt(deny: _Deny.fakeDns);
    }

    final literal = sourceLiteral ?? InternetAddress.tryParse(targetHost);
    if (literal != null && _isLocalNetworkDestination(literal)) {
      _localNetworkRejections++;
      AppLogger.d(_tag, 'refusing $targetKey: local-network address');
      return const _StreamAttempt(deny: _Deny.localNetwork);
    }

    if (_isKnownUnreachable(targetKey)) {
      _cachedRefusalRejections++;
      AppLogger.d(_tag, 'refusing $targetKey: the edge refused it moments ago');
      return const _StreamAttempt(deny: _Deny.cachedUnreachable);
    }

    final session = await _awaitUsableSession();
    if (session == null) {
      return const _StreamAttempt(deny: _Deny.noSession);
    }
    if (identical(session, _unauthenticatedSession)) {
      _sessionAuthRejections++;
      return const _StreamAttempt(deny: _Deny.authLatched);
    }

    TunneledStream? tunneled;
    Object? cause;
    try {
      tunneled = await session
          .openStream(targetHost, targetPort)
          .timeout(_openStreamTimeout);
    } on TimeoutException {
      cause = UpstreamConnectTimeoutException(
          authority: targetKey, message: 'timed out opening $targetKey');
    } catch (e) {
      cause = e;
    }

    if (tunneled != null) {
      _health.observeSuccess();
      _forgetUnreachable(targetKey);
      if (_unauthenticatedSession != null &&
          !identical(session, _unauthenticatedSession)) {
        _unauthenticatedSession = null;
      }
      return _StreamAttempt(stream: tunneled);
    }

    final declinedByEdge = _shouldRememberRefusal(cause);
    if (declinedByEdge) _rememberUnreachable(targetKey);
    _recordUpstreamFailure(targetKey, cause, declinedByEdge: declinedByEdge);

    switch (_health.observeFailure(targetKey, cause)) {
      case HealthVerdict.targetFailure:
        break;
      case HealthVerdict.sessionUnhealthy:
        AppLogger.w(_tag,
            'upstream session looks unhealthy: several unrelated '
            'destinations failed; asking for a redial');
        onSessionUnhealthy?.call();
      case HealthVerdict.sessionUnauthenticated:
        final alreadyLatched = identical(session, _unauthenticatedSession);
        _unauthenticatedSession = session;
        if (!alreadyLatched) {
          AppLogger.w(_tag,
              'the edge rejected this session\'s proxy pass ($cause); '
              'refusing further flows locally and asking for a redial');
        }
        onSessionUnhealthy?.call();
    }
    return _StreamAttempt(cause: cause);
  }

  Future<void> _relay(
    Socket client,
    SocketByteReader reader,
    TunneledStream tunneled, {
    List<int>? forwardFirst,
  }) async {
    if (forwardFirst != null) {
      uploadBytes += forwardFirst.length;
      tunneled.output.add(forwardFirst);
    }

    // Relay: client -> upstream.
    final upstreamDone = Completer<void>();
    late final StreamSubscription<List<int>> upstreamSub;
    upstreamSub = reader.rest().listen(
      (bytes) {
        uploadBytes += bytes.length;
        tunneled.output.add(bytes);
      },
      onDone: () {
        tunneled.output.close();
        if (!upstreamDone.isCompleted) upstreamDone.complete();
      },
      onError: (Object _) {
        if (!upstreamDone.isCompleted) upstreamDone.complete();
      },
      cancelOnError: true,
    );

    // Relay: upstream -> client.
    try {
      await for (final bytes in tunneled.input) {
        downloadBytes += bytes.length;
        client.add(bytes);
      }
      await client.flush();
      await client.close(); // half-close toward the client
    } catch (_) {
    } finally {
      await upstreamDone.future
          .timeout(const Duration(minutes: 2), onTimeout: () {});
      await upstreamSub.cancel();
      tunneled.close();
    }
  }

  Future<void> _handleUdpAssociate(
    Socket client,
    SocketByteReader reader,
    Future<void> Function(int, {List<int>? boundAddress, int boundPort})
        writeReply,
  ) async {
    _Socks5Target? target;
    try {
      target = await _readTargetAddress(reader);
    } catch (_) {
      await writeReply(0x08);
      return;
    }
    final requestedPort = target.port;
    if (requestedPort != dnsPort && requestedPort != 0) {
      await writeReply(0x02);
      return;
    }

    final session = await _awaitUsableSession();
    if (session == null) {
      await writeReply(0x05);
      return;
    }
    if (identical(session, _unauthenticatedSession)) {
      _sessionAuthRejections++;
      await writeReply(0x01);
      return;
    }

    Socks5UdpDnsRelay? relay;
    try {
      relay = Socks5UdpDnsRelay(
        bindAddress: client.address,
        clientAddress: client.address,
        sessionProvider: sessionProvider,
      );
      await relay.start();
    } catch (e) {
      AppLogger.d(_tag, 'could not start the UDP DNS relay: $e');
      await writeReply(0x01);
      return;
    }

    try {
      await writeReply(0x00,
          boundAddress: _addressBytes(relay.boundAddress),
          boundPort: relay.boundPort);
      // Keep the association alive until the client closes the TCP side.
      final rest = reader.rest();
      await for (final _ in rest) {}
    } catch (_) {
    } finally {
      await relay.stop();
    }
  }

  void _recordUpstreamFailure(String target, Object? cause,
      {bool declinedByEdge = false}) {
    AppLogger.d(_tag, 'opening upstream stream failed for $target: $cause');
    if (declinedByEdge) {
      _declinedDestinations++;
      return;
    }
    _upstreamFailures++;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastFailureSummaryAt < 15000) return;
    _lastFailureSummaryAt = now;
    AppLogger.w(_tag, 'recent upstream failures; most recent: $target -- $cause');
  }

  bool _shouldRememberRefusal(Object? cause) {
    if (cause is! UpstreamConnectRejectedException) return false;
    final status = cause.statusCode;
    return status != null &&
        UpstreamHealthTracker.targetUnreachableStatusCodes.contains(status);
  }

  bool _isKnownUnreachable(String key) {
    final record = _unreachableTargets[key];
    if (record == null) return false;
    return DateTime.now().millisecondsSinceEpoch < record.expiresAt;
  }

  void _rememberUnreachable(String key) {
    final record = _unreachableTargets.putIfAbsent(key, () => _RefusalRecord());
    record.strikes++;
    final shift = (record.strikes - 1).clamp(0, 16);
    var backoffMs = _unreachableTargetTtlMs << shift;
    if (backoffMs > _unreachableTargetTtlCapMs) {
      backoffMs = _unreachableTargetTtlCapMs;
    }
    record.expiresAt = DateTime.now().millisecondsSinceEpoch + backoffMs;
    if (_unreachableTargets.length > _unreachableTargetCacheCap) {
      _unreachableTargets.remove(_unreachableTargets.keys.first);
    }
    if (record.strikes == _refusalsBeforeTreatingAsPolicy) {
      AppLogger.d(_tag,
          'the edge has refused $key ${record.strikes} times in a row; '
          'further attempts will be refused on-device with a backoff');
    }
  }

  void _forgetUnreachable(String key) {
    if (_unreachableTargets.remove(key) != null) {
      AppLogger.d(_tag, '$key succeeded; clearing its refusal backoff');
    }
  }

  int _replyCodeFor(Object? cause) {
    if (cause == null || cause is UpstreamConnectTimeoutException) return 0x06;
    if (cause is! UpstreamConnectRejectedException) return 0x01;
    final status = cause.statusCode;
    if (status == null) return 0x01;
    if (UpstreamHealthTracker.targetUnreachableStatusCodes.contains(status)) {
      return 0x04;
    }
    return 0x01;
  }

  Future<_Socks5Target> _readTargetAddress(SocketByteReader reader) async {
    final addrType = await reader.readUnsignedByte();
    String host;
    InternetAddress? literal;
    switch (addrType) {
      case 0x01:
        final bytes = await reader.readBytes(4);
        literal = InternetAddress.fromRawAddress(Uint8List.fromList(bytes));
        host = bytes.join('.');
      case 0x03:
        final len = await reader.readUnsignedByte();
        if (len == 0) throw const FormatException('empty SOCKS5 domain name');
        final bytes = await reader.readBytes(len);
        host = String.fromCharCodes(bytes);
      case 0x04:
        final bytes = await reader.readBytes(16);
        literal = InternetAddress.fromRawAddress(Uint8List.fromList(bytes));
        host = literal.address;
      default:
        throw FormatException('unsupported SOCKS5 address type $addrType');
    }
    final port = await reader.readUnsignedShort();
    return _Socks5Target(host, port, literal);
  }

  static List<int> _addressBytes(InternetAddress address) {
    try {
      return address.rawAddress;
    } catch (_) {
      return [0, 0, 0, 0];
    }
  }

  static bool _isLocalNetworkDestination(InternetAddress address) {
    if (address.isLoopback ||
        address.isLinkLocal ||
        address.isMulticast ||
        _isSiteLocal(address)) {
      return true;
    }
    final raw = address.rawAddress;
    if (raw.length == 16) return (raw[0] & 0xFE) == 0xFC; // fc00::/7
    return false;
  }

  static bool _isSiteLocal(InternetAddress address) {
    final raw = address.rawAddress;
    if (raw.length != 4) return false;
    if (raw[0] == 10) return true;
    if (raw[0] == 172 && raw[1] >= 16 && raw[1] <= 31) return true;
    if (raw[0] == 192 && raw[1] == 168) return true;
    return false;
  }
}

class _Socks5Target {
  const _Socks5Target(this.host, this.port, this.literal);

  final String host;
  final int port;
  final InternetAddress? literal;
}

enum _Deny { fakeDns, localNetwork, cachedUnreachable, noSession, authLatched }

class _StreamAttempt {
  const _StreamAttempt({this.stream, this.deny, this.cause});

  final TunneledStream? stream;
  final _Deny? deny;
  final Object? cause;
}

List<int> socksReply(int replyCode,
    {List<int>? boundAddress, int boundPort = 0}) {
  final addressBytes = boundAddress ?? [0, 0, 0, 0];
  final addressType = addressBytes.length == 16 ? 0x04 : 0x01;
  return [
    0x05,
    replyCode,
    0x00,
    addressType,
    ...addressBytes,
    (boundPort >> 8) & 0xFF,
    boundPort & 0xFF,
  ];
}
