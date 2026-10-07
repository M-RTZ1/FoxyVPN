import 'dart:async';
import 'dart:io';

import 'upstream_session.dart';

enum HealthVerdict { targetFailure, sessionUnhealthy, sessionUnauthenticated }

/// Port of Android's `UpstreamHealthTracker`: distinguishes one bad
/// destination from a broken session by watching timeout patterns and
/// session-fatal CONNECT rejections.
class UpstreamHealthTracker {
  static const int maxDistinctTimeoutTargets = 10;
  static const Set<int> sessionFatalStatusCodes = {401, 403, 407};
  static const Set<int> targetUnreachableStatusCodes = {502, 503, 504};

  final Set<String> _timeoutTargets = <String>{};

  void observeSuccess() {
    _timeoutTargets.clear();
  }

  void reset() {
    _timeoutTargets.clear();
  }

  HealthVerdict observeFailure(String target, Object? cause) {
    if (_invalidatesSession(cause)) {
      _timeoutTargets.clear();
      return HealthVerdict.sessionUnauthenticated;
    }
    if (!_isSilence(cause)) return HealthVerdict.targetFailure;

    _timeoutTargets.add(target);
    if (_timeoutTargets.length < maxDistinctTimeoutTargets) {
      return HealthVerdict.targetFailure;
    }
    _timeoutTargets.clear();
    return HealthVerdict.sessionUnhealthy;
  }

  bool _isSilence(Object? cause) =>
      cause == null ||
      cause is UpstreamConnectTimeoutException ||
      cause is SocketException ||
      cause is TimeoutException;

  bool _invalidatesSession(Object? cause) {
    if (cause is! UpstreamConnectRejectedException) return false;
    final status = cause.statusCode;
    return status != null && sessionFatalStatusCodes.contains(status);
  }
}
