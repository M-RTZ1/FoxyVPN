import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:foxyvpn/vpn/socks5_udp_dns_relay.dart';
import 'package:foxyvpn/vpn/upstream_session.dart';

class _FakeStream {
  _FakeStream({required this.answer}) {
    outputCtl.stream.listen((bytes) {
      received.addAll(bytes);
      final reply = answer;
      if (reply == null || answered || received.length < 2) return;
      final expected = (received[0] << 8) | received[1];
      if (received.length < 2 + expected) return;
      answered = true;
      inputCtl.add([(reply.length >> 8) & 0xFF, reply.length & 0xFF, ...reply]);
    });
    tunneled = TunneledStream(
      input: inputCtl.stream,
      output: outputCtl.sink,
      close: () {
        if (!inputCtl.isClosed) inputCtl.close();
        if (!outputCtl.isClosed) outputCtl.close();
      },
    );
  }

  final List<int>? answer;
  final StreamController<List<int>> inputCtl = StreamController<List<int>>();
  final StreamController<List<int>> outputCtl = StreamController<List<int>>();
  final List<int> received = [];
  late final TunneledStream tunneled;
  bool answered = false;
}

class _FakeSession implements UpstreamSession {
  _FakeSession({this.answer, this.openError});

  final List<int>? answer;
  final Object? openError;
  final List<({String host, int port})> opened = [];
  final List<_FakeStream> streams = [];

  @override
  bool get isConnected => true;
  @override
  Future<void> connect() async {}
  @override
  Future<TunneledStream> openStream(String host, int port) async {
    opened.add((host: host, port: port));
    final error = openError;
    if (error != null) throw error;
    final stream = _FakeStream(answer: answer);
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

List<int> _dnsAnswer() => [
      0x46, 0x4f, // transaction id echoed
      0x81, 0x80, // response, recursion available
      0x00, 0x01, // one question
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      7, ...'example'.codeUnits,
      3, ...'com'.codeUnits,
      0x00,
      0x00, 0x01, // A
      0x00, 0x01, // IN
    ];

void main() {
  test('probe succeeds when the custom resolver answers through the tunnel',
      () async {
    final session = _FakeSession(answer: _dnsAnswer());
    expect(await Socks5UdpDnsRelay.probe(session, '1.1.1.1'), isTrue);
    expect(session.opened.single.host, '1.1.1.1');
    expect(session.opened.single.port, 53);
    final written = session.streams.single.received;
    expect(written.length, 2 + 29);
    expect(written[2], 0x46);
  });

  test('probe fails when the resolver cannot be dialled from the tunnel',
      () async {
    final session = _FakeSession(
      openError: const SocketException('connection refused'),
    );
    expect(await Socks5UdpDnsRelay.probe(session, '1.1.1.1'), isFalse);
  });

  test('probe fails when the resolver never answers', () async {
    final session = _FakeSession(answer: null);
    final started = DateTime.now();
    expect(
      await Socks5UdpDnsRelay.probe(
        session,
        '1.1.1.1',
        timeout: const Duration(milliseconds: 150),
      ),
      isFalse,
    );
    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(seconds: 2)),
    );
  });

  test('probe rejects a reply that is not the query response', () async {
    final session = _FakeSession(answer: List<int>.filled(12, 0));
    expect(await Socks5UdpDnsRelay.probe(session, '1.1.1.1'), isFalse);
  });
}
