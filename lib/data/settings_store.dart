import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum UpstreamProxyType { socks5, http }

enum DohProvider {
  automatic('Automatic'),
  cloudflare('Cloudflare'),
  google('Google'),
  quad9('Quad9'),
  off('Off (use the network\'s resolver)');

  const DohProvider(this.label);

  final String label;

  List<String> get addresses => switch (this) {
    DohProvider.automatic => ['1.1.1.1', '8.8.8.8', '9.9.9.9'],
    DohProvider.cloudflare => ['1.1.1.1', '1.0.0.1'],
    DohProvider.google => ['8.8.8.8', '8.8.4.4'],
    DohProvider.quad9 => ['9.9.9.9', '149.112.112.112'],
    DohProvider.off => const [],
  };
}

enum ThemeModeSetting { system, light, dark }

enum AppLanguage { system, en, fa }

/// Mirrors the Android `SettingsStore`. Windows has no per-app split
/// tunneling equivalent, so `excludedApps` is intentionally absent.
class SettingsStore extends ChangeNotifier {
  SettingsStore._();

  static final SettingsStore instance = SettingsStore._();

  static const String defaultSockBindAddress = '127.0.0.1';

  /// Dedicated FoxyVPN frontend port. The classic SOCKS port 1080 is claimed
  /// by every other proxy on a developer machine, and Windows' dynamic port
  /// range starts at 49152, so this sits below it and clear of the usual
  /// alternates (8080/8888/3128/7890).
  static const int defaultSocksPort = 21080;
  static const int defaultUpstreamProxyPort = 1080;
  static const String defaultCustomDnsServer = '1.1.1.1';

  static const List<(String, String)> socksBindAddressPresets = [
    ('127.0.0.1', 'Loopback only (127.0.0.1)'),
    ('0.0.0.0', 'All interfaces (0.0.0.0)'),
  ];

  static const List<(String, String)> customDnsPresets = [
    ('1.1.1.1', 'Cloudflare (1.1.1.1)'),
    ('8.8.8.8', 'Google (8.8.8.8)'),
    ('9.9.9.9', 'Quad9 (9.9.9.9)'),
  ];

