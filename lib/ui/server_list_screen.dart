import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart' hide ConnectionState;
import '../data/proxy_state_store.dart';
import '../data/server_list_client.dart';
import '../data/server_list_store.dart';
import '../l10n/generated/app_localizations.dart';
import '../vpn/ping_util.dart';

enum _PingState { pending, done, failed }

/// Mozilla VPN server list: pick a country, then a specific edge.
class ServerListScreen extends StatefulWidget {
  const ServerListScreen({super.key});

  @override
  State<ServerListScreen> createState() => _ServerListScreenState();
}

class _ServerListScreenState extends State<ServerListScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(ServerListStore.instance.boot());
  }

  void _reload() => unawaited(ServerListStore.instance.refresh());

  Future<void> _selectCandidate(ProxyCandidate candidate) async {
    ProxyStateStore.instance.save(candidate);
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final country = candidate.countryName.isNotEmpty
        ? candidate.countryName
        : candidate.countryCode;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.serversLocationSet(country, candidate.authority)),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final store = ServerListStore.instance;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(l10n.serversTitle),
          centerTitle: true,
          actions: [
            if (store.refreshing)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            IconButton(
              tooltip: l10n.serversReload,
              icon: const Icon(Icons.refresh),
              onPressed: _reload,
            ),
          ],
        ),
        body: SafeArea(
          child: _listBody(l10n, store),
        ),
      ),
    );
  }

  /// Painted from the store, so the list is on screen before any request has
  /// answered; an empty list means even the bundled snapshot was unreadable.
  Widget _listBody(AppLocalizations l10n, ServerListStore store) {
    final countries = store.countries;
    if (countries.isEmpty) {
      if (store.refreshing) {
        return const Center(child: CircularProgressIndicator());
      }
      return _ErrorState(
        message: l10n.serversNoneAvailable,
        onRetry: _reload,
      );
    }
    return Column(
      children: [
        if (store.origin == ServerListOrigin.bundled && !store.refreshing)
          const _BundledSnapshotBanner(),
        Expanded(
          child: _CountryList(
            countries: countries,
            onTap: _openCountry,
          ),
        ),
      ],
    );
  }

  void _openCountry(VpnCountry country) {
    final candidates = ServerListClient.candidatesForCountry(
        ServerListStore.instance.countries, country.code);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => _CityServersPage(
          country: country,
          candidates: candidates,
          onSelect: (candidate) async {
            await _selectCandidate(candidate);
            if (context.mounted) Navigator.of(context).pop();
          },
        ),
      ),
    );
  }
}

/// Shown instead of an empty list when Remote Settings cannot be reached at
/// all, so a stale location is never mistaken for the live one.
class _BundledSnapshotBanner extends StatelessWidget {
  const _BundledSnapshotBanner();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(
              Icons.cloud_off,
              size: 18,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.serversBundledSnapshot,
                style: TextStyle(
                  color: scheme.onSecondaryContainer,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CountryList extends StatelessWidget {
  const _CountryList({required this.countries, required this.onTap});

  final List<VpnCountry> countries;
  final void Function(VpnCountry) onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListView.separated(
      itemCount: countries.length + 1,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == 0) {
          return ListTile(
            leading: const Icon(Icons.auto_awesome),
            title: Text(l10n.serversRecommended),
            subtitle: Text(l10n.serversRecommendedSubtitle),
            onTap: () {
              ProxyStateStore.instance.clear();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(l10n.serversAutoChosen),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          );
        }
        final country = countries[index - 1];
        return ListTile(
          leading: CircleAvatar(
            radius: 16,
            child: Text(country.code.isEmpty ? '?' : country.code[0]),
          ),
          title: Text(country.name.isEmpty ? country.code : country.name),
          subtitle: Text(l10n.serversCityCount(country.cities.length)),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => onTap(country),
        );
      },
    );
  }
}

class _CityServersPage extends StatefulWidget {
  const _CityServersPage({
    required this.country,
    required this.candidates,
    required this.onSelect,
  });

  final VpnCountry country;
  final List<ProxyCandidate> candidates;
  final Future<void> Function(ProxyCandidate) onSelect;

  @override
  State<_CityServersPage> createState() => _CityServersPageState();
}

class _CityServersPageState extends State<_CityServersPage> {
  final Map<String, int> _pingMs = <String, int>{};
  final Map<String, _PingState> _pingState = <String, _PingState>{};
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _startPings();
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  Future<void> _startPings() async {
    final futures = <Future<void>>[];
    for (final candidate in widget.candidates) {
      final key = candidate.authority;
      futures.add(() async {
        final ms = await PingUtil.measureTcpLatencyMs(
            candidate.host, candidate.port);
        if (_cancelled || !mounted) return;
        setState(() {
          if (ms != null) {
            _pingMs[key] = ms;
            _pingState[key] = _PingState.done;
          } else {
            _pingState[key] = _PingState.failed;
          }
        });
      }());
    }
    await Future.wait(futures);
  }

  String _pingLabelFor(String key, AppLocalizations l10n) {
    final state = _pingState[key] ?? _PingState.pending;
    switch (state) {
      case _PingState.done:
        final ms = _pingMs[key];
        return ms != null ? l10n.serversPingResult(ms) : l10n.serversPingUnavailable;
      case _PingState.failed:
        return l10n.serversPingUnavailable;
      case _PingState.pending:
        return l10n.serversPinging;
    }
  }

  @override
  Widget build(BuildContext context) {
    final selected = ProxyStateStore.instance.load();
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.country.name.isEmpty
            ? widget.country.code
            : widget.country.name),
        centerTitle: true,
      ),
      body: SafeArea(
        child: widget.candidates.isEmpty
            ? Center(child: Text(l10n.serversNoServers))
            : ListView.separated(
                itemCount: widget.candidates.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final candidate = widget.candidates[index];
                  final isSelected =
                      selected?.authority == candidate.authority;
                  final key = candidate.authority;
                  final pingText = _pingLabelFor(key, l10n);
                  return ListTile(
                    leading: Icon(
                      isSelected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    title: Text(candidate.cityCode.isEmpty
                        ? candidate.host
                        : '${candidate.cityCode} • ${candidate.host}'),
                    subtitle: Text('${l10n.serversPort(candidate.port)} • $pingText'),
                    onTap: () => widget.onSelect(candidate),
                  );
                },
              ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: scheme.error),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.refresh),
              label: Text(l10n.serversTryAgain),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}
