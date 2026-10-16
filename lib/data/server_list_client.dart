import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../core/app_logger.dart';
import '../vpn/edge_address_resolver.dart';
import 'control_plane_http.dart';
import 'models.dart';
import 'settings_store.dart';

const String _tag = 'ServerListClient';

const String remoteSettingsUrl =
    'https://firefox.settings.services.mozilla.com/v1/buckets/main/collections/vpn-serverlist/records';

const String recommendedCountryCode = 'REC';

/// Snapshot of the same endpoint, shipped so a blocked or poisoned resolver
/// never leaves the app without a location to connect to.
const String bundledServerListAsset = 'assets/data/servers_fallback.json';

const Set<String> _excludedCountryNames = {'CatchAll Anycast'};

enum ServerListOrigin {
  /// Whatever Mozilla serves right now.
  online,

  /// The shipped snapshot: usable, but possibly stale.
  bundled,
}

typedef ServerList = ({List<VpnCountry> countries, ServerListOrigin origin});

class ServerListClient {
  /// Ceiling for the online attempts. The bundled snapshot is loaded as soon
  /// as it runs out, instead of letting a network that swallows packets dead
  /// stop the caller's own timeout from ever reaching the fallback.
  static const Duration onlineBudget = Duration(seconds: 12);
  static const Duration _minimumAttemptSlice = Duration(milliseconds: 1500);

  /// A single dial through a DNS-over-HTTPS answer, TCP connect and TLS
  /// handshake included. A middlebox that drops those packets must not be
  /// allowed to spend the whole [onlineBudget] on one attempt.
  static const Duration _directDialBudget = Duration(seconds: 4);

  /// Ceiling for the DNS-over-HTTPS lookup that precedes that dial.
  static const Duration _lookupBudget = Duration(seconds: 6);

  /// Longest [fetchCountries] can take, bundled snapshot read included. A
  /// caller with a shorter timeout would cancel the future before its own
  /// fallback ever ran, which is how a blocked network used to end up as an
  /// empty list instead of a stale one.
  static Duration get totalBudget => onlineBudget + const Duration(seconds: 6);

  Future<ServerList> fetchCountries() async {
    final watch = Stopwatch()..start();
    final online = await _fetchOnline(watch);
    if (online.isNotEmpty) {
      return (countries: online, origin: ServerListOrigin.online);
    }
    final bundled = await fetchBundledCountries();
    if (bundled.isNotEmpty) {
      AppLogger.w(_tag,
          'the online server list was unavailable; falling back to the bundled '
          'snapshot (${bundled.length} countries)');
    }
    return (countries: bundled, origin: ServerListOrigin.bundled);
  }

  /// The shipped snapshot, with no network involved.
  Future<List<VpnCountry>> fetchBundledCountries() async {
    final text = await _readBundledSnapshot();
    if (text == null) {
      AppLogger.w(_tag, 'the bundled server list could not be read');
      return const [];
    }
    try {
      return parseCountries(jsonDecode(text) as Map<String, dynamic>);
    } catch (error) {
      AppLogger.w(_tag, 'the bundled server list is corrupt', error);
      return const [];
    }
  }

  /// Remote Settings is fetched through a DNS-over-HTTPS answer first, because
  /// a network that forges the record for this host forges it for the system
  /// resolver too. Every failure is swallowed and reported as an empty list:
  /// a server list that cannot be refreshed must not abort a connection.
  Future<List<VpnCountry>> _fetchOnline(Stopwatch watch) async {
    final failures = <String>[];
    final uri = Uri.parse(remoteSettingsUrl);
    if (ControlPlaneHttp.usesSystemResolver) {
      final endpoints = SettingsStore.instance.dohProvider.addresses;
      if (endpoints.isEmpty) {
        failures.add('no DNS-over-HTTPS endpoint is configured');
      } else {
        final countries =
            await _dialDirect(uri, endpoints, watch, failures);
        if (countries != null) return countries;
      }
    }

    final timeout = _slice(watch);
    if (timeout != null) {
      try {
        final countries = _countriesFrom(
            await ControlPlaneHttp.send('GET', uri, timeout: timeout));
        if (countries.isNotEmpty) {
          AppLogger.i(_tag,
              'fetched ${countries.length} countries from Remote Settings via '
              'the network resolver');
          return countries;
        }
        failures.add('Remote Settings returned no usable locations');
      } catch (error) {
        failures.add('$error');
      }
    } else {
      failures.add('ran out of time');
    }

    AppLogger.w(
        _tag, 'could not load the server list online: ${failures.join('; ')}');
    return const [];
  }

