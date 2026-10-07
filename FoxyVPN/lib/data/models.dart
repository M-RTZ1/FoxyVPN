enum ConnectionState { disconnected, connecting, connected }

enum LoginStepState { credentials, twoFactor }

class VpnProtocol {
  const VpnProtocol({
    required this.name,
    this.host = '',
    this.port = 0,
    this.scheme = '',
    this.templateString = '',
  });

  final String name;
  final String host;
  final int port;
  final String scheme;
  final String templateString;
}

class VpnServerNode {
  const VpnServerNode({
    required this.hostname,
    this.port = 0,
    this.quarantined = false,
    this.protocols = const [],
  });

  final String hostname;
  final int port;
  final bool quarantined;
  final List<VpnProtocol> protocols;
}

class VpnCity {
  const VpnCity({required this.name, required this.code, this.servers = const []});

  final String name;
  final String code;
  final List<VpnServerNode> servers;
}

class VpnCountry {
  const VpnCountry({required this.name, required this.code, this.cities = const []});

  final String name;
  final String code;
  final List<VpnCity> cities;
}

class ProxyCandidate {
  const ProxyCandidate({
    required this.host,
    required this.port,
    required this.countryCode,
    required this.countryName,
    this.cityCode = '',
  });

  final String host;
  final int port;
  final String countryCode;
  final String countryName;
  final String cityCode;

  String get authority => '$host:$port';

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'countryCode': countryCode,
        'countryName': countryName,
        'cityCode': cityCode,
      };

  static ProxyCandidate? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final host = json['host'] as String?;
    final port = json['port'] as int?;
    if (host == null || host.isEmpty || port == null || port == 0) return null;
    return ProxyCandidate(
      host: host,
      port: port,
      countryCode: json['countryCode'] as String? ?? '',
      countryName: json['countryName'] as String? ?? '',
      cityCode: json['cityCode'] as String? ?? '',
    );
  }
}

class Entitlement {
  const Entitlement({
    required this.subscribed,
    required this.uid,
    this.maxBytes,
    required this.limitedBandwidth,
    this.quotaRemaining,
  });

  final bool subscribed;
  final String uid;
  final int? maxBytes;
  final bool limitedBandwidth;
  final int? quotaRemaining;

  Entitlement copyWith({int? quotaRemaining}) => Entitlement(
        subscribed: subscribed,
        uid: uid,
        maxBytes: maxBytes,
        limitedBandwidth: limitedBandwidth,
        quotaRemaining: quotaRemaining ?? this.quotaRemaining,
      );
}

class RuntimeAuth {
  const RuntimeAuth({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAtEpochSeconds,
  });

  final String accessToken;
  final String? refreshToken;
  final int expiresAtEpochSeconds;
}
