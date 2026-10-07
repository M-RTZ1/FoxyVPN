import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class ProxyStateStore extends ChangeNotifier {
  ProxyStateStore._();

  static final ProxyStateStore instance = ProxyStateStore._();

  static const int failureThreshold = 3;

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  SharedPreferences get _p {
    final prefs = _prefs;
    if (prefs == null) throw StateError('ProxyStateStore.init() not called');
    return prefs;
  }

  ProxyCandidate? load() {
    final raw = _p.getString('selected_proxy');
    if (raw == null) return null;
    try {
      return ProxyCandidate.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  void save(ProxyCandidate candidate) {
    _p.setString('selected_proxy', jsonEncode({
      ...candidate.toJson(),
      'failures': 0,
    }));
    notifyListeners();
  }

  /// Returns (failureCount, cleared).
  (int, bool) recordFailure() {
    final failures = (_p.getInt('selected_proxy_failures') ?? 0) + 1;
    if (failures >= failureThreshold) {
      clear();
      return (failures, true);
    }
    _p.setInt('selected_proxy_failures', failures);
    return (failures, false);
  }

  void clear() {
    _p.remove('selected_proxy');
    _p.remove('selected_proxy_failures');
    notifyListeners();
  }
}
