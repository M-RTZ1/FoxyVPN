import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Buffered byte reader over a [Socket] for protocol handshakes.
/// After the handshake, [rest] hands the remaining byte stream back
/// (buffered leftovers first, then the live socket).
class SocketByteReader {
  SocketByteReader(this._socket) {
    _subscription = _socket.listen(
      _onData,
      onError: (Object e) {
        _error = e;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
      cancelOnError: false,
    );
    _subscription.pause();
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;
  final List<int> _buffer = [];
  bool _done = false;
  bool _streaming = false;
  Object? _error;
  Completer<void>? _waiter;

  void _onData(Uint8List data) {
    _buffer.addAll(data);
    if (!_streaming) _subscription.pause();
    _wake();
  }

  void _wake() {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      _waiter = null;
      waiter.complete();
    }
  }

  Future<void> _waitForData() {
    if (_buffer.isNotEmpty || _done || _error != null) {
      return Future.value();
    }
    _subscription.resume();
    final completer = Completer<void>();
    _waiter = completer;
    return completer.future;
  }

  Future<int> readUnsignedByte() async {
    final bytes = await readBytes(1);
    return bytes[0];
  }

  Future<int> readUnsignedShort() async {
    final bytes = await readBytes(2);
    return (bytes[0] << 8) | bytes[1];
  }

  Future<List<int>> readBytes(int count) async {
    while (_buffer.length < count) {
      if (_error != null) throw _error!;
      if (_done) {
        throw const SocketException(
            'connection closed while more data was expected');
      }
      await _waitForData();
    }
    final out = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return out;
  }

  Future<String> readUntilHeaderEnd() async {
    while (true) {
      final asString = latin1.decode(_buffer);
      final idx = asString.indexOf('\r\n\r\n');
      if (idx >= 0) {
        final head = asString.substring(0, idx);
        _buffer.removeRange(0, idx + 4);
        return head;
      }
      if (_error != null) throw _error!;
      if (_done) {
        throw const SocketException('connection closed during handshake');
      }
      await _waitForData();
    }
  }

  List<int> takeBuffered() {
    final out = List<int>.from(_buffer);
    _buffer.clear();
    return out;
  }

  /// Pushes bytes back to the front of the buffer (protocol sniffing).
  void unreadBytes(Iterable<int> bytes) {
    _buffer.insertAll(0, bytes);
  }

  /// Returns everything not yet consumed: buffered bytes followed by the
  /// live socket stream. The reader must not be used afterwards.
  Stream<List<int>> rest() {
    final controller = StreamController<List<int>>();
    _streaming = true;
    if (_buffer.isNotEmpty) {
      controller.add(takeBuffered());
    }
    if (_done) {
      controller.close();
      return controller.stream;
    }
    _subscription.onData((data) {
      if (!controller.isClosed) controller.add(data);
    });
    _subscription.onDone(() {
      if (!controller.isClosed) controller.close();
    });
    _subscription.onError((Object e) {
      if (!controller.isClosed) controller.addError(e);
    });
    _subscription.resume();
    return controller.stream;
  }

  /// Cancels the subscription so the raw socket can be used elsewhere.
  Future<void> detach() async {
    await _subscription.cancel();
  }
}
