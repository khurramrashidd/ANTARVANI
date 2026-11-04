import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'app/settings.dart';
import 'app/theme.dart';
import 'firebase_options.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'services/auth_service.dart';
import 'services/sync_service.dart';
import 'widgets/common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  await AppSettings.instance.load();
  // Sync first: it switches on Firestore offline mode, which must happen
  // before anything else touches Firestore.
  await SyncService.instance.init();
  AuthService.instance.start();
  runApp(const AntarvaniApp());
}

class AntarvaniApp extends StatelessWidget {
  const AntarvaniApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => MaterialApp(
        title: 'ANTARVANI',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: settings.themeMode,
        // A new key on language change rebuilds every screen in the new
        // language; the open page is remembered by HomeShell.lastPage.
        home: AuthGate(key: ValueKey(settings.lang)),
      ),
    );
  }
}

/// Login page until someone is signed in, then the app.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    return AnimatedBuilder(
      animation: auth,
      builder: (context, _) {
        if (!auth.ready) return const _Splash();
        if (!auth.signedIn) return const LoginScreen();
        return const HomeShell();
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(child: BrandLogo(size: 96)),
      );
}
