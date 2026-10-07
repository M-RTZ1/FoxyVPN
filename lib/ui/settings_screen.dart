import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/settings_store.dart';
import '../vpn/system_proxy_manager.dart';

/// All mirrored Android settings, laid out for the phone-sized window.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _settings = SettingsStore.instance;

  late final TextEditingController _socksBindController;
  late final TextEditingController _socksPortController;
  late final TextEditingController _customDnsController;
  late final TextEditingController _edgeController;
  late final TextEditingController _proxyHostController;
  late final TextEditingController _proxyPortController;
  final TextEditingController _proxyUsernameController =
      TextEditingController();
  final TextEditingController _proxyPasswordController =
      TextEditingController();
  late final TextEditingController _tunnelPathController;

  @override
  void initState() {
    super.initState();
    _socksBindController =
        TextEditingController(text: _settings.socksBindAddress);
    _socksPortController =
        TextEditingController(text: '${_settings.socksPort}');
    _customDnsController =
        TextEditingController(text: _settings.customDnsServer);
    _edgeController =
        TextEditingController(text: _settings.customEdgeAddress);
    _proxyHostController =
        TextEditingController(text: _settings.upstreamProxyHost);
    _proxyPortController =
        TextEditingController(text: '${_settings.upstreamProxyPort}');
    _tunnelPathController =
        TextEditingController(text: _settings.hevTunnelBinaryPath);
    _loadProxyCredentials();
  }

  Future<void> _loadProxyCredentials() async {
    final username = await _settings.upstreamProxyUsername;
    final password = await _settings.upstreamProxyPassword;
    if (!mounted) return;
    setState(() {
      _proxyUsernameController.text = username;
      _proxyPasswordController.text = password;
    });
  }

  @override
  void dispose() {
    _socksBindController.dispose();
    _socksPortController.dispose();
    _customDnsController.dispose();
    _edgeController.dispose();
    _proxyHostController.dispose();
    _proxyPortController.dispose();
    _proxyUsernameController.dispose();
    _proxyPasswordController.dispose();
    _tunnelPathController.dispose();
    super.dispose();
  }

  Future<void> _fillFromSystemProxy() async {
    final current = await SystemProxyManager.readCurrent();
    final parsed = SystemProxyManager.parseServerValue(current.server);
    if (!mounted) return;
    if (parsed == null) {
      _showError(
          current.server.isEmpty
              ? 'Windows has no system proxy configured'
              : 'Could not understand the Windows proxy setting: ${current.server}');
      return;
    }
    setState(() {
      _settings.upstreamProxyEnabled = true;
      _settings.upstreamProxyType = UpstreamProxyType.http;
      _settings.upstreamProxyHost = parsed.$1;
      _proxyHostController.text = parsed.$1;
      _settings.upstreamProxyPort = parsed.$2;
      _proxyPortController.text = '${parsed.$2}';
    });
  }

  Future<void> _saveProxyCredentials() async {
    await _settings
        .setUpstreamProxyUsername(_proxyUsernameController.text.trim());
    await _settings
        .setUpstreamProxyPassword(_proxyPasswordController.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Proxy credentials saved'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _settings,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('Settings'), centerTitle: true),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                _SectionTitle('Appearance'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: SegmentedButton<ThemeModeSetting>(
                    segments: const [
                      ButtonSegment(
                          value: ThemeModeSetting.system,
                          icon: Icon(Icons.brightness_auto),
                          label: Text('Auto')),
                      ButtonSegment(
                          value: ThemeModeSetting.light,
                          icon: Icon(Icons.light_mode),
                          label: Text('Light')),
                      ButtonSegment(
                          value: ThemeModeSetting.dark,
                          icon: Icon(Icons.dark_mode),
                          label: Text('Dark')),
                    ],
                    selected: {_settings.themeMode},
                    onSelectionChanged: (selection) =>
                        _settings.themeMode = selection.first,
                  ),
                ),
                const SizedBox(height: 8),
                _SectionTitle('Connection'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Exit check'),
                  subtitle: const Text(
                      'Verify the exit country after connecting and log a warning on mismatch'),
                  value: _settings.exitCheckEnabled,
                  onChanged: (v) => _settings.exitCheckEnabled = v,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Proxy-only mode'),
                  subtitle: const Text(
                      'Expose only the local proxy; no wintun adapter, no admin rights needed'),
                  value: _settings.proxyOnlyMode,
                  onChanged: (v) => _settings.proxyOnlyMode = v,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Set as Windows system proxy'),
                  subtitle: const Text(
                      'While connected, point Windows (and every app that '
                      'honours it) at the local HTTP proxy; reverted on '
                      'disconnect'),
                  value: _settings.systemProxyEnabled,
                  onChanged: (v) => _settings.systemProxyEnabled = v,
                ),
                _DropdownTile<DohProvider>(
                  title: 'DNS-over-HTTPS resolver (for edge resolution)',
                  value: _settings.dohProvider,
                  values: DohProvider.values,
                  labelOf: (p) => p.label,
                  onChanged: (v) => _settings.dohProvider = v,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Custom DNS server for the tunnel'),
                  subtitle: const Text(
                      'When on, the TUN interface hands this resolver to apps instead of on-device fake-DNS'),
                  value: _settings.customDnsEnabled,
                  onChanged: (v) => _settings.customDnsEnabled = v,
                ),
                if (_settings.customDnsEnabled)
                  _TextFieldTile(
                    label: 'Custom DNS server (IPv4)',
                    controller: _customDnsController,
                    keyboardType: TextInputType.text,
                    helper: 'e.g. 1.1.1.1',
                    onSubmitted: (v) {
                      _settings.customDnsServer = v;
                      _customDnsController.text = _settings.customDnsServer;
                      if (!SettingsStore.isValidDnsServer(v.trim())) {
                        _showError('Invalid DNS server address');
                      }
                    },
                    presets: SettingsStore.customDnsPresets,
                    onPreset: (value) => setState(
                        () => _customDnsController.text = value),
                  ),
                _TextFieldTile(
                  label: 'Pinned edge address (optional)',
                  controller: _edgeController,
                  helper: 'Force every connection to dial this Fastly edge IP',
                  onSubmitted: (v) {
                    _settings.customEdgeAddress = v;
                    final stored = _settings.customEdgeAddress;
                    if (v.trim().isNotEmpty && stored != v.trim().toLowerCase()) {
                      _showError('Invalid hostname or IP address');
                    }
                  },
                ),
                _SectionTitle('Local proxy (SOCKS5 + HTTP)'),
                _TextFieldTile(
                  label: 'Bind address',
                  controller: _socksBindController,
                  helper: 'Restart the tunnel to apply',
                  onSubmitted: (v) {
                    if (!SettingsStore.isValidIpAddress(v.trim())) {
                      _showError('Invalid IP address');
                      return;
                    }
                    _settings.socksBindAddress = v;
                  },
                  presets: SettingsStore.socksBindAddressPresets,
                  onPreset: (value) =>
                      setState(() => _socksBindController.text = value),
                ),
                _TextFieldTile(
                  label: 'Port',
                  controller: _socksPortController,
                  keyboardType: TextInputType.number,
                  helper: 'Restart the tunnel to apply',
                  onSubmitted: (v) {
                    final port = int.tryParse(v.trim());
                    if (port == null || port < 1 || port > 65535) {
                      _showError('Invalid port number');
                      return;
                    }
                    _settings.socksPort = port;
                  },
                ),
                _SectionTitle('Chain through an upstream proxy'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Use an upstream proxy'),
                  subtitle: const Text(
                      'Route everything (sign-in, Guardian, server list and '
                      'the edge dials) through a SOCKS5 or HTTP proxy; '
                      'credentials apply to the edge connection'),
                  value: _settings.upstreamProxyEnabled,
                  onChanged: (v) => _settings.upstreamProxyEnabled = v,
                ),
                if (_settings.upstreamProxyEnabled) ...[
                  _DropdownTile<UpstreamProxyType>(
                    title: 'Proxy type',
                    value: _settings.upstreamProxyType,
                    values: UpstreamProxyType.values,
                    labelOf: (t) => t == UpstreamProxyType.socks5
                        ? 'SOCKS5'
                        : 'HTTP (CONNECT)',
                    onChanged: (v) => _settings.upstreamProxyType = v,
                  ),
                  _TextFieldTile(
                    label: 'Proxy host',
                    controller: _proxyHostController,
                    onSubmitted: (v) => _settings.upstreamProxyHost = v,
                  ),
                  _TextFieldTile(
                    label: 'Proxy port',
                    controller: _proxyPortController,
                    keyboardType: TextInputType.number,
                    onSubmitted: (v) {
                      final port = int.tryParse(v.trim());
                      if (port != null) _settings.upstreamProxyPort = port;
                    },
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _fillFromSystemProxy,
                      icon: const Icon(Icons.settings_ethernet, size: 18),
                      label: const Text('Copy from Windows system proxy'),
                    ),
                  ),
                  _TextFieldTile(
                    label: 'Proxy username (optional)',
                    controller: _proxyUsernameController,
                    onSubmitted: (_) => _saveProxyCredentials(),
                  ),
                  _TextFieldTile(
                    label: 'Proxy password (optional)',
                    controller: _proxyPasswordController,
                    obscure: true,
                    onSubmitted: (_) => _saveProxyCredentials(),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 4, 0, 0),
                      child: TextButton.icon(
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('Save credentials'),
                        onPressed: _saveProxyCredentials,
                      ),
                    ),
                  ),
                ],
                _SectionTitle('Tunnel engine'),
                _TextFieldTile(
                  label: 'hev-socks5-tunnel.exe path',
                  controller: _tunnelPathController,
                  helper:
                      'Leave empty to look next to the app executable (or in '
                      'bin\\). Required for full-VPN mode; proxy-only mode '
                      'does not need it.',
                  onSubmitted: (v) => _settings.hevTunnelBinaryPath = v,
                ),
                _SectionTitle('About'),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ClipOval(
                              child: Image.asset(
                                'assets/images/foxyvpn_logo.jpg',
                                width: 44,
                                height: 44,
                                fit: BoxFit.cover,
                              ),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Text(
                                'FoxyVPN for Windows • traffic rides HTTP/2 '
                                    'CONNECT streams through Fastly edges '
                                    'using your Mozilla VPN entitlement '
                                    '(50 GB/month free).\n\n'
                                    'Full-VPN mode creates a wintun adapter '
                                    'and needs the app to run as '
                                    'administrator.',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: const Icon(Icons.code, size: 20),
                          title: const Text(
                            'Source: github.com/M-RTZ1/FoxyVPN',
                            style: TextStyle(fontSize: 12),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.copy, size: 18),
                            tooltip: 'Copy the project source URL',
                            onPressed: () {
                              Clipboard.setData(const ClipboardData(
                                  text: 'https://github.com/M-RTZ1/FoxyVPN'));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Source URL copied'),
                                  behavior: SnackBarBehavior.floating,
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Theme.of(context).colorScheme.error,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: scheme.primary, letterSpacing: 0.8),
      ),
    );
  }
}

