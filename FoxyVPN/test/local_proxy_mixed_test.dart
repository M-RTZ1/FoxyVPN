import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluttewind/vpn/local_socks5_server.dart';
import 'package:fluttewind/vpn/upstream_session.dart';

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

  @override
  bool get isConnected => true;
  @override
  Future<void> connect() async {}
  @override
  Future<TunneledStream> openStream(String host, int port) async {
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
      onError: (Object _) {},
      onDone: () {},
    );
  }

  final List<int> received = [];

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

  setUp(() async {
    session = _FakeSession();
    server = LocalSocks5Server(
      bindAddress: '127.0.0.1',
      port: 0,
      rejectFakeDnsAddresses: false,
      sessionProvider: () => session,
    );
    await server.start();
  });

  tearDown(() async => server.stop());

  Future<({Socket socket, _Collector collector})> connectClient() async {
    final socket = await Socket.connect('127.0.0.1', server.boundPort);
    final collector = _Collector(socket);
    return (socket: socket, collector: collector);
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
}