  /// Dials [uri] at an address DoH gave us, TLS still validating the real
  /// hostname. Returns null when the attempt produced nothing usable, having
  /// recorded the reason in [failures].
  Future<List<VpnCountry>?> _dialDirect(Uri uri, List<String> endpoints,
      Stopwatch watch, List<String> failures) async {
    final address = await _lookupThroughDoh(uri, endpoints, watch, failures);
    if (address == null) return null;
    final timeout = _slice(watch, _directDialBudget);
    if (timeout == null) {
      failures.add('ran out of time');
      return null;
    }
    try {
      final countries = _countriesFrom(
          await ControlPlaneHttp.sendDirect('GET', uri, address,
              timeout: timeout));
      if (countries.isEmpty) {
        failures.add('the DNS-over-HTTPS dial returned no usable locations');
        return null;
      }
      AppLogger.i(_tag,
          'fetched ${countries.length} countries from Remote Settings, '
          'dialled through DNS-over-HTTPS at $address');
      return countries;
    } catch (error) {
      failures.add('the DNS-over-HTTPS dial failed: $error');
      return null;
    }
  }

  Future<String?> _lookupThroughDoh(Uri uri, List<String> endpoints,
      Stopwatch watch, List<String> failures) async {
    final timeout = _slice(watch, _lookupBudget);
    if (timeout == null) {
      failures.add('ran out of time');
      return null;
    }
    try {
      return await EdgeAddressResolver
          .resolve(uri.host, endpoints)
          .timeout(timeout);
    } catch (error) {
      failures.add('the DNS-over-HTTPS lookup failed: $error');
      return null;
    }
  }

  /// Time still left in the online budget for one step, capped so a single
  /// stalled step cannot eat all of it. Null once too little is left for an
  /// attempt to be worth making.
  static Duration? _slice(Stopwatch watch, [Duration cap = onlineBudget]) {
    final left = onlineBudget - watch.elapsed;
    if (left < _minimumAttemptSlice) return null;
    return left > cap ? cap : left;
  }

  /// The asset bundle comes first: it resolves next to the executable, whereas
  /// "Run as administrator" starts the process with C:\Windows\System32 as its
  /// working directory, where any relative path finds nothing. The disk roots
  /// are the fallback for Dart tooling that has no Flutter binding to read
  /// bundle assets.
  static Future<String?> _readBundledSnapshot() async {
    try {
      return await rootBundle.loadString(bundledServerListAsset);
    } catch (error) {
      AppLogger.d(_tag, 'bundled snapshot is not in the asset bundle: $error');
    }
    for (final root in _snapshotRoots()) {
      try {
        final file = File(_join(root, bundledServerListAsset));
        if (file.existsSync()) return await file.readAsString();
      } catch (error) {
        AppLogger.d(_tag, 'no readable snapshot under $root: $error');
      }
    }
    return null;
  }

