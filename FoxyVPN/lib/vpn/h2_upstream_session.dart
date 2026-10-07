import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http2/transport.dart';

import '../core/app_logger.dart';
import '../data/settings_store.dart';
import 'route_manager.dart';
import 'socket_byte_reader.dart';
import 'upstream_session.dart';

const String _tag = 'H2UpstreamSession';

const Duration _keepaliveCheckInterval = Duration(seconds: 3);
const Duration _keepaliveIdleThreshold = Duration(seconds: 15);
const Duration _keepalivePingTimeout = Duration(seconds: 10);

const Duration _openStreamTimeout = Duration(seconds: 20);
const Duration _tcpConnectTimeout = Duration(seconds: 15);

const int _http2FlowControlWindowBytes = 16 * 1024 * 1024;

class UpstreamProxyConfig {
  const UpstreamProxyConfig({
    required this.type,
    required this.host,
    required this.port,
    this.username,
    this.password,
  });

  final UpstreamProxyType type;
  final String host;
  final int port;
  final String? username;
  final String? password;

  String get address => '$host:$port';
}

/// Port of Android's `H2UpstreamSession`: one TLS/ALPN-h2 connection to the
/// Fastly edge; every tunnel flow is an HTTP/2 CONNECT stream carrying a
/// `proxy-authorization: Bearer <proxy pass>` header.
class H2UpstreamSession implements UpstreamSession {
  H2UpstreamSession(
    this.upstreamHost,
    this.upstreamPort,
    String bearerToken, {
    this.upstreamProxy,
    this.edgeAddress,
  }) : _currentBearerToken = bearerToken;

  final String upstreamHost;
  final int upstreamPort;
  final UpstreamProxyConfig? upstreamProxy;
  final String? edgeAddress;

  String get _connectHost {
    final edge = edgeAddress;
    return (edge != null && edge.isNotEmpty) ? edge : upstreamHost;
  }

  String _currentBearerToken;

  Socket? _rawSocket;
  SecureSocket? _secureSocket;
  ClientTransportConnection? _transport;
  StreamSubscription<void>? _frameSubscription;
  Timer? _keepaliveTimer;

  int _lastActivityAt = DateTime.now().millisecondsSinceEpoch;
  int _lastStreamDataAt = DateTime.now().millisecondsSinceEpoch;
  bool _awaitingPingAck = false;
  int _pingSentAt = 0;
  bool _acceptingNewStreams = true;
  int _activeStreams = 0;
  bool _closed = false;
  Timer? _drainTimer;

  @override
  bool get isConnected =>
      !_closed &&
      _acceptingNewStreams &&
      (_transport?.isOpen ?? false);

  @override
  void updateBearerToken(String token) {
    if (token.isEmpty || token == _currentBearerToken) return;
    _currentBearerToken = token;
    AppLogger.i(_tag,
        'proxy pass swapped into the live session; subsequent flows '
        'authenticate with the new pass');
  }

  int get activeStreamCount => _activeStreams;
  int get lastStreamDataAt => _lastStreamDataAt;

  @override
  Future<void> connect() async {
    Socket raw;
    if (upstreamProxy != null) {
      AppLogger.i(_tag,
          'chaining upstream connection to $_connectHost:$upstreamPort through '
          '${upstreamProxy!.type.name} proxy ${upstreamProxy!.address}');
      raw = await _connectViaProxy(upstreamProxy!);
    } else {
      raw = await Socket.connect(_connectHost, upstreamPort,
          timeout: _tcpConnectTimeout);
    }
    _rawSocket = raw;
    raw.setOption(SocketOption.tcpNoDelay, true);

    SecureSocket secure;
    try {
      secure = await SecureSocket.secure(
        raw,
        host: upstreamHost,
        supportedProtocols: const ['h2'],
      ).timeout(_tcpConnectTimeout);
    } catch (e) {
      raw.destroy();
      rethrow;
    }
    _secureSocket = secure;

    final negotiated = secure.selectedProtocol;
    AppLogger.i(_tag,
        'TLS handshake to $_connectHost:$upstreamPort complete, verified '
        'name=$upstreamHost, negotiated ALPN protocol=$negotiated');
    if (negotiated != 'h2') {
      secure.destroy();
      throw HandshakeException(
          'Upstream did not negotiate HTTP/2 over ALPN (got \'$negotiated\')');
    }

    final transport = ClientTransportConnection.viaSocket(
      secure,
      settings: const ClientSettings(
        streamWindowSize: _http2FlowControlWindowBytes,
        allowServerPushes: false,
      ),
    );
    _transport = transport;

    try {
      await transport.onInitialPeerSettingsReceived.timeout(_openStreamTimeout);
    } catch (e) {
      await _teardown();
      throw UpstreamConnectTimeoutException(
        authority: '$upstreamHost:$upstreamPort',
        message: 'Timed out waiting for the upstream\'s HTTP/2 SETTINGS',
        cause: e,
      );
    }

    _noteInboundActivity();
    _frameSubscription = transport.onFrameReceived.listen((_) {
      _noteInboundActivity();
    });
    _startKeepalive();
  }

