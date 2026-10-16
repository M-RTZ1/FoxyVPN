import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_logger.dart';
import 'models.dart';
import 'server_list_client.dart';

const String _tag = 'ServerListStore';

/// The server list for the whole process lifetime.
///
/// The snapshot bundled with the app is applied before any request goes out,
/// so the location picker is never empty and connecting never waits on a
/// resolver. The live list from Remote Settings replaces it once the background
/// refresh lands; a refresh that fails leaves the list the user is looking at
/// untouched.
class ServerListStore extends ChangeNotifier {
  ServerListStore._();

  static final ServerListStore instance = ServerListStore._();

  final ServerListClient _client = ServerListClient();

  List<VpnCountry> _countries = const [];
  ServerListOrigin _origin = ServerListOrigin.bundled;
  bool _refreshing = false;
  Future<void>? _seeding;
  Future<void>? _booted;

  List<VpnCountry> get countries => _countries;
  ServerListOrigin get origin => _origin;
  bool get refreshing => _refreshing;

  /// Reads the bundled snapshot, then refreshes once in the background.
  /// Calling it again is free: the work happens at most once.
  Future<void> boot() => _booted ??= () async {
        await _seed();
        unawaited(refresh());
      }();

  /// Locations to dial. Waits for the local snapshot only, never for the
  /// network, so this belongs on the connect path.
  Future<List<VpnCountry>> forConnect() async {
    if (_countries.isEmpty) await _seed();
    return _countries;
  }

  Future<void> _seed() => _seeding ??= () async {
        final bundled = await _client.fetchBundledCountries();
        if (bundled.isNotEmpty && _countries.isEmpty) {
          _apply(bundled, ServerListOrigin.bundled);
        }
      }();

  /// Fetches the live list. Used by the reload button and by [boot]; failures
  /// are logged, not raised, because the existing list stays valid.
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    notifyListeners();
    try {
      await _seed();
      final list = await _client
          .fetchCountries()
          .timeout(ServerListClient.totalBudget);
      if (list.countries.isNotEmpty) _apply(list.countries, list.origin);
    } catch (error) {
      AppLogger.w(_tag, 'server list refresh did not complete', error);
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  void _apply(List<VpnCountry> countries, ServerListOrigin origin) {
    _countries = countries;
    _origin = origin;
    notifyListeners();
  }
}