  static List<String> _snapshotRoots() {
    final roots = <String>[];
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      roots.add(_join(exeDir, 'data/flutter_assets'));
    } catch (error) {
      AppLogger.d(_tag, 'cannot locate the executable: $error');
    }
    try {
      roots.add(Directory.current.path);
    } catch (_) {}
    return roots;
  }

  static String _join(String root, String relative) =>
      [root, ...relative.split('/')].join(Platform.pathSeparator);

  List<VpnCountry> _countriesFrom(CpResponse response) {
    if (!response.isSuccessful) {
      throw Exception(
          'Remote Settings fetch failed: HTTP ${response.statusCode}');
    }
    return parseCountries(jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Remote Settings records and the bundled snapshot share one shape, so one
  /// parser serves both. Public so the shipped snapshot can be tested offline.
  List<VpnCountry> parseCountries(Map<String, dynamic> body) {
    final records = (body['data'] as List<dynamic>?) ?? const [];
    final countries = <VpnCountry>[];
    for (final record in records) {
      final recordMap = record as Map<String, dynamic>;
      final countryJson =
          (recordMap['country'] as Map<String, dynamic>?) ?? recordMap;
      final country = _parseCountry(countryJson);
      final isExcluded = _excludedCountryNames.any((name) =>
          name.toLowerCase() == country.name.toLowerCase());
      if (country.code.isNotEmpty && country.cities.isNotEmpty && !isExcluded) {
        countries.add(country);
      }
    }
    return countries;
  }

  VpnCountry _parseCountry(Map<String, dynamic> json) => VpnCountry(
        name: json['name'] as String? ?? '',
        code: json['code'] as String? ?? '',
        cities: ((json['cities'] as List<dynamic>?) ?? const [])
            .map((c) => _parseCity(c as Map<String, dynamic>))
            .toList(),
      );

  VpnCity _parseCity(Map<String, dynamic> json) => VpnCity(
        name: json['name'] as String? ?? '',
        code: json['code'] as String? ?? '',
        servers: ((json['servers'] as List<dynamic>?) ?? const [])
            .map((s) => _parseServer(s as Map<String, dynamic>))
            .toList(),
      );

  VpnServerNode _parseServer(Map<String, dynamic> json) => VpnServerNode(
        hostname: json['hostname'] as String? ?? '',
        port: json['port'] as int? ?? 0,
        quarantined: json['quarantined'] == true,
        protocols: ((json['protocols'] as List<dynamic>?) ?? const [])
            .map((p) => _parseProtocol(p as Map<String, dynamic>))
            .toList(),
      );

  VpnProtocol _parseProtocol(Map<String, dynamic> json) => VpnProtocol(
        name: json['name'] as String? ?? '',
        host: json['host'] as String? ?? '',
        port: json['port'] as int? ?? 0,
        scheme: json['scheme'] as String? ?? '',
        templateString: json['templateString'] as String? ?? '',
      );

  static (String, int)? defaultConnectTarget(VpnServerNode server) {
    for (final proto in server.protocols) {
      if (proto.name == 'connect') {
        final host = proto.host.isNotEmpty ? proto.host : server.hostname;
        final port = proto.port != 0 ? proto.port : server.port;
        return (host, port);
      }
    }
    if (server.protocols.isEmpty) return (server.hostname, server.port);
    return null;
  }

  static List<ProxyCandidate> candidatesForCountry(
      List<VpnCountry> countries, String countryCode) {
    final out = <ProxyCandidate>[];
    for (final country in countries) {
      if (country.code.toLowerCase() != countryCode.toLowerCase()) continue;
      for (final city in country.cities) {
        for (final server in city.servers) {
          if (server.quarantined) continue;
          final target = defaultConnectTarget(server);
          if (target == null) continue;
          out.add(ProxyCandidate(
            host: target.$1,
            port: target.$2,
            countryCode: country.code,
            countryName: country.name,
            cityCode: city.code,
          ));
        }
      }
    }
    return out;
  }

  static List<ProxyCandidate> candidatesForCity(
          List<VpnCountry> countries, String countryCode, String cityCode) =>
      candidatesForCountry(countries, countryCode)
          .where((c) => c.cityCode.toLowerCase() == cityCode.toLowerCase())
          .toList();
}