  SharedPreferences? _prefs;
  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    wOptions: WindowsOptions(),
  );

  /// The `(address, port)` the local SOCKS5/HTTP frontend should listen on.
  /// Kept in step with [socksBindAddress] and [socksPort] so
  /// `VpnController` can rebind a running proxy the moment either changes
  /// instead of waiting for a manual reconnect.
  final ValueNotifier<(String, int)> localProxyEndpoint = ValueNotifier((
    defaultSockBindAddress,
    defaultSocksPort,
  ));

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _migrateLegacySocksPort();
    localProxyEndpoint.value = (socksBindAddress, socksPort);
  }

  /// Builds before the dedicated port shipped stored the classic 1080; move
  /// those installs once, and never touch a port chosen afterwards.
  void _migrateLegacySocksPort() {
    if (_p.getBool('socks_port_migrated') ?? false) return;
    _p.setBool('socks_port_migrated', true);
    if (_p.getInt('socks_port') == 1080) {
      _p.setInt('socks_port', defaultSocksPort);
    }
  }

  SharedPreferences get _p {
    final prefs = _prefs;
    if (prefs == null) throw StateError('SettingsStore.init() not called');
    return prefs;
  }

  ThemeModeSetting get themeMode => ThemeModeSetting.values.firstWhere(
    (m) => m.name == _p.getString('theme_mode'),
    orElse: () => ThemeModeSetting.system,
  );
  set themeMode(ThemeModeSetting value) {
    _p.setString('theme_mode', value.name);
    notifyListeners();
  }

  AppLanguage get appLanguage => AppLanguage.values.firstWhere(
    (l) => l.name == _p.getString('app_language'),
    orElse: () => AppLanguage.system,
  );
  set appLanguage(AppLanguage value) {
    _p.setString('app_language', value.name);
    notifyListeners();
  }

  bool get exitCheckEnabled => _p.getBool('exit_check_enabled') ?? true;
  set exitCheckEnabled(bool value) {
    _p.setBool('exit_check_enabled', value);
    notifyListeners();
  }

  String get socksBindAddress =>
      _p.getString('socks_bind_address') ?? defaultSockBindAddress;
  set socksBindAddress(String value) {
    _p.setString(
      'socks_bind_address',
      value.trim().isEmpty ? defaultSockBindAddress : value.trim(),
    );
    localProxyEndpoint.value = (socksBindAddress, socksPort);
    notifyListeners();
  }

  int get socksPort => _p.getInt('socks_port') ?? defaultSocksPort;
  set socksPort(int value) {
    _p.setInt('socks_port', value.clamp(1, 65535));
    localProxyEndpoint.value = (socksBindAddress, socksPort);
    notifyListeners();
  }

  DohProvider get dohProvider => DohProvider.values.firstWhere(
    (p) => p.name == _p.getString('doh_provider'),
    orElse: () => DohProvider.automatic,
  );
  set dohProvider(DohProvider value) {
    _p.setString('doh_provider', value.name);
    notifyListeners();
  }

  bool get customDnsEnabled => _p.getBool('custom_dns_enabled') ?? false;
  set customDnsEnabled(bool value) {
    _p.setBool('custom_dns_enabled', value);
    notifyListeners();
  }

  String get customDnsServer {
    final value = _p.getString('custom_dns_server') ?? defaultCustomDnsServer;
    return isValidDnsServer(value) ? value : defaultCustomDnsServer;
  }

  set customDnsServer(String value) {
    final trimmed = value.trim();
    if (!isValidDnsServer(trimmed)) return;
    _p.setString('custom_dns_server', trimmed);
    notifyListeners();
  }

  String? get effectiveCustomDnsServer =>
      customDnsEnabled ? customDnsServer : null;

  bool get proxyOnlyMode => _p.getBool('proxy_only_mode') ?? false;
  set proxyOnlyMode(bool value) {
    _p.setBool('proxy_only_mode', value);
    notifyListeners();
  }

  bool get systemProxyEnabled => _p.getBool('system_proxy_enabled') ?? false;
  set systemProxyEnabled(bool value) {
    _p.setBool('system_proxy_enabled', value);
    notifyListeners();
  }

  String get customEdgeAddress =>
      (_p.getString('custom_edge_address') ?? '').toLowerCase();
  set customEdgeAddress(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isNotEmpty && !isValidEdgeHost(normalized)) return;
    _p.setString('custom_edge_address', normalized);
    notifyListeners();
  }

  String? get effectiveCustomEdgeAddress {
    final value = customEdgeAddress;
    return isValidEdgeHost(value) ? value : null;
  }

  bool get upstreamProxyEnabled =>
      _p.getBool('upstream_proxy_enabled') ?? false;
  set upstreamProxyEnabled(bool value) {
    _p.setBool('upstream_proxy_enabled', value);
    notifyListeners();
  }

  UpstreamProxyType get upstreamProxyType =>
      UpstreamProxyType.values.firstWhere(
        (t) => t.name == _p.getString('upstream_proxy_type'),
        orElse: () => UpstreamProxyType.socks5,
      );
  set upstreamProxyType(UpstreamProxyType value) {
    _p.setString('upstream_proxy_type', value.name);
    notifyListeners();
  }

  String get upstreamProxyHost => _p.getString('upstream_proxy_host') ?? '';
  set upstreamProxyHost(String value) {
    _p.setString('upstream_proxy_host', value.trim());
    notifyListeners();
  }

  int get upstreamProxyPort =>
      _p.getInt('upstream_proxy_port') ?? defaultUpstreamProxyPort;
  set upstreamProxyPort(int value) {
    _p.setInt('upstream_proxy_port', value.clamp(1, 65535));
    notifyListeners();
  }

  Future<String> get upstreamProxyUsername async =>
      await _secure.read(key: 'upstream_proxy_username') ?? '';
  Future<void> setUpstreamProxyUsername(String value) =>
      _secure.write(key: 'upstream_proxy_username', value: value);

  Future<String> get upstreamProxyPassword async =>
      await _secure.read(key: 'upstream_proxy_password') ?? '';
  Future<void> setUpstreamProxyPassword(String value) =>
      _secure.write(key: 'upstream_proxy_password', value: value);

  /// Path to the hev-socks5-tunnel Windows binary (bundled or user-provided).
  String get hevTunnelBinaryPath =>
      _p.getString('hev_tunnel_binary_path') ?? '';
  set hevTunnelBinaryPath(String value) {
    _p.setString('hev_tunnel_binary_path', value.trim());
    notifyListeners();
  }

  /// Internal bookkeeping for the GitHub release check: when the release feed
  /// was last polled and which version's notification the user dismissed.
  int get lastUpdateCheckAtMillis => _p.getInt('last_update_check_at') ?? 0;
  set lastUpdateCheckAtMillis(int value) =>
      _p.setInt('last_update_check_at', value);

  String get dismissedUpdateTag => _p.getString('dismissed_update_tag') ?? '';
  set dismissedUpdateTag(String value) =>
      _p.setString('dismissed_update_tag', value);

  static bool isValidIpAddress(String value) {
    if (value.contains(':')) {
      // Very permissive IPv6 literal check.
      return value.split(':').length >= 3 &&
          value
              .replaceAll(':', '')
              .split('')
              .every(
                (c) =>
                    c.isEmpty ||
                    (c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57) ||
                    (c.toLowerCase().codeUnitAt(0) >= 97 &&
                        c.toLowerCase().codeUnitAt(0) <= 102),
              );
    }
    final parts = value.split('.');
    if (parts.length != 4) return false;
    for (final part in parts) {
      if (part.isEmpty || part.length > 3) return false;
      final v = int.tryParse(part);
      if (v == null || v < 0 || v > 255) return false;
    }
    return true;
  }

  static bool isValidDnsServer(String value) => isValidIpAddress(value);

  static bool isValidHostname(String value) {
    var host = value.trim();
    if (host.endsWith('.')) host = host.substring(0, host.length - 1);
    if (host.isEmpty || host.length > 253) return false;
    if (host.contains(':')) return false;
    if (host.split('').every((c) => _isDigit(c) || c == '.')) return false;
    final labels = host.split('.');
    if (labels.length < 2) return false;
    for (final label in labels) {
      if (label.isEmpty || label.length > 63) return false;
      if (label.startsWith('-') || label.endsWith('-')) return false;
      for (final c in label.split('')) {
        final isAsciiAlnum =
            (c.codeUnitAt(0) < 128) && (RegExp(r'[A-Za-z0-9]').hasMatch(c));
        if (!(c == '-' || isAsciiAlnum)) return false;
      }
    }
    return true;
  }

  static bool _isDigit(String c) =>
      c.codeUnitAt(0) >= 48 && c.codeUnitAt(0) <= 57;

  static bool isValidEdgeHost(String value) =>
      isValidHostname(value) || isValidIpAddress(value);
}