  void _noteInboundActivity() {
    _lastActivityAt = DateTime.now().millisecondsSinceEpoch;
    _awaitingPingAck = false;
  }

  void _noteStreamData() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastActivityAt = now;
    _lastStreamDataAt = now;
  }

  void _startKeepalive() {
    _keepaliveTimer =
        Timer.periodic(_keepaliveCheckInterval, (timer) async {
      if (_closed) {
        timer.cancel();
        return;
      }
      final transport = _transport;
      if (transport == null || !transport.isOpen) {
        timer.cancel();
        _acceptingNewStreams = false;
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final idleFor = now - _lastActivityAt;
      if (_awaitingPingAck && now - _pingSentAt >= _keepalivePingTimeout.inMilliseconds) {
        AppLogger.w(_tag,
            'keepalive PING went unanswered for ${now - _pingSentAt}ms; '
            'closing dead upstream session');
        await close();
        timer.cancel();
        return;
      }
      if (!_awaitingPingAck && idleFor >= _keepaliveIdleThreshold.inMilliseconds) {
        _awaitingPingAck = true;
        _pingSentAt = now;
        transport.ping().catchError((Object e) {
          AppLogger.w(_tag, 'keepalive PING failed: $e; closing session');
          close();
        });
      }
    });
  }

  @override
  Future<TunneledStream> openStream(String targetHost, int targetPort) async {
    final transport = _transport;
    if (transport == null || _closed) {
      throw const SocketException('H2UpstreamSession is not connected');
    }
    if (!transport.isOpen) {
      throw const SocketException('H2UpstreamSession channel is not active');
    }
    if (!_acceptingNewStreams) {
      throw const SocketException('H2UpstreamSession is shutting down');
    }

    final authority =
        targetHost.contains(':') ? '[$targetHost]:$targetPort' : '$targetHost:$targetPort';

    final ClientTransportStream stream;
    try {
      stream = transport.makeRequest([
        Header(utf8.encode(':method'), utf8.encode('CONNECT')),
        Header(utf8.encode(':authority'), utf8.encode(authority)),
        Header(utf8.encode('proxy-authorization'),
            utf8.encode('Bearer $_currentBearerToken')),
      ]);
    } catch (e) {
      throw SocketException(
          'Could not open an HTTP/2 stream to $authority: $e');
    }

    _activeStreams++;
    var handedOff = false;
    try {
      final responseHeaders = Completer<int?>();
      final input = StreamController<List<int>>();

      void onDone() {
        _activeStreams--;
        if (!input.isClosed) input.close();
        if (_activeStreams == 0 && !_acceptingNewStreams && !_closed) {
          close();
        }
      }

      stream.onTerminated = (int? errorCode) {
        if (!responseHeaders.isCompleted) {
          responseHeaders.completeError(SocketException(
              'Upstream reset the stream to $authority (errorCode=$errorCode)'));
        }
        if (!input.isClosed) {
          input.addError(SocketException(
              'Upstream reset stream (errorCode=$errorCode)'));
          input.close();
        }
        onDone();
      };

      stream.incomingMessages.listen(
        (message) {
          _noteInboundActivity();
          if (message is HeadersStreamMessage) {
            if (!responseHeaders.isCompleted) {
              responseHeaders.complete(_statusOf(message.headers));
            }
            if (message.endStream) {
              if (!input.isClosed) input.close();
            }
          } else if (message is DataStreamMessage) {
            _noteStreamData();
            if (!input.isClosed) input.add(message.bytes);
            if (message.endStream && !input.isClosed) input.close();
          }
        },
        onDone: () {
          if (!responseHeaders.isCompleted) {
            responseHeaders.completeError(const SocketException(
                'Upstream stream closed before CONNECT completed'));
          }
          if (!input.isClosed) input.close();
          onDone();
        },
        onError: (Object e) {
          if (!responseHeaders.isCompleted) responseHeaders.completeError(e);
          if (!input.isClosed) {
            input.addError(e);
            input.close();
          }
          onDone();
        },
        cancelOnError: false,
      );

      int? status;
      try {
        status = await responseHeaders.future.timeout(_openStreamTimeout);
      } on TimeoutException catch (e) {
        stream.terminate();
        throw UpstreamConnectTimeoutException(
          authority: authority,
          message: 'Timed out waiting for CONNECT response from '
              '$upstreamHost:$upstreamPort ($authority)',
          cause: e,
        );
      }
      if (status == null || status < 200 || status > 299) {
        stream.terminate();
        throw UpstreamConnectRejectedException(
          statusCode: status,
          authority: authority,
          message: 'Upstream rejected CONNECT to $authority: status=$status',
        );
      }

      final output = StreamController<List<int>>();
      output.stream.listen(
        (bytes) {
          _noteStreamData();
          stream.outgoingMessages.add(DataStreamMessage(bytes));
        },
        onDone: () {
          // Half-close: END_STREAM on an empty DATA frame.
          stream.outgoingMessages
              .add(DataStreamMessage(Uint8List(0), endStream: true));
        },
        onError: (Object _) => stream.terminate(),
        cancelOnError: true,
      );

      handedOff = true;
      return TunneledStream(
        input: input.stream,
        output: output.sink,
        close: () {
          if (!output.isClosed) output.close();
          if (!input.isClosed) input.close();
          stream.terminate();
        },
      );
    } finally {
      if (!handedOff) {
        _activeStreams--;
        if (_activeStreams == 0 && !_acceptingNewStreams && !_closed) {
          close();
        }
      }
    }
  }

  static int? _statusOf(List<Header> headers) {
    for (final header in headers) {
      if (utf8.decode(header.name) == ':status') {
        return int.tryParse(utf8.decode(header.value).trim());
      }
    }
    return null;
  }

  @override
  void disableNewStreamsAndCloseWhenIdle() {
    _acceptingNewStreams = false;
    if (_activeStreams == 0) {
      close();
      return;
    }
    if (_drainTimer != null) return;
    _lastStreamDataAt = DateTime.now().millisecondsSinceEpoch;
    _drainTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) {
      final idleFor = DateTime.now().millisecondsSinceEpoch - _lastStreamDataAt;
      if (_activeStreams == 0 || idleFor >= 120000) {
        timer.cancel();
        _drainTimer = null;
        if (_activeStreams > 0) {
          AppLogger.w(_tag,
              'a swapped-out upstream session moved no data for 120s with '
              '$_activeStreams flow(s) still open; closing it');
        }
        close();
      }
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _teardown();
  }

  Future<void> _teardown() async {
    _keepaliveTimer?.cancel();
    _drainTimer?.cancel();
    await _frameSubscription?.cancel();
    final transport = _transport;
    if (transport != null && transport.isOpen) {
      try {
        await transport.finish().timeout(const Duration(seconds: 2));
      } catch (_) {
        try {
          await transport.terminate();
        } catch (_) {}
      }
    }
    try {
      _secureSocket?.destroy();
    } catch (_) {}
    try {
      _rawSocket?.destroy();
    } catch (_) {}
  }

  // ---- upstream proxy chaining -------------------------------------------

  Future<Socket> _connectViaProxy(UpstreamProxyConfig proxy) async {
    // Under the tunnel takeover the proxy host itself must bypass wintun and
    // must not be looked up through mapdns; RouteManager cached its real IPv4
    // before the tunnel started.
    final proxyAddress =
        await RouteManager.instance.ensureBypassHost(proxy.host) ?? proxy.host;
    final socket =
        await Socket.connect(proxyAddress, proxy.port, timeout: _tcpConnectTimeout);
    socket.setOption(SocketOption.tcpNoDelay, true);
    try {
      switch (proxy.type) {
        case UpstreamProxyType.socks5:
          await _socks5Handshake(socket, proxy);
        case UpstreamProxyType.http:
          await _httpConnectHandshake(socket, proxy);
      }
      return socket;
    } catch (e) {
      socket.destroy();
      rethrow;
    }
  }

  Future<void> _socks5Handshake(Socket socket, UpstreamProxyConfig proxy) async {
    final reader = SocketByteReader(socket);
    final hasCredentials =
        proxy.username != null && proxy.username!.isNotEmpty;
    final greeting = hasCredentials
        ? [0x05, 0x02, 0x00, 0x02]
        : [0x05, 0x01, 0x00];
    socket.add(greeting);
    await socket.flush();

    final response = await reader.readBytes(2);
    if (response[0] != 0x05) {
      throw const SocketException('upstream SOCKS5 proxy sent an invalid greeting');
    }
    if (response[1] == 0xFF) {
      throw const SocketException('upstream SOCKS5 proxy rejected our auth methods');
    }
    if (response[1] == 0x02) {
      final user = utf8.encode(proxy.username ?? '');
      final pass = utf8.encode(proxy.password ?? '');
      socket.add([0x01, user.length, ...user, pass.length, ...pass]);
      await socket.flush();
      final auth = await reader.readBytes(2);
      if (auth[1] != 0x00) {
        throw const SocketException('upstream SOCKS5 proxy rejected the credentials');
      }
    }

    final host = utf8.encode(upstreamHost);
    socket.add([
      0x05, 0x01, 0x00, 0x03, host.length, ...host,
      (upstreamPort >> 8) & 0xFF, upstreamPort & 0xFF,
    ]);
    await socket.flush();

    final header = await reader.readBytes(4);
    if (header[1] != 0x00) {
      throw SocketException(
          'upstream SOCKS5 proxy refused CONNECT (reply=${header[1]})');
    }
    switch (header[3]) {
      case 0x01:
        await reader.readBytes(4 + 2);
      case 0x03:
        final len = (await reader.readBytes(1))[0];
        await reader.readBytes(len + 2);
      case 0x04:
        await reader.readBytes(16 + 2);
      default:
        throw const SocketException('upstream SOCKS5 proxy sent an unknown address type');
    }
    final leftover = reader.takeBuffered();
    if (leftover.isNotEmpty) {
      throw const SocketException(
          'upstream SOCKS5 proxy pipelined data after the CONNECT reply');
    }
    await reader.detach();
  }

  Future<void> _httpConnectHandshake(
      Socket socket, UpstreamProxyConfig proxy) async {
    final reader = SocketByteReader(socket);
    final buffer = StringBuffer()
      ..write('CONNECT $upstreamHost:$upstreamPort HTTP/1.1\r\n')
      ..write('Host: $upstreamHost:$upstreamPort\r\n');
    if (proxy.username != null && proxy.username!.isNotEmpty) {
      final credentials = base64
          .encode(utf8.encode('${proxy.username}:${proxy.password ?? ''}'));
      buffer.write('Proxy-Authorization: Basic $credentials\r\n');
    }
    buffer.write('\r\n');
    socket.add(utf8.encode(buffer.toString()));
    await socket.flush();

    final head = await reader.readUntilHeaderEnd();
    final statusLine = head.split('\r\n').first;
    final parts = statusLine.split(' ');
    final code = parts.length >= 2 ? int.tryParse(parts[1]) : null;
    if (code == null || code < 200 || code > 299) {
      throw SocketException(
          'upstream HTTP proxy refused CONNECT: $statusLine');
    }
    final leftover = reader.takeBuffered();
    if (leftover.isNotEmpty) {
      throw const SocketException(
          'upstream HTTP proxy pipelined data after the CONNECT reply');
    }
    await reader.detach();
  }
}
