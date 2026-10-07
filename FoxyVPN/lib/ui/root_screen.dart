import 'package:flutter/material.dart';

import '../core/app_logger.dart';
import '../data/fxa_auth_repository.dart';
import '../data/token_store.dart';
import 'home_shell.dart';
import 'login_screen.dart';

/// Restores a stored Firefox Accounts session on startup and routes to
/// either the sign-in screen or the main shell.
class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  late final Future<SessionStatus> _restore;
  bool _signedIn = false;
  bool _signedOut = false;

  @override
  void initState() {
    super.initState();
    _restore = _restoreSession();
  }

  Future<SessionStatus> _restoreSession() async {
    try {
      return await FxaAuthRepository(TokenStore.instance).restoreSession();
    } catch (e) {
      AppLogger.w('RootScreen', 'session restore failed', e);
      return SessionStatus.needsLogin;
    }
  }

  Widget _shell() => HomeShell(
        onSignedOut: () => setState(() {
          _signedIn = false;
          _signedOut = true;
        }),
      );

  Widget _login() => LoginScreen(
        onSignedIn: () => setState(() {
          _signedOut = false;
          _signedIn = true;
        }),
      );

  @override
  Widget build(BuildContext context) {
    if (_signedOut) return _login();
    if (_signedIn) return _shell();
    return FutureBuilder<SessionStatus>(
      future: _restore,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const _Splash();
        }
        if (snapshot.data == SessionStatus.active) {
          return _shell();
        }
        return _login();
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipOval(
              child: Image.asset(
                'assets/images/foxyvpn_logo.jpg',
                width: 96,
                height: 96,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 16),
            Text('FoxyVPN',
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
