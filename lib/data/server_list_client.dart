import 'dart:convert';

import '../core/app_logger.dart';
import 'control_plane_http.dart';
import 'models.dart';

const String _tag = 'ServerListClient';

const String remoteSettingsUrl =
    'https://firefox.settings.services.mozilla.com/v1/buckets/main/collections/vpn-serverlist/records';

const String recommendedCountryCode = 'REC';

const Set<String> _excludedCountryNames = {'CatchAll Anycast'};

class ServerListClient {
  Future<List<VpnCountry>> fetchCountries() async {
    final response =
        await ControlPlaneHttp.send('GET', Uri.parse(remoteSettingsUrl));
    if (!response.isSuccessful) {
      throw Exception('Remote Settings fetch failed: HTTP ${response.statusCode}');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
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
    AppLogger.i(_tag, 'fetched ${countries.length} countries from Remote Settings');
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
