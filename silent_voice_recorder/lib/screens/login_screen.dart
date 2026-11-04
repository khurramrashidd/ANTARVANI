import 'package:flutter/material.dart';

import '../app/l10n.dart';
import '../app/settings.dart';
import '../app/theme.dart';
import '../services/auth_service.dart';
import '../widgets/common.dart';

/// First screen. One button signs in, and also registers anyone new — they
/// start as a patient, and the master admin promotes collectors.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _busy = false;

  Future<void> _signIn() async {
    setState(() => _busy = true);
    final err = await AuthService.instance.signInWithGoogle();
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null && err != 'cancelled') {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('login_failed'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: Brand.gradient),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      // Language picker, top right
                      Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: _LangMenu(settings: settings),
                        ),
                      ),
                      const SizedBox(height: 40),
                      const BrandLogo(size: 108),
                      const SizedBox(height: 22),
                      Text(tr('app_name'),
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 34,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 4)),
                      const SizedBox(height: 6),
                      Text(tr('tagline'),
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 16)),
                      const SizedBox(height: 48),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(22),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(tr('login_title'),
                                  style: const TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.w800)),
                              const SizedBox(height: 8),
                              Text(tr('login_body'),
                                  style: const TextStyle(height: 1.4)),
                              const SizedBox(height: 22),
                              FilledButton.icon(
                                onPressed: _busy ? null : _signIn,
                                icon: _busy
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white))
                                    : const Icon(Icons.login),
                                label: Text(_busy
                                    ? tr('signing_in')
                                    : tr('continue_google')),
                              ),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  Icon(Icons.lock_outline,
                                      size: 16,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(tr('login_privacy'),
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LangMenu extends StatelessWidget {
  final AppSettings settings;
  const _LangMenu({required this.settings});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      onSelected: settings.setLang,
      itemBuilder: (_) => AppSettings.languages.entries
          .map((e) => PopupMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.translate, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Text(AppSettings.languages[settings.lang]!,
                style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );
  }
}
