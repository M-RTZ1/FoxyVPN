import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http2/transport.dart';

const int _prefaceLength = 24;
const int _settingsFrameType = 0x4;
const int _windowUpdateFrameType = 0x8;
const int _initialWindowSizeSettingId = 0x4;
const int _ackFlag = 0x1;
const int _defaultConnectionWindow = (1 << 16) - 1;

void main() {
  test('advertises a large connection-level receive window', () async {
    const requested = 16 * 1024 * 1024;
    final frames = await _captureClientFrames(
      const ClientSettings(
        streamWindowSize: requested,
        connectionWindowSize: requested,
      ),
    );

    final settings = frames.firstWhere(
      (frame) =>
          frame.type == _settingsFrameType && frame.flags & _ackFlag == 0,
      orElse: () => fail('the client did not send its SETTINGS frame'),
    );
    expect(_settingValue(settings.payload, _initialWindowSizeSettingId),
        requested);

    final windowUpdate = frames.firstWhere(
      (frame) =>
          frame.type == _windowUpdateFrameType && frame.streamId == 0,
      orElse: () => fail('no connection-level WINDOW_UPDATE was sent'),
    );
    expect(_uint32(windowUpdate.payload, 0),
        requested - _defaultConnectionWindow);
  });

  test('keeps the 64 KiB connection window when not configured', () async {
    final frames = await _captureClientFrames(const ClientSettings());

    expect(
      frames.where(
          (frame) => frame.type == _windowUpdateFrameType && frame.streamId == 0),
      isEmpty,
    );
  });
}

Future<List<_Frame>> _captureClientFrames(ClientSettings settings) async {
  final incoming = StreamController<List<int>>();
  final outgoing = StreamController<List<int>>();
  final bytes = <int>[];
  outgoing.stream.listen(bytes.addAll);

  final transport = ClientTransportConnection.viaStreams(
    incoming.stream,
    outgoing.sink,
    settings: settings,
  );

  // The client only becomes operational after the peer's first SETTINGS frame.
  // Feed an empty one and let the queued writes reach the outgoing stream.
  incoming.add([0, 0, 0, _settingsFrameType, 0, 0, 0, 0, 0]);
  await pumpEventQueue();

  expect(transport.isOpen, isTrue);
  return _parseFrames(bytes);
}

List<_Frame> _parseFrames(List<int> bytes) {
  expect(bytes.length, greaterThanOrEqualTo(_prefaceLength),
      reason: 'the connection preface should have been written');
  final frames = <_Frame>[];
  var offset = _prefaceLength;
  while (offset + 9 <= bytes.length) {
    final length = (bytes[offset] << 16) |
        (bytes[offset + 1] << 8) |
        bytes[offset + 2];
    final type = bytes[offset + 3];
    final flags = bytes[offset + 4];
    final streamId = ((bytes[offset + 5] & 0x7f) << 24) |
        (bytes[offset + 6] << 16) |
        (bytes[offset + 7] << 8) |
        bytes[offset + 8];
    final payloadStart = offset + 9;
    frames.add(_Frame(
      type: type,
      flags: flags,
      streamId: streamId,
      payload: bytes.sublist(payloadStart, payloadStart + length),
    ));
    offset = payloadStart + length;
  }
  return frames;
}

int? _settingValue(List<int> payload, int identifier) {
  for (var offset = 0; offset + 6 <= payload.length; offset += 6) {
    if (_uint16(payload, offset) == identifier) {
      return _uint32(payload, offset + 2);
    }
  }
  return null;
}

int _uint16(List<int> bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];

int _uint32(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

class _Frame {
  const _Frame({
    required this.type,
    required this.flags,
    required this.streamId,
    required this.payload,
  });

  final int type;
  final int flags;
  final int streamId;
  final List<int> payload;
}
