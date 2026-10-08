import 'package:flutter/material.dart';

import '../core/app_logger.dart';
import '../data/models.dart' hide ConnectionState;
import '../data/proxy_state_store.dart';
import '../data/server_list_client.dart';
import '../l10n/generated/app_localizations.dart';

/// Mozilla VPN server list: pick a country, then a specific edge.
class ServerListScreen extends StatefulWidget {
  const ServerListScreen({super.key});

  @override
  State<ServerListScreen> createState() => _ServerListScreenState();
}

class _ServerListScreenState extends State<ServerListScreen> {
  late Future<List<VpnCountry>> _countriesFuture;
  final _client = ServerListClient();

  @override
  void initState() {
    super.initState();
    _countriesFuture = _loadCountries();
  }

  Future<List<VpnCountry>> _loadCountries() {
    return _client.fetchCountries().then((countries) {
      _cached = countries;
      return countries;
    }).catchError((Object e) {
      AppLogger.w('ServerListScreen', 'server list fetch failed', e);
      throw e;
    });
  }

  void _reload() {
    setState(() => _countriesFuture = _loadCountries());
  }

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
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.serversTitle),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: l10n.serversReload,
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<List<VpnCountry>>(
          future: _countriesFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return _ErrorState(
                message: l10n.serversLoadFailed('${snapshot.error}'),
                onRetry: _reload,
              );
            }
            final countries = snapshot.data ?? const [];
            if (countries.isEmpty) {
              return _ErrorState(
                message: l10n.serversNoneAvailable,
                onRetry: _reload,
              );
            }
            return _CountryList(countries: countries, onTap: _openCountry);
          },
        ),
      ),
    );
  }

  void _openCountry(VpnCountry country) {
    final candidates =
        ServerListClient.candidatesForCountry(_cached, country.code);
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

  List<VpnCountry> _cached = const [];
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

class _CityServersPage extends StatelessWidget {
  const _CityServersPage({
    required this.country,
    required this.candidates,
    required this.onSelect,
  });

  final VpnCountry country;
  final List<ProxyCandidate> candidates;
  final Future<void> Function(ProxyCandidate) onSelect;

  @override
  Widget build(BuildContext context) {
    final selected = ProxyStateStore.instance.load();
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(country.name.isEmpty ? country.code : country.name),
        centerTitle: true,
      ),
      body: SafeArea(
        child: candidates.isEmpty
            ? Center(child: Text(l10n.serversNoServers))
            : ListView.separated(
                itemCount: candidates.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final candidate = candidates[index];
                  final isSelected =
                      selected?.authority == candidate.authority;
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
                    subtitle: Text(l10n.serversPort(candidate.port)),
                    onTap: () => onSelect(candidate),
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
