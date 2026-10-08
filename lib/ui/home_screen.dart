import 'package:flutter/material.dart' hide ConnectionState;

import '../core/app_logger.dart';
import '../core/app_version.dart';
import '../core/byte_format.dart';
import '../data/models.dart';
import '../data/proxy_state_store.dart';
import '../data/token_store.dart';
import '../data/update_checker.dart';
import '../l10n/generated/app_localizations.dart';
import '../vpn/vpn_controller.dart';

/// Main screen: power button, connection status, speed and quota readouts.
class HomeScreen extends StatefulWidget {
  const HomeScreen({required this.onSignedOut, super.key});

  final VoidCallback onSignedOut;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  VpnController get _vpn => VpnController.instance;
  UpdateChecker get _update => UpdateChecker.instance;

  Future<void> _signOut() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.signOutDialogTitle),
        content: Text(l10n.signOutDialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.actionSignOut),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _vpn.disconnect('the user signed out');
    try {
      await TokenStore.instance.clear();
    } catch (e) {
      AppLogger.w('HomeScreen', 'could not clear stored tokens', e);
    }
    if (mounted) widget.onSignedOut();
  }

  Future<void> _togglePower() async {
    switch (_vpn.state) {
      case ConnectionState.disconnected:
        await _vpn.connect();
      case ConnectionState.connecting:
        await _vpn.disconnect('cancelled while connecting');
      case ConnectionState.connected:
        await _vpn.disconnect();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _vpn,
        ProxyStateStore.instance,
        UpdateChecker.instance,
      ]),
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final l10n = AppLocalizations.of(context);
        final state = _vpn.state;
        final selected = ProxyStateStore.instance.load();

        return Scaffold(
          appBar: AppBar(
            title: const Text('FoxyVPN'),
            centerTitle: true,
            actions: [
              IconButton(
                tooltip: l10n.actionSignOut,
                icon: const Icon(Icons.logout),
                onPressed: _signOut,
              ),
            ],
          ),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              children: [
                const SizedBox(height: 16),
                Center(
                  child: _PowerButton(state: state, onTap: _togglePower),
                ),
                const SizedBox(height: 20),
                Text(
                  _statusText(l10n),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  switch (state) {
                    ConnectionState.connected => _locationLabel(selected, l10n),
                    ConnectionState.connecting => l10n.homeEstablishingTunnel,
                    ConnectionState.disconnected => l10n.homeTrafficUnprotected,
                  },
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (_vpn.lastError != null) ...[
                  const SizedBox(height: 14),
                  Card(
                    color: scheme.errorContainer,
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 20,
                            color: scheme.onErrorContainer,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _vpn.lastError!,
                              style: TextStyle(
                                color: scheme.onErrorContainer,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (_update.updateAvailable) ...[
                  const SizedBox(height: 14),
                  _UpdateCard(
                    release: _update.latest!,
                    onDownload: _update.openDownload,
                    onDismiss: _update.dismissLatest,
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: _StatCard(
                        icon: Icons.arrow_downward,
                        label: l10n.statDownload,
                        value: state == ConnectionState.connected
                            ? formatBytesPerSecond(_vpn.downloadBytesPerSecond)
                            : '—',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatCard(
                        icon: Icons.arrow_upward,
                        label: l10n.statUpload,
                        value: state == ConnectionState.connected
                            ? formatBytesPerSecond(_vpn.uploadBytesPerSecond)
                            : '—',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _QuotaCard(vpn: _vpn),
                const SizedBox(height: 12),
                _ServerCard(selected: selected),
                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }

  String _statusText(AppLocalizations l10n) {
    return switch (_vpn.statusKind) {
      VpnStatusKind.disconnected => l10n.statusDisconnected,
      VpnStatusKind.connecting => l10n.statusConnecting,
      VpnStatusKind.waitingForNetwork => l10n.statusWaitingForNetwork,
      VpnStatusKind.reconnecting => l10n.statusReconnecting,
      VpnStatusKind.connectedVpn => l10n.statusConnectedVpn(_vpn.statusDetail),
      VpnStatusKind.proxyActive => l10n.statusProxyActive(_vpn.statusDetail),
    };
  }

  String _locationLabel(ProxyCandidate? selected, AppLocalizations l10n) {
    if (selected == null) return l10n.autoSelectedLocation;
    final country = selected.countryName.isNotEmpty
        ? selected.countryName
        : selected.countryCode;
    final city = selected.cityCode.isNotEmpty ? ' • ${selected.cityCode}' : '';
    return l10n.exitLocation('$country$city');
  }
}

class _PowerButton extends StatelessWidget {
  const _PowerButton({required this.state, required this.onTap});

  final ConnectionState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final connected = state == ConnectionState.connected;
    final connecting = state == ConnectionState.connecting;
    final background = connected
        ? scheme.primary
        : scheme.surfaceContainerHighest;
    final foreground = connected ? scheme.onPrimary : scheme.onSurfaceVariant;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: 168,
        height: 168,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: background,
          boxShadow: connected
              ? [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.4),
                    blurRadius: 32,
                    spreadRadius: 2,
                  ),
                ]
              : null,
        ),
        child: Center(
          child: connecting
              ? SizedBox(
                  width: 64,
                  height: 64,
                  child: CircularProgressIndicator(
                    strokeWidth: 5,
                    color: foreground,
                  ),
                )
              : Icon(
                  Icons.power_settings_new_rounded,
                  size: 64,
                  color: foreground,
                ),
        ),
      ),
    );
  }
}

/// Shown when the GitHub release check found a newer build.
class _UpdateCard extends StatelessWidget {
  const _UpdateCard({
    required this.release,
    required this.onDownload,
    required this.onDismiss,
  });

  final GithubRelease release;
  final Future<void> Function() onDownload;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final asset = release.assetName;
    final changelog = release.changelog;

    return Card(
      color: scheme.secondaryContainer,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.system_update_alt,
                  size: 20,
                  color: scheme.onSecondaryContainer,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.updateAvailableTitle(release.version),
                    style: TextStyle(
                      color: scheme.onSecondaryContainer,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              l10n.updateAvailableBody(AppVersion.number),
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSecondaryContainer,
              ),
            ),
            if (changelog.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                changelog,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onDismiss,
                  child: Text(l10n.updateActionNotNow),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed: () => onDownload(),
                  child: Text(
                    asset == null
                        ? l10n.updateActionOpenRelease
                        : l10n.updateActionDownload(asset),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        child: Column(
          children: [
            Icon(icon, size: 20, color: scheme.primary),
            const SizedBox(height: 6),
            Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuotaCard extends StatelessWidget {
  const _QuotaCard({required this.vpn});

  final VpnController vpn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final remaining = vpn.quotaRemainingBytes;
    final max = vpn.quotaMaxBytes;

    Widget child;
    if (remaining == null) {
      child = Row(
        children: [
          Icon(Icons.data_usage_outlined, size: 20, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l10n.quotaPending,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      );
    } else {
      final usedFraction = (max != null && max > 0)
          ? (1 - remaining / max).clamp(0.0, 1.0)
          : 0.0;
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.data_usage_outlined, size: 20, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  max != null
                      ? l10n.quotaLeftOf(
                          formatBytes(remaining),
                          formatBytes(max),
                        )
                      : l10n.quotaLeft(formatBytes(remaining)),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: usedFraction,
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ],
      );
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(padding: const EdgeInsets.all(14), child: child),
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({required this.selected});

  final ProxyCandidate? selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final country = selected == null
        ? l10n.serverCardRecommended
        : (selected!.countryName.isNotEmpty
              ? selected!.countryName
              : selected!.countryCode);
    final details = selected == null
        ? l10n.serverCardPickLocation
        : '${selected!.cityCode.isNotEmpty ? '${selected!.cityCode} • ' : ''}${selected!.authority}';

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(Icons.location_on_outlined, color: scheme.primary),
        title: Text(country),
        subtitle: Text(
          details,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
