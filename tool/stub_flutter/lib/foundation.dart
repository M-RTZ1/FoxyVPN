/// Stub of `package:flutter/foundation.dart` for tool/verify_fix.dart.
///
/// Only the symbols the pure-Dart VPN libraries actually touch are provided:
/// `debugPrint` and `ValueNotifier` (used by `AppLogger`).
library;

/// Mirrors flutter's `debugPrint`: line-aware, throttled console output.
void debugPrint(String? message, {int? wrapWidth}) {
  if (message == null) return;
  // ignore: avoid_print
  print(message);
}

/// A deliberately tiny stand-in for flutter's `ValueNotifier`.
class ValueNotifier<T> extends ChangeNotifier {
  ValueNotifier(this._value);

  T _value;
  T get value => _value;

  set value(T newValue) {
    if (identical(newValue, _value)) return;
    _value = newValue;
    notifyListeners();
  }

  @override
  String toString() => 'ValueNotifier<$T>($_value)';
}

/// A deliberately tiny stand-in for flutter's `ChangeNotifier`.
class ChangeNotifier {
  final List<void Function()> _listeners = [];

  bool get hasListeners => _listeners.isNotEmpty;

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void notifyListeners() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void dispose() => _listeners.clear();
}

bool get kDebugMode => true;
