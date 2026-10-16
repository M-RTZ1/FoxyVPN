import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_version.dart';
import '../data/settings_store.dart';
import '../data/split_tunnel_rules.dart';
import '../data/update_checker.dart';
import '../l10n/generated/app_localizations.dart';
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
  final TextEditingController _splitPatternController = TextEditingController();

  /// Action used for the next rule the user adds; most people come here to
  /// bypass something, so that is the starting choice.
  SplitTunnelAction _newSplitAction = SplitTunnelAction.direct;

  @override
  void initState() {
    super.initState();
    _socksBindController = TextEditingController(
      text: _settings.socksBindAddress,
    );
    _socksPortController = TextEditingController(
      text: '${_settings.socksPort}',
    );
    _customDnsController = TextEditingController(
      text: _settings.customDnsServer,
    );
    _edgeController = TextEditingController(text: _settings.customEdgeAddress);
    _proxyHostController = TextEditingController(
      text: _settings.upstreamProxyHost,
    );
    _proxyPortController = TextEditingController(
      text: '${_settings.upstreamProxyPort}',
    );
    _tunnelPathController = TextEditingController(
      text: _settings.hevTunnelBinaryPath,
    );
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
    _splitPatternController.dispose();
    super.dispose();
  }

  Future<void> _fillFromSystemProxy() async {
    final l10n = AppLocalizations.of(context);
    final current = await SystemProxyManager.readCurrent();
    final parsed = SystemProxyManager.parseServerValue(current.server);
    if (!mounted) return;
    if (parsed == null) {
      _showError(
        current.server.isEmpty
            ? l10n.noSystemProxyConfigured
            : l10n.unparsableSystemProxy(current.server),
      );
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
    final l10n = AppLocalizations.of(context);
    await _settings.setUpstreamProxyUsername(
      _proxyUsernameController.text.trim(),
    );
    await _settings.setUpstreamProxyPassword(_proxyPasswordController.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.credentialsSaved),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _updateTile(AppLocalizations l10n) {
    final checker = UpdateChecker.instance;
    final release = checker.latest;
    final subtitle = switch (checker.status) {
      UpdateStatus.checking => l10n.updateChecking,
      UpdateStatus.available => l10n.updateAvailableTitle(
        release?.version ?? '',
      ),
      UpdateStatus.upToDate => l10n.updateUpToDate(
        release?.version ?? AppVersion.full,
      ),
      UpdateStatus.nonePublished => l10n.updateNonePublished,
      UpdateStatus.failed => l10n.updateFailed(checker.error ?? ''),
      UpdateStatus.unknown => l10n.aboutVersion(AppVersion.full),
    };
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: const Icon(Icons.system_update_alt, size: 20),
      title: Text(l10n.updateCheckAction),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: switch (checker.status) {
        UpdateStatus.checking => const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        UpdateStatus.available => const Icon(Icons.open_in_new, size: 18),
        _ => const Icon(Icons.chevron_right, size: 18),
      },
      onTap: checker.status == UpdateStatus.checking
          ? null
          : () => checker.updateAvailable
                ? checker.openDownload()
                : checker.checkNow(),
    );
  }

  String _splitActionLabel(AppLocalizations l10n, SplitTunnelAction action) =>
      action == SplitTunnelAction.tunnel
      ? l10n.splitTunnelActionTunnel
      : l10n.splitTunnelActionDirect;

  /// Adds a rule from the text field, or a preset when a chip was tapped.
  /// Re-adding a pattern changes what it does instead of stacking a second
  /// rule that the first one shadows.
  void _addSplitRule({String? preset}) {
    final l10n = AppLocalizations.of(context);
    final input = (preset ?? _splitPatternController.text).trim();
    if (input.isEmpty) return;
    final rule = SplitTunnelRule.parse(input, action: _newSplitAction);
    if (rule == null) {
      _showError(l10n.splitTunnelInvalidPattern);
      return;
    }
    final rules = _settings.splitTunnelRules;
    final index = rules.indexWhere(
      (existing) =>
          existing.pattern == rule.pattern && existing.kind == rule.kind,
    );
    if (index >= 0) {
      rules[index] = rule;
    } else {
      rules.add(rule);
    }
    _settings.splitTunnelRules = rules;
    if (preset == null) _splitPatternController.clear();
  }

  void _removeSplitRuleAt(int index) {
    final rules = _settings.splitTunnelRules;
    if (index < 0 || index >= rules.length) return;
    rules.removeAt(index);
    _settings.splitTunnelRules = rules;
  }

  void _setSplitRuleAction(int index, SplitTunnelAction action) {
    final rules = _settings.splitTunnelRules;
    if (index < 0 || index >= rules.length) return;
    final rule = rules[index];
    rules[index] = SplitTunnelRule(
      pattern: rule.pattern,
      kind: rule.kind,
      action: action,
      enabled: rule.enabled,
    );
    _settings.splitTunnelRules = rules;
  }

  Widget _splitRuleTile(
    AppLocalizations l10n,
    SplitTunnelRule rule,
    int index,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Row(
        children: [
          Icon(
            rule.kind == SplitTunnelPatternKind.address
                ? Icons.numbers
                : Icons.public,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              rule.display,
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          DropdownButton<SplitTunnelAction>(
            value: rule.action,
            isDense: true,
            underline: const SizedBox.shrink(),
            items: [
              for (final action in SplitTunnelAction.values)
                DropdownMenuItem(
                  value: action,
                  child: Text(
                    _splitActionLabel(l10n, action),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null) _setSplitRuleAction(index, v);
            },
          ),
          IconButton(
            tooltip: l10n.splitTunnelDeleteRule,
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: () => _removeSplitRuleAt(index),
          ),
        ],
      ),
    );
  }

  List<Widget> _splitTunnelSection(AppLocalizations l10n) {
    final rules = _settings.splitTunnelRules;
    final hint = TextStyle(
      fontSize: 12,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(l10n.splitTunnelTitle),
        subtitle: Text(l10n.splitTunnelSubtitle),
        value: _settings.splitTunnelEnabled,
        onChanged: (v) => _settings.splitTunnelEnabled = v,
      ),
      _DropdownTile<SplitTunnelAction>(
        title: l10n.splitTunnelDefaultTitle,
        value: _settings.splitTunnelDefaultAction,
        values: SplitTunnelAction.values,
        labelOf: (action) => _splitActionLabel(l10n, action),
        onChanged: (v) => _settings.splitTunnelDefaultAction = v,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
        child: Text(l10n.splitTunnelActionLabel, style: hint),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
        child: SegmentedButton<SplitTunnelAction>(
          segments: [
            ButtonSegment(
              value: SplitTunnelAction.tunnel,
              icon: const Icon(Icons.vpn_lock, size: 18),
              label: Text(l10n.splitTunnelActionTunnel),
            ),
            ButtonSegment(
              value: SplitTunnelAction.direct,
              icon: const Icon(Icons.alt_route, size: 18),
              label: Text(l10n.splitTunnelActionDirect),
            ),
          ],
          selected: {_newSplitAction},
          showSelectedIcon: false,
          onSelectionChanged: (selection) =>
              setState(() => _newSplitAction = selection.first),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _splitPatternController,
                onSubmitted: (_) => _addSplitRule(),
                decoration: InputDecoration(
                  labelText: l10n.splitTunnelPatternLabel,
                  helperText: l10n.splitTunnelPatternHelper,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            IconButton(
              tooltip: l10n.splitTunnelAddRule,
              icon: const Icon(Icons.add_circle_outline),
              onPressed: _addSplitRule,
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final tld in splitTunnelTldPresets)
              ActionChip(
                label: Text('.$tld'),
                visualDensity: VisualDensity.compact,
                onPressed: () => _addSplitRule(preset: '.$tld'),
              ),
          ],
        ),
      ),
      if (rules.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
          child: Text(l10n.splitTunnelNoRules, style: hint),
        )
      else
        for (var index = 0; index < rules.length; index++)
          _splitRuleTile(l10n, rules[index], index),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
        child: Text(l10n.splitTunnelApplyHint, style: hint),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_settings, UpdateChecker.instance]),
      builder: (context, _) {
        final l10n = AppLocalizations.of(context);
        return Scaffold(
          appBar: AppBar(title: Text(l10n.navSettings), centerTitle: true),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                _SectionTitle(l10n.sectionAppearance),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: SegmentedButton<ThemeModeSetting>(
                    segments: [
                      ButtonSegment(
                        value: ThemeModeSetting.system,
                        icon: const Icon(Icons.brightness_auto),
                        label: Text(l10n.themeAuto),
                      ),
                      ButtonSegment(
                        value: ThemeModeSetting.light,
                        icon: const Icon(Icons.light_mode),
                        label: Text(l10n.themeLight),
                      ),
                      ButtonSegment(
                        value: ThemeModeSetting.dark,
                        icon: const Icon(Icons.dark_mode),
                        label: Text(l10n.themeDark),
                      ),
                    ],
                    selected: {_settings.themeMode},
                    onSelectionChanged: (selection) =>
                        _settings.themeMode = selection.first,
                  ),
                ),
                _SectionTitle(l10n.sectionLanguage),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: SegmentedButton<AppLanguage>(
                    segments: [
                      ButtonSegment(
                        value: AppLanguage.system,
                        icon: const Icon(Icons.settings_input_antenna),
                        label: Text(l10n.languageSystem),
                      ),
                      ButtonSegment(
                        value: AppLanguage.en,
                        icon: const Icon(Icons.translate),
                        label: Text(l10n.languageEnglish),
                      ),
                      ButtonSegment(
                        value: AppLanguage.fa,
                        icon: const Icon(Icons.translate),
                        label: Text(l10n.languagePersian),
                      ),
                    ],
                    selected: {_settings.appLanguage},
                    onSelectionChanged: (selection) =>
                        _settings.appLanguage = selection.first,
                  ),
                ),
                const SizedBox(height: 8),
                _SectionTitle(l10n.sectionConnection),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.exitCheckTitle),
                  subtitle: Text(l10n.exitCheckSubtitle),
                  value: _settings.exitCheckEnabled,
                  onChanged: (v) => _settings.exitCheckEnabled = v,
                ),
                _SectionTitle(l10n.sectionConnectionMode),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SegmentedButton<ConnectionMode>(
                        segments: [
                          ButtonSegment(
                            value: ConnectionMode.proxy,
                            icon: const Icon(Icons.lan_outlined),
                            label: Text(l10n.connectionModeProxy),
                          ),
                          ButtonSegment(
                            value: ConnectionMode.systemProxy,
                            icon: const Icon(Icons.settings_ethernet),
                            label: Text(l10n.connectionModeSystemProxy),
                          ),
                          ButtonSegment(
                            value: ConnectionMode.tunnel,
                            icon: const Icon(Icons.vpn_lock),
                            label: Text(l10n.connectionModeTunnel),
                          ),
                        ],
                        selected: {_settings.connectionMode},
                        onSelectionChanged: (selection) =>
                            _settings.connectionMode = selection.first,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        switch (_settings.connectionMode) {
                          ConnectionMode.proxy =>
                            l10n.connectionModeProxyDesc,
                          ConnectionMode.systemProxy =>
                            l10n.connectionModeSystemProxyDesc,
                          ConnectionMode.tunnel =>
                            l10n.connectionModeTunnelDesc,
                        },
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                _DropdownTile<DohProvider>(
                  title: l10n.dohTitle,
                  value: _settings.dohProvider,
                  values: DohProvider.values,
                  labelOf: (p) => p.label,
                  onChanged: (v) => _settings.dohProvider = v,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.customDnsTitle),
                  subtitle: Text(l10n.customDnsSubtitle),
                  value: _settings.customDnsEnabled,
                  onChanged: (v) => _settings.customDnsEnabled = v,
                ),
                if (_settings.customDnsEnabled)
                  _TextFieldTile(
                    label: l10n.customDnsLabel,
                    controller: _customDnsController,
                    keyboardType: TextInputType.text,
                    helper: l10n.customDnsHelper,
                    onSubmitted: (v) {
                      _settings.customDnsServer = v;
                      _customDnsController.text = _settings.customDnsServer;
                      if (!SettingsStore.isValidDnsServer(v.trim())) {
                        _showError(l10n.errorInvalidDns);
                      }
                    },
                    presets: SettingsStore.customDnsPresets,
                    onPreset: (value) {
                      setState(() => _customDnsController.text = value);
                      _settings.customDnsServer = value;
                    },
                  ),
                _TextFieldTile(
                  label: l10n.pinnedEdgeLabel,
                  controller: _edgeController,
                  helper: l10n.pinnedEdgeHelper,
                  onSubmitted: (v) {
                    _settings.customEdgeAddress = v;
                    final stored = _settings.customEdgeAddress;
                    if (v.trim().isNotEmpty &&
                        stored != v.trim().toLowerCase()) {
                      _showError(l10n.errorInvalidHostOrIp);
                    }
                  },
                ),
                _SectionTitle(l10n.sectionLocalProxy),
                _TextFieldTile(
                  label: l10n.bindAddressLabel,
                  controller: _socksBindController,
                  helper: l10n.localProxyApplyHint,
                  onSubmitted: (v) {
                    if (!SettingsStore.isValidIpAddress(v.trim())) {
                      _showError(l10n.errorInvalidIp);
                      return;
                    }
                    _settings.socksBindAddress = v;
                  },
                  presets: SettingsStore.socksBindAddressPresets,
                  onPreset: (value) {
                    setState(() => _socksBindController.text = value);
                    _settings.socksBindAddress = value;
                  },
                ),
                _TextFieldTile(
                  label: l10n.portLabel,
                  controller: _socksPortController,
                  keyboardType: TextInputType.number,
                  helper: l10n.localProxyApplyHint,
                  onSubmitted: (v) {
                    final port = int.tryParse(v.trim());
                    if (port == null || port < 1 || port > 65535) {
                      _showError(l10n.errorInvalidPort);
                      return;
                    }
                    _settings.socksPort = port;
                  },
                ),
                _SectionTitle(l10n.sectionSplitTunnel),
                ..._splitTunnelSection(l10n),
                _SectionTitle(l10n.sectionUpstreamProxy),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l10n.upstreamTitle),
                  subtitle: Text(l10n.upstreamSubtitle),
                  value: _settings.upstreamProxyEnabled,
                  onChanged: (v) => _settings.upstreamProxyEnabled = v,
                ),
                if (_settings.upstreamProxyEnabled) ...[
                  _DropdownTile<UpstreamProxyType>(
                    title: l10n.proxyTypeLabel,
                    value: _settings.upstreamProxyType,
                    values: UpstreamProxyType.values,
                    labelOf: (t) => t == UpstreamProxyType.socks5
                        ? 'SOCKS5'
                        : l10n.proxyTypeHttp,
                    onChanged: (v) => _settings.upstreamProxyType = v,
                  ),
                  _TextFieldTile(
                    label: l10n.proxyHostLabel,
                    controller: _proxyHostController,
                    onSubmitted: (v) => _settings.upstreamProxyHost = v,
                  ),
                  _TextFieldTile(
                    label: l10n.proxyPortLabel,
                    controller: _proxyPortController,
                    keyboardType: TextInputType.number,
                    onSubmitted: (v) {
                      final port = int.tryParse(v.trim());
                      if (port != null) _settings.upstreamProxyPort = port;
                    },
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: _fillFromSystemProxy,
                      icon: const Icon(Icons.settings_ethernet, size: 18),
                      label: Text(l10n.copyFromSystemProxy),
                    ),
                  ),
                  _TextFieldTile(
                    label: l10n.proxyUsernameLabel,
                    controller: _proxyUsernameController,
                    onSubmitted: (_) => _saveProxyCredentials(),
                  ),
                  _TextFieldTile(
                    label: l10n.proxyPasswordLabel,
                    controller: _proxyPasswordController,
                    obscure: true,
                    onSubmitted: (_) => _saveProxyCredentials(),
                  ),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 0, 0),
                      child: TextButton.icon(
                        icon: const Icon(Icons.save_outlined),
                        label: Text(l10n.saveCredentials),
                        onPressed: _saveProxyCredentials,
                      ),
                    ),
                  ),
                ],
                _SectionTitle(l10n.sectionTunnelEngine),
                _TextFieldTile(
                  label: l10n.tunnelPathLabel,
                  controller: _tunnelPathController,
                  helper: l10n.tunnelPathHelper,
                  onSubmitted: (v) => _settings.hevTunnelBinaryPath = v,
                ),
                _SectionTitle(l10n.sectionAbout),
                _updateTile(l10n),
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
                            Expanded(
                              child: Text(
                                l10n.aboutBody,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            l10n.aboutVersion(AppVersion.full),
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          leading: const Icon(Icons.code, size: 20),
                          title: Text(
                            l10n.aboutSource,
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.copy, size: 18),
                            tooltip: l10n.copySourceUrl,
                            onPressed: () {
                              Clipboard.setData(
                                const ClipboardData(
                                  text: 'https://github.com/M-RTZ1/FoxyVPN',
                                ),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(l10n.sourceUrlCopied),
                                  behavior: SnackBarBehavior.floating,
                                  duration: const Duration(seconds: 2),
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
    // Letter-spacing tears Persian glyph joins apart; keep it for Latin only.
    final letterSpacing = Directionality.of(context) == TextDirection.ltr
        ? 0.8
        : 0.0;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(4, 18, 4, 6),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: scheme.primary,
          letterSpacing: letterSpacing,
        ),
      ),
    );
  }
}

