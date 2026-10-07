import 'package:flutter/material.dart' hide ConnectionState;

import '../core/app_logger.dart';
import '../core/byte_format.dart';
import '../data/models.dart';
import '../data/proxy_state_store.dart';
import '../data/token_store.dart';
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

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
            'The tunnel will be disconnected and your Firefox Account '
            'session removed from this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
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
      animation: Listenable.merge([_vpn, ProxyStateStore.instance]),
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final state = _vpn.state;
        final selected = ProxyStateStore.instance.load();

        return Scaffold(
          appBar: AppBar(
            title: const Text('FoxyVPN'),
            centerTitle: true,
            actions: [
              IconButton(
                tooltip: 'Sign out',
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
                Center(child: _PowerButton(state: state, onTap: _togglePower)),
                const SizedBox(height: 20),
                Text(
                  _vpn.statusLabel,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  switch (state) {
                    ConnectionState.connected =>
                      _locationLabel(selected),
                    ConnectionState.connecting => 'Establishing the tunnel…',
                    ConnectionState.disconnected =>
                      'Your traffic is not protected',
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
                          Icon(Icons.error_outline,
                              size: 20, color: scheme.onErrorContainer),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _vpn.lastError!,
                              style: TextStyle(
                                  color: scheme.onErrorContainer, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: _StatCard(
                        icon: Icons.arrow_downward,
                        label: 'Download',
                        value: state == ConnectionState.connected
                            ? formatBytesPerSecond(_vpn.downloadBytesPerSecond)
                            : '—',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatCard(
                        icon: Icons.arrow_upward,
                        label: 'Upload',
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

  String _locationLabel(ProxyCandidate? selected) {
    if (selected == null) return 'Auto-selected location';
    final country =
        selected.countryName.isNotEmpty ? selected.countryName : selected.countryCode;
    final city = selected.cityCode.isNotEmpty ? ' • ${selected.cityCode}' : '';
    return 'Exit location: $country$city';
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

class _StatCard extends StatelessWidget {
  const _StatCard(
      {required this.icon, required this.label, required this.value});

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
            Text(value,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600)),
            Text(label,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
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
              'Quota information appears once the tunnel connects.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
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
                      ? '${formatBytes(remaining)} left of ${formatBytes(max)}'
                      : '${formatBytes(remaining)} left',
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
    final country = selected == null
        ? 'Recommended (automatic)'
        : (selected!.countryName.isNotEmpty
            ? selected!.countryName
            : selected!.countryCode);
    final details = selected == null
        ? 'Pick a location on the Servers tab'
        : '${selected!.cityCode.isNotEmpty ? '${selected!.cityCode} • ' : ''}${selected!.authority}';

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(Icons.location_on_outlined, color: scheme.primary),
        title: Text(country),
        subtitle: Text(details,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant)),
      ),
    );
  }
}
