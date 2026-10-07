import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../core/app_logger.dart';
import 'upstream_session.dart';

const String _tag = 'Socks5UdpDnsRelay';

const int dnsPort = 53;
const int maxDnsMessageBytes = 4096;
const int _socks5UdpHeaderMinBytes = 10;
const int _maxInflightQueries = 32;
const Duration _queryTimeout = Duration(seconds: 10);

/// Port of Android's `Socks5UdpDnsRelay`. The tunnel carries TCP only, so
/// a UDP association is accepted for DNS (port 53) and nothing else;
/// queries go out as DNS-over-TCP inside an upstream CONNECT stream.
class Socks5UdpDnsRelay {
  Socks5UdpDnsRelay({
    required this.bindAddress,
    required this.clientAddress,
    required this.sessionProvider,
  });

  final InternetAddress bindAddress;
  final InternetAddress clientAddress;
  final UpstreamSession? Function() sessionProvider;

  RawDatagramSocket? _socket;
  int _inflight = 0;
  bool _unsupportedFlowReported = false;

  int queriesOverTcp = 0;
  int nonDnsDropped = 0;
  int foreignSourceDropped = 0;
  int otherDropped = 0;

  InternetAddress get boundAddress =>
      _socket?.address ?? InternetAddress.loopbackIPv4;
  int get boundPort => _socket?.port ?? 0;

  Future<void> start() async {
    final socket = await RawDatagramSocket.bind(bindAddress, 0);
    socket.broadcastEnabled = false;
    _socket = socket;
    socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        if (datagram.address.address != clientAddress.address) {
          if (foreignSourceDropped++ == 0) {
            AppLogger.w(_tag,
                'dropping a datagram from ${datagram.address.address}: '
                'relaying for anyone else would make this an open resolver');
          }
          return;
        }
        if (_inflight >= _maxInflightQueries) {
          otherDropped++;
          return;
        }
        _inflight++;
        _relay(datagram.data,
                InternetAddress(datagram.address.address), datagram.port)
            .whenComplete(() => _inflight--);
      },
      onError: (Object e) => AppLogger.d(_tag, 'UDP relay error: $e'),
    );
  }

  Future<void> stop() async {
    _socket?.close();
    _socket = null;
    if (queriesOverTcp > 0 ||
        nonDnsDropped > 0 ||
        foreignSourceDropped > 0 ||
        otherDropped > 0) {
      AppLogger.d(_tag,
          'UDP association closed: $queriesOverTcp DNS queries over TCP, '
          '$nonDnsDropped non-DNS datagrams dropped, '
          '$foreignSourceDropped from unassociated sources, '
          '$otherDropped other drops');
    }
  }

  Future<void> _relay(
      Uint8List datagram, InternetAddress replyAddress, int replyPort) async {
    final socket = _socket;
    if (socket == null) return;
    final request = _parseRequest(datagram);
    if (request == null) {
      otherDropped++;
      return;
    }
    if (request.port != dnsPort) {
      nonDnsDropped++;
      if (!_unsupportedFlowReported) {
        _unsupportedFlowReported = true;
        AppLogger.d(_tag,
            'dropping a datagram for port ${request.port}: this tunnel '
            'carries TCP only, so general UDP (QUIC included) cannot be '
            'relayed and the sender has to fall back to TCP');
      }
      return;
    }

    final query = datagram.sublist(request.payloadOffset);
    if (query.isEmpty || query.length > maxDnsMessageBytes) {
      otherDropped++;
      return;
    }
    final session = sessionProvider();
    if (session == null || !session.isConnected) {
      otherDropped++;
      return;
    }

    final answer = await _queryOverTcp(session, request.host, query);
    if (answer == null) {
      otherDropped++;
      return;
    }
    queriesOverTcp++;

    final response = Uint8List(request.payloadOffset + answer.length)
      ..setRange(0, request.payloadOffset, datagram)
      ..setRange(request.payloadOffset, request.payloadOffset + answer.length,
          answer);
    try {
      socket.send(response, replyAddress, replyPort);
    } catch (_) {
      otherDropped++;
    }
  }

  Future<List<int>?> _queryOverTcp(
      UpstreamSession session, String resolverHost, List<int> query) async {
    TunneledStream? tunneled;
    try {
      tunneled = await session.openStream(resolverHost, dnsPort);
    } catch (_) {
      return null;
    }
    try {
      final result = await Future.any<List<int>?>([
        _dnsOverTcpExchange(tunneled, query),
        Future<List<int>?>.delayed(_queryTimeout, () => null),
      ]);
      return result;
    } catch (_) {
      return null;
    } finally {
      tunneled.close();
    }
  }

  Future<List<int>> _dnsOverTcpExchange(
      TunneledStream tunneled, List<int> query) async {
    tunneled.output
        .add([(query.length >> 8) & 0xFF, query.length & 0xFF, ...query]);
    final buffer = <int>[];
    int? expectedLength;
    await for (final chunk in tunneled.input) {
      buffer.addAll(chunk);
      if (expectedLength == null && buffer.length >= 2) {
        expectedLength = (buffer[0] << 8) | buffer[1];
        if (expectedLength == 0 || expectedLength > maxDnsMessageBytes) {
          throw const SocketException('implausible DNS-over-TCP length');
        }
      }
      if (expectedLength != null &&
          buffer.length >= 2 + expectedLength) {
        return buffer.sublist(2, 2 + expectedLength);
      }
    }
    throw const SocketException('DNS-over-TCP stream ended early');
  }

  _UdpRequest? _parseRequest(Uint8List datagram) {
    if (datagram.length < _socks5UdpHeaderMinBytes) return null;
    if (datagram[0] != 0 || datagram[1] != 0 || datagram[2] != 0) return null;

    var offset = 3;
    final addressType = datagram[offset++];
    String host;
    switch (addressType) {
      case 0x01:
        if (datagram.length < offset + 4 + 2) return null;
        host = datagram.sublist(offset, offset + 4).join('.');
        offset += 4;
      case 0x03:
        final length = datagram[offset++];
        if (length == 0) return null;
        if (datagram.length < offset + length + 2) return null;
        host = String.fromCharCodes(datagram.sublist(offset, offset + length));
        offset += length;
      case 0x04:
        if (datagram.length < offset + 16 + 2) return null;
        host = InternetAddress.fromRawAddress(
                Uint8List.fromList(datagram.sublist(offset, offset + 16)))
            .address;
        offset += 16;
      default:
        return null;
    }
    final port = (datagram[offset] << 8) | datagram[offset + 1];
    offset += 2;
    return _UdpRequest(offset, host, port);
  }
}

class _UdpRequest {
  const _UdpRequest(this.payloadOffset, this.host, this.port);

  final int payloadOffset;
  final String host;
  final int port;
}
