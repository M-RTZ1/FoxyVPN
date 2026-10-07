import 'dart:collection';

import 'package:flutter/foundation.dart';

enum LogLevel { info, warn, error }

class LogEntry {
  LogEntry({
    required this.id,
    required this.timestampMillis,
    required this.level,
    required this.tag,
    required this.message,
  });

  final int id;
  final int timestampMillis;
  final LogLevel level;
  final String tag;
  final String message;
}

class AppLogger {
  AppLogger._();

  static const int maxEntries = 2000;

  static final Queue<LogEntry> _buffer = Queue();
  static int _counter = 0;

  static final ValueNotifier<List<LogEntry>> entries =
      ValueNotifier<List<LogEntry>>(const []);

  static void d(String tag, String message) {
    debugPrint('D/$tag: $message');
  }

  static void i(String tag, String message) {
    debugPrint('I/$tag: $message');
    _log(LogLevel.info, tag, message);
  }

  static void w(String tag, String message, [Object? error]) {
    debugPrint('W/$tag: $message${error != null ? ': $error' : ''}');
    _log(LogLevel.warn, tag,
        error != null ? '$message: $_errMessage(error)' : message);
  }

  static void e(String tag, String message, [Object? error]) {
    debugPrint('E/$tag: $message${error != null ? ': $error' : ''}');
    _log(LogLevel.error, tag,
        error != null ? '$message: $_errMessage(error)' : message);
  }

  static String _errMessage(Object error) {
    if (error is Error) return error.toString();
    return error.toString();
  }

  static void _log(LogLevel level, String tag, String message) {
    _buffer.addLast(LogEntry(
      id: ++_counter,
      timestampMillis: DateTime.now().millisecondsSinceEpoch,
      level: level,
      tag: tag,
      message: message,
    ));
    while (_buffer.length > maxEntries) {
      _buffer.removeFirst();
    }
    entries.value = _buffer.toList(growable: false);
  }

  static void clear() {
    _buffer.clear();
    entries.value = const [];
  }

  static String exportAsText() {
    String fmt(int v, [int pad = 2]) => v.toString().padLeft(pad, '0');
    return _buffer.map((entry) {
      final t = DateTime.fromMillisecondsSinceEpoch(entry.timestampMillis);
      final ts = '${t.year}-${fmt(t.month)}-${fmt(t.day)} '
          '${fmt(t.hour)}:${fmt(t.minute)}:${fmt(t.second)}.${fmt(t.millisecond, 3)}';
      return '$ts ${entry.level.name.toUpperCase().padRight(5)} '
          '[${entry.tag}] ${entry.message}';
    }).join('\n');
  }
}
