import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/settings.dart';
import 'app/theme.dart';
import 'firebase_options.dart';
import 'phrases.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'screens/update_gate_screen.dart';
import 'services/auth_service.dart';
import 'services/background_upload.dart';
import 'services/language_service.dart';
import 'services/model_service.dart';
import 'services/release_service.dart';
import 'services/sync_service.dart';
import 'widgets/common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  // The lip crop assumes the phone is upright, as it was during recording.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await AppSettings.instance.load();
  await LanguageService.instance.load();
  // Sync first: it switches on Firestore offline mode, which must happen
  // before anything else touches Firestore.
  await SyncService.instance.init();
  // Clips keep uploading after the app is closed; the app and the service
  // hand the queue back and forth so they never upload the same clip twice.
  await BackgroundUpload.configure();
  BackgroundUploadWatcher.instance.start();
  AuthService.instance.start();
  unawaited(ReleaseService.instance.start());
  // A different phrase language means a different model.
  LanguageService.instance
      .addListener(() => unawaited(ModelService.instance.sync()));
  runApp(const AntarvaniApp());
}

class AntarvaniApp extends StatelessWidget {
  const AntarvaniApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([settings, LanguageService.instance]),
      builder: (context, _) => MaterialApp(
        title: 'ANTARVANI',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: settings.themeMode,
        // A new key on language change rebuilds every screen in the new
        // language; the open page is remembered by HomeShell.lastPage.
        // The same goes for the phrase language.
        home: AuthGate(key: ValueKey('${settings.lang}/${PhraseBook.code}')),
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
    final release = ReleaseService.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([auth, release]),
      builder: (context, _) {
        if (!auth.ready) return const _Splash();
        if (!auth.signedIn) return const LoginScreen();
        // Everyone stays on the same build: an older one cannot be used.
        if (release.updateRequired) return const UpdateGateScreen();
        // Both need a signed-in reader, and both are safe to call again.
        LanguageService.instance.watch();
        unawaited(ModelService.instance.start());
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
