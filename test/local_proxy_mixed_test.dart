import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/vpn/local_socks5_server.dart';
import 'package:foxyvpn/vpn/upstream_session.dart';

class _FakeStream {
  _FakeStream(this.host, this.port) {
    inputCtl = StreamController<List<int>>();
    outputCtl = StreamController<List<int>>();
    outputCtl.stream.listen(
      (bytes) => received.addAll(bytes),
      onDone: () => halfClosed = true,
    );
    tunneled = TunneledStream(
      input: inputCtl.stream,
      output: outputCtl.sink,
      close: () {
        if (!inputCtl.isClosed) inputCtl.close();
        if (!outputCtl.isClosed) outputCtl.close();
      },
    );
  }

  final String host;
  final int port;
  late final StreamController<List<int>> inputCtl;
  late final StreamController<List<int>> outputCtl;
  late final TunneledStream tunneled;
  final List<int> received = [];
  bool halfClosed = false;
}

class _FakeSession implements UpstreamSession {
  final List<_FakeStream> streams = [];
  int? rejectStatus;
  Object? openError;
  int openAttempts = 0;

  @override
  bool get isConnected => true;
  @override
  Future<void> connect() async {}
  @override
  Future<TunneledStream> openStream(String host, int port) async {
    openAttempts++;
    final error = openError;
    if (error != null) throw error;
    final status = rejectStatus;
    if (status != null) {
      throw UpstreamConnectRejectedException(
        statusCode: status,
        authority: '$host:$port',
        message: 'rejected by the edge',
      );
    }
    final stream = _FakeStream(host, port);
    streams.add(stream);
    return stream.tunneled;
  }

  @override
  void disableNewStreamsAndCloseWhenIdle() {}
  @override
  void updateBearerToken(String token) {}
  @override
  Future<void> close() async {}
}

class _Collector {
  _Collector(Socket socket) {
    socket.listen(
      (bytes) => received.addAll(bytes),
      onError: (Object _) => _completeClosed(),
      onDone: _completeClosed,
    );
  }

  final List<int> received = [];
  final Completer<void> closed = Completer<void>();

  void _completeClosed() {
    if (!closed.isCompleted) closed.complete();
  }

