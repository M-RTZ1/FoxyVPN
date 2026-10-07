import 'dart:async';
import 'dart:io';

abstract class UpstreamSession {
  Future<void> connect();

  Future<TunneledStream> openStream(String targetHost, int targetPort);

  void disableNewStreamsAndCloseWhenIdle();

  void updateBearerToken(String token);

  bool get isConnected;

  Future<void> close();
}

/// A bidirectional byte stream carried inside the upstream tunnel.
class TunneledStream {
  TunneledStream({
    required this.input,
    required this.output,
    required this.close,
  });

  /// Bytes arriving from the remote end; closes on end-of-stream.
  final Stream<List<int>> input;

  /// Bytes are written to the remote end; [StreamSink.close] half-closes.
  final StreamSink<List<int>> output;

  /// Tears the stream down in both directions.
  final void Function() close;
}

class UpstreamConnectRejectedException implements IOException {
  UpstreamConnectRejectedException({
    required this.statusCode,
    required this.authority,
    required this.message,
  });

  final int? statusCode;
  final String authority;
  final String message;

  @override
  String toString() => message;
}

class UpstreamConnectTimeoutException implements IOException {
  UpstreamConnectTimeoutException({
    required this.authority,
    required this.message,
    this.cause,
  });

  final String authority;
  final String message;
  final Object? cause;

  @override
  String toString() => message;
}
