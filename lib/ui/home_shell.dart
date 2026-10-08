import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import 'home_screen.dart';
import 'logs_screen.dart';
import 'server_list_screen.dart';
import 'settings_screen.dart';

/// Phone-style shell: page body plus a bottom navigation bar.
class HomeShell extends StatefulWidget {
  const HomeShell({required this.onSignedOut, super.key});

  final VoidCallback onSignedOut;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  late final List<Widget> _pages = [
    HomeScreen(onSignedOut: widget.onSignedOut),
    const ServerListScreen(),
    const SettingsScreen(),
    const LogsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.power_settings_new_outlined),
            selectedIcon: const Icon(Icons.power_settings_new),
            label: l10n.navHome,
          ),
          NavigationDestination(
            icon: const Icon(Icons.public_outlined),
            selectedIcon: const Icon(Icons.public),
            label: l10n.navServers,
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: l10n.navSettings,
          ),
          NavigationDestination(
            icon: const Icon(Icons.receipt_long_outlined),
            selectedIcon: const Icon(Icons.receipt_long),
            label: l10n.navLogs,
          ),
        ],
      ),
    );
  }
}
