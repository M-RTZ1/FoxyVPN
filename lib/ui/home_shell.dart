import 'package:flutter/material.dart';

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
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.power_settings_new_outlined),
            selectedIcon: Icon(Icons.power_settings_new),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.public_outlined),
            selectedIcon: Icon(Icons.public),
            label: 'Servers',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'Logs',
          ),
        ],
      ),
    );
  }
}