class _TextFieldTile extends StatelessWidget {
  const _TextFieldTile({
    required this.label,
    required this.controller,
    this.onSubmitted,
    this.keyboardType,
    this.helper,
    this.obscure = false,
    this.presets = const [],
    this.onPreset,
  });

  final String label;
  final TextEditingController controller;
  final void Function(String)? onSubmitted;
  final TextInputType? keyboardType;
  final String? helper;
  final bool obscure;
  final List<(String, String)> presets;
  final void Function(String)? onPreset;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            obscureText: obscure,
            keyboardType: keyboardType,
            inputFormatters: keyboardType == TextInputType.number
                ? [FilteringTextInputFormatter.digitsOnly]
                : null,
            onSubmitted: onSubmitted,
            decoration: InputDecoration(
              labelText: label,
              helperText: helper,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
          if (presets.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final (value, name) in presets)
                  ActionChip(
                    label: Text(name),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onPreset?.call(value),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _DropdownTile<T> extends StatelessWidget {
  const _DropdownTile({
    required this.title,
    required this.value,
    required this.values,
    required this.labelOf,
    required this.onChanged,
  });

  final String title;
  final T value;
  final List<T> values;
  final String Function(T) labelOf;
  final void Function(T) onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(title,
                style: Theme.of(context).textTheme.bodyMedium),
          ),
          DropdownButton<T>(
            value: value,
            items: [
              for (final item in values)
                DropdownMenuItem(
                  value: item,
                  child: Text(labelOf(item)),
                ),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ],
      ),
    );
  }
}