  Future<void> _until(bool Function() condition) async {
    for (var i = 0; i < 150; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError('condition not met; got: ${utf8.decode(received, allowMalformed: true)}');
  }

  Future<List<int>> exactly(int n) async {
    await _until(() => received.length >= n);
    final out = List<int>.from(received.sublist(0, n));
    received.removeRange(0, n);
    return out;
  }

  Future<String> textUntil(String needle) async {
    await _until(() => utf8.decode(received, allowMalformed: true).contains(needle));
    final text = utf8.decode(received, allowMalformed: true);
    received.clear();
    return text;
  }
}

void main() {
  late _FakeSession session;
  late LocalSocks5Server server;
  late _Collector clientOut;
  var unhealthyCalls = 0;

  setUp(() async {
    session = _FakeSession();
    unhealthyCalls = 0;
    server = LocalSocks5Server(
      bindAddress: '127.0.0.1',
      port: 0,
      rejectFakeDnsAddresses: false,
      sessionProvider: () => session,
      onSessionUnhealthy: () => unhealthyCalls++,
    );
    await server.start();
  });

  tearDown(() async => server.stop());

  Future<({Socket socket, _Collector collector})> connectClient() async {
    final socket = await Socket.connect('127.0.0.1', server.boundPort);
    final collector = _Collector(socket);
    return (socket: socket, collector: collector);
  }

  Future<int> socksConnectReply(String host, int port) async {
    final client = await connectClient();
    client.socket.add([0x05, 0x01, 0x00]);
    await client.collector.exactly(2);
    final hostBytes = utf8.encode(host);
    client.socket.add([
      0x05, 0x01, 0x00, 0x03, hostBytes.length, ...hostBytes,
      (port >> 8) & 0xFF, port & 0xFF,
    ]);
    final reply = await client.collector.exactly(10);
    client.socket.destroy();
    return reply[1];
  }

  test('SOCKS5 CONNECT still works on the mixed port', () async {
    final client = await connectClient();
    clientOut = client.collector;
    client.socket.add([0x05, 0x01, 0x00]);
    expect(await clientOut.exactly(2), [0x05, 0x00]);

    final host = utf8.encode('example.org');
    client.socket.add([
      0x05, 0x01, 0x00, 0x03, host.length, ...host, 0x1F, 0x90, // port 8080
    ]);
    final reply = await clientOut.exactly(10);
    expect(reply[1], 0x00);

    final up = session.streams.single;
    expect(up.host, 'example.org');
    expect(up.port, 8080);

    client.socket.add(utf8.encode('ping'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(utf8.decode(up.received), 'ping');

    up.inputCtl.add(utf8.encode('pong'));
    expect(utf8.decode(await clientOut.exactly(4)), 'pong');
    client.socket.destroy();
  });

  test('HTTP CONNECT tunnels through the upstream session', () async {
    final client = await connectClient();
    clientOut = client.collector;
    client.socket.write('CONNECT example.net:8443 HTTP/1.1\r\n'
        'Host: example.net:8443\r\n\r\n');
    final head = await clientOut.textUntil('\r\n\r\n');
    expect(head, startsWith('HTTP/1.1 200'));

    final up = session.streams.single;
    expect(up.host, 'example.net');
    expect(up.port, 8443);

    client.socket.write('tls-bytes');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(utf8.decode(up.received), 'tls-bytes');

    up.inputCtl.add(utf8.encode('tls-back'));
    expect(utf8.decode(await clientOut.exactly(8)), 'tls-back');
    client.socket.destroy();
  });

  test('absolute-URI request is rewritten to origin-form and hop headers '
      'are stripped', () async {
    final client = await connectClient();
    clientOut = client.collector;
    client.socket.write('GET http://example.io/a/b?x=1 HTTP/1.1\r\n'
        'Host: example.io\r\n'
        'Proxy-Authorization: Basic dXNlcjpwYXNz\r\n'
        'Connection: keep-alive\r\n\r\n');
    await Future<void>.delayed(const Duration(milliseconds: 150));

    final up = session.streams.single;
    expect(up.host, 'example.io');
    expect(up.port, 80);
    final forwarded = utf8.decode(up.received);
    expect(forwarded, startsWith('GET /a/b?x=1 HTTP/1.1\r\n'));
    expect(forwarded, contains('Host: example.io\r\n'));
    expect(forwarded, isNot(contains('Proxy-Authorization')));
    expect(forwarded, endsWith('\r\n\r\n'));

    up.inputCtl.add(utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi'));
    final response = await clientOut.textUntil('hi');
    expect(response, startsWith('HTTP/1.1 200 OK'));
    expect(response, endsWith('hi'));
    client.socket.destroy();
  });

  test('non-proxy-shaped HTTP request gets HTTP 400', () async {
    final client = await connectClient();
    clientOut = client.collector;
    client.socket.write('GET /index.html HTTP/1.1\r\nHost: x\r\n\r\n');
    final head = await clientOut.textUntil('\r\n\r\n');
    expect(head, startsWith('HTTP/1.1 400'));
    client.socket.destroy();
  });

  test('a 502 on a proxied port is retried instead of being remembered',
      () async {
    session.rejectStatus = 502;

    expect(await socksConnectReply('rr1---sn-a.example', 443), 0x04);
    expect(await socksConnectReply('rr1---sn-a.example', 443), 0x04);

    expect(session.openAttempts, 2,
        reason: 'a transient gateway error must not blacklist the host');
  });

  test('a refusal on a port the edge does not proxy is remembered', () async {
    session.rejectStatus = 502;

    expect(await socksConnectReply('example.org', 9898), 0x04);
    expect(await socksConnectReply('example.org', 9898), 0x04);

    expect(session.openAttempts, 1,
        reason: 'the second attempt should be refused on-device');
  });

  test('a saturated session is busy, not unhealthy', () async {
    session.openError = UpstreamConnectSaturatedException(
      authority: 'rr1---sn-a.example:443',
      message: 'all stream slots are in use',
    );

    for (var i = 0; i < 12; i++) {
      expect(await socksConnectReply('rr$i---sn-a.example', 443), 0x01);
    }

    expect(session.openAttempts, 12,
        reason: 'a busy session must not blacklist a destination locally');
    expect(unhealthyCalls, 0,
        reason: 'saturation says nothing about the tunnel\'s health');
  });

  test('a broken tunnel releases the client instead of holding it for the '
      'drain timeout', () async {
    final client = await connectClient();
    clientOut = client.collector;
    client.socket.add([0x05, 0x01, 0x00]);
    await clientOut.exactly(2);

    final host = utf8.encode('rr1---sn-a.example');
    client.socket.add([
      0x05, 0x01, 0x00, 0x03, host.length, ...host, 0x01, 0xBB, // port 443
    ]);
    expect((await clientOut.exactly(10))[1], 0x00);

    session.streams.single.inputCtl
        .addError(const SocketException('the tunnel died mid-flow'));

    await clientOut.closed.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => fail('the client was left holding a dead flow'),
    );
  });
}