/// A labelled field that commits its value as soon as it loses focus, not
/// only on Enter: in a desktop window the pointer, not the keyboard, is how
/// the user leaves a field, and a setting that never got saved looks like a
/// setting that was ignored.
class _TextFieldTile extends StatefulWidget {
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
  State<_TextFieldTile> createState() => _TextFieldTileState();
}

class _TextFieldTileState extends State<_TextFieldTile> {
  late final FocusNode _focusNode;
  late String _lastCommitted;

  @override
  void initState() {
    super.initState();
    _lastCommitted = widget.controller.text;
    _focusNode = FocusNode()..addListener(_commit);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_commit);
    _focusNode.dispose();
    super.dispose();
  }

  /// A desktop user leaves a field with the pointer, not with Enter, so an
  /// uncommitted edit would otherwise be silently dropped when focus ends.
  void _commit() {
    if (_focusNode.hasFocus) return;
    final text = widget.controller.text;
    if (text == _lastCommitted) return;
    _lastCommitted = text;
    widget.onSubmitted?.call(text);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: widget.controller,
            focusNode: _focusNode,
            obscureText: widget.obscure,
            keyboardType: widget.keyboardType,
            inputFormatters: widget.keyboardType == TextInputType.number
                ? [FilteringTextInputFormatter.digitsOnly]
                : null,
            // Enter commits here; the blur listener skips it because the text
            // has not changed since.
            onSubmitted: (_) => _commit(),
            decoration: InputDecoration(
              labelText: widget.label,
              helperText: widget.helper,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
          ),
          if (widget.presets.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final (value, name) in widget.presets)
                  ActionChip(
                    label: Text(name),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => widget.onPreset?.call(value),
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
            child: Text(title, style: Theme.of(context).textTheme.bodyMedium),
          ),
          DropdownButton<T>(
            value: value,
            items: [
              for (final item in values)
                DropdownMenuItem(value: item, child: Text(labelOf(item))),
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
