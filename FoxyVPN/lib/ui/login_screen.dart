import 'package:flutter/material.dart';

import '../data/fxa_auth_repository.dart';
import '../data/token_store.dart';

/// Firefox Accounts sign-in: email + password, then an email-2FA code step
/// when the account requires it.
class LoginScreen extends StatefulWidget {
  const LoginScreen({required this.onSignedIn, super.key});

  final VoidCallback onSignedIn;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _codeController = TextEditingController();

  bool _twoFactorStep = false;
  bool _busy = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final needsTwoFactor = await FxaAuthRepository(TokenStore.instance)
          .startLogin(
              _emailController.text.trim(), _passwordController.text);
      if (!mounted) return;
      if (needsTwoFactor) {
        setState(() {
          _twoFactorStep = true;
          _busy = false;
        });
      } else {
        widget.onSignedIn();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is FxaApiError ? e.message : e.toString();
      });
    }
  }

  Future<void> _submitCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FxaAuthRepository(TokenStore.instance).submitTwoFactorCode(code);
      if (!mounted) return;
      widget.onSignedIn();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is FxaApiError ? e.message : e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.vpn_lock_rounded, size: 64, color: scheme.primary),
                  const SizedBox(height: 12),
                  Text(
                    'FoxyVPN',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _twoFactorStep
                        ? 'Enter the verification code sent to your email'
                        : 'Sign in with your Firefox Account',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 28),
                  if (!_twoFactorStep) ...[
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.alternate_email),
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => (v == null || !v.contains('@'))
                          ? 'Enter a valid email address'
                          : null,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      autofillHints: const [AutofillHints.password],
                      onFieldSubmitted: (_) => _busy ? null : _signIn(),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(_obscurePassword
                              ? Icons.visibility
                              : Icons.visibility_off),
                          onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                      validator: (v) =>
                          (v == null || v.isEmpty) ? 'Enter your password' : null,
                    ),
                  ] else ...[
                    TextFormField(
                      controller: _codeController,
                      keyboardType: TextInputType.number,
                      autofocus: true,
                      onFieldSubmitted: (_) => _busy ? null : _submitCode(),
                      decoration: const InputDecoration(
                        labelText: 'Verification code',
                        prefixIcon: Icon(Icons.pin_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.error, fontSize: 13),
                    ),
                  ],
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : (_twoFactorStep ? _submitCode : _signIn),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: _busy
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          )
                        : Text(_twoFactorStep ? 'Verify' : 'Sign in'),
                  ),
                  if (_twoFactorStep) ...[
                    const SizedBox(height: 10),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _twoFactorStep = false;
                                _error = null;
                              }),
                      child: const Text('Back to sign-in'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
