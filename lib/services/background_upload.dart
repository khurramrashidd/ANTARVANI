import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../firebase_options.dart';
import 'drive_uploader.dart';
import 'language_service.dart';

/// Uploading that carries on after the app is closed.
///
/// Android kills an ordinary app the moment it leaves the screen, so clips
/// used to sit on the phone until somebody opened ANTARVANI again — which is
/// how 94 clips went missing from the corpus without anyone noticing. The
/// only way to keep working after that point is a foreground service: a real
/// Android service with a notification the person can see. The notification
/// is not decoration, it is the price of being allowed to run.
///
/// The service shares one thing with the app: the upload queue in
/// SharedPreferences. It never runs at the same time as the app's own
/// uploader — the app stops the service when it comes to the front and
/// starts it again when it leaves.
class BackgroundUpload {
  BackgroundUpload._();

  static const _channelId = 'antarvani_upload';
  static const _notificationId = 8921;

  /// Same key SyncService uses. One queue, two readers, never at once.
  static const _queueKey = 'upload_queue_v1';

  static const _kEnabled = 'bg_upload_enabled';
  static const _kMobile = 'bg_upload_mobile_data';
  static const _kLastError = 'bg_upload_last_error';
  static const _kLastRun = 'bg_upload_last_run';
  static const _kUploaded = 'bg_upload_count';

  static bool _configured = false;

  // ------------------------------------------------------------ settings
  static Future<bool> enabled() async =>
      (await SharedPreferences.getInstance()).getBool(_kEnabled) ?? true;

  static Future<void> setEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, v);
    if (!v) await stop();
  }

  /// Clips are about 3 MB each. The team asked for mobile data as well as
  /// WiFi, so this starts on; it is here so one person on a small plan can
  /// turn it off without turning the whole feature off.
  static Future<bool> mobileDataAllowed() async =>
      (await SharedPreferences.getInstance()).getBool(_kMobile) ?? true;

  static Future<void> setMobileDataAllowed(bool v) async =>
      (await SharedPreferences.getInstance()).setBool(_kMobile, v);

  /// What the service said last time it stopped. Empty when all went well.
  static Future<String> lastError() async =>
      (await SharedPreferences.getInstance()).getString(_kLastError) ?? '';

  static Future<DateTime?> lastRun() async {
    final s = (await SharedPreferences.getInstance()).getString(_kLastRun);
    return s == null ? null : DateTime.tryParse(s)?.toLocal();
  }

  /// How many clips the service has sent since it was installed.
  static Future<int> uploadedInBackground() async =>
      (await SharedPreferences.getInstance()).getInt(_kUploaded) ?? 0;

  // --------------------------------------------------------- permissions
  /// Android 13 and later will not show the service notification without
  /// this, and a service with no notification is not allowed to run.
  static Future<bool> hasNotificationPermission() async =>
      !Platform.isAndroid || await Permission.notification.isGranted;

  static Future<bool> askNotificationPermission() async =>
      (await Permission.notification.request()).isGranted;

  /// Battery optimisation is what actually kills uploads on Realme, Redmi,
  /// Oppo and Vivo. Without this exemption the service is stopped within
  /// minutes of the screen going off.
  static Future<bool> batteryExempt() async {
    if (!Platform.isAndroid) return true;
    try {
      return await Permission.ignoreBatteryOptimizations.isGranted;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> askBatteryExempt() async {
    try {
      return (await Permission.ignoreBatteryOptimizations.request()).isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Autostart (MIUI, ColorOS, Funtouch) cannot be switched on by any app —
  /// it has to be done by hand. All we can do is open the app's settings
  /// page and say what to look for.
  static Future<void> openPhoneSettings() => openAppSettings();

  // ------------------------------------------------------------ lifecycle
  /// Called once from main(), before the first screen.
  static Future<void> configure() async {
    if (_configured || !Platform.isAndroid) return;
    _configured = true;
    try {
      await FlutterBackgroundService().configure(
        androidConfiguration: AndroidConfiguration(
          onStart: backgroundEntry,
          autoStart: false,
          isForegroundMode: true,
          notificationChannelId: _channelId,
          initialNotificationTitle: 'ANTARVANI',
          initialNotificationContent: 'Preparing to upload…',
          foregroundServiceNotificationId: _notificationId,
        ),
        iosConfiguration: IosConfiguration(autoStart: false),
      );
    } catch (e) {
      debugPrint('background service could not be configured: $e');
    }
  }

  static Future<bool> isRunning() async {
    if (!Platform.isAndroid) return false;
    try {
      return await FlutterBackgroundService().isRunning();
    } catch (_) {
      return false;
    }
  }

  /// Hands the queue over to the service. Called when the app leaves the
  /// screen — there is no point running it while the app is in front, where
  /// SyncService does the same work with a progress bar.
  static Future<void> handOver() async {
    if (!Platform.isAndroid) return;
    if (!await enabled()) return;
    if (!await hasNotificationPermission()) return;
    final p = await SharedPreferences.getInstance();
    await p.reload();
    if ((p.getStringList(_queueKey) ?? const []).isEmpty) return;
    if (await isRunning()) return;
    try {
      await FlutterBackgroundService().startService();
    } catch (e) {
      debugPrint('could not start the upload service: $e');
    }
  }

  /// Called when the app comes back to the front, so the two never upload
  /// the same clip at the same moment.
  static Future<void> takeBack() async {
    if (!Platform.isAndroid) return;
    await stop();
  }

  static Future<void> stop() async {
    try {
      if (await isRunning()) {
        FlutterBackgroundService().invoke('stop');
      }
    } catch (e) {
      debugPrint('could not stop the upload service: $e');
    }
  }
}

/// Watches the app going to and from the screen.
class BackgroundUploadWatcher with WidgetsBindingObserver {
  static final BackgroundUploadWatcher instance = BackgroundUploadWatcher._();
  BackgroundUploadWatcher._();

  void start() => WidgetsBinding.instance.addObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(BackgroundUpload.handOver());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(BackgroundUpload.takeBack());
    }
  }
}

// ======================================================================
//  Everything below runs in the service, in its own isolate
// ======================================================================
/// The service's entry point. It is a separate isolate with nothing from the
/// app in it: no Firebase, no sign-in, no settings. All of that is set up
/// again here from scratch.
@pragma('vm:entry-point')
Future<void> backgroundEntry(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  var stopping = false;
  service.on('stop').listen((_) {
    stopping = true;
  });

  final prefs = await SharedPreferences.getInstance();
  Future<void> note(String key, Object value) async {
    if (value is String) {
      await prefs.setString(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    }
  }

  await note(BackgroundUpload._kLastRun,
      DateTime.now().toUtc().toIso8601String());
  await note(BackgroundUpload._kLastError, '');

  Future<void> show(String title, String text) async {
    if (service is AndroidServiceInstance) {
      await service.setForegroundNotificationInfo(
          title: title, content: text);
    }
    service.invoke('progress', {'title': title, 'text': text});
  }

  Future<void> quit(String why) async {
    if (why.isNotEmpty) await note(BackgroundUpload._kLastError, why);
    service.invoke('finished', {'error': why});
    await service.stopSelf();
  }

  try {
    await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform);
  } catch (e) {
    // Already there, or genuinely broken. Uploading does not need Firestore,
    // so carry on and let the writes fail quietly if it was the second.
    debugPrint('background Firebase: $e');
  }

  // Which phrase language this phone is recording decides the Drive folder
  // the clips belong in. The isolate starts blank, so it has to be read back
  // or a Marathi session would be filed under Hindi.
  try {
    await LanguageService.instance.load();
  } catch (e) {
    debugPrint('background language: $e');
  }

  final db = FirebaseFirestore.instance;
  final drive = DriveUploader();

  // Sign in without a screen. This only works because the person already
  // granted Drive access in the app; it refreshes the token, it does not ask
  // for anything new.
  await show('ANTARVANI', 'Connecting to Drive…');
  if (!await drive.connect(interactive: false)) {
    await quit(drive.lastError ??
        'Drive could not be reached without opening the app.');
    return;
  }

  var sent = 0;
  while (!stopping) {
    await prefs.reload();
    final raw = prefs.getStringList(BackgroundUpload._queueKey) ?? const [];
    if (raw.isEmpty) {
      await show('ANTARVANI', 'Everything uploaded');
      await note(BackgroundUpload._kUploaded,
          (prefs.getInt(BackgroundUpload._kUploaded) ?? 0) + sent);
      await quit('');
      return;
    }

    final conn = await Connectivity().checkConnectivity();
    final offline = conn.every((r) => r == ConnectivityResult.none);
    final mobileOnly = !offline &&
        !conn.contains(ConnectivityResult.wifi) &&
        !conn.contains(ConnectivityResult.ethernet);
    if (offline) {
      await show('ANTARVANI', '${raw.length} clips waiting — no connection');
      await Future<void>.delayed(const Duration(seconds: 30));
      continue;
    }
    if (mobileOnly && !(prefs.getBool(BackgroundUpload._kMobile) ?? true)) {
      await show('ANTARVANI', '${raw.length} clips waiting for WiFi');
      await Future<void>.delayed(const Duration(seconds: 60));
      continue;
    }

    final item = jsonDecode(raw.first) as Map<String, dynamic>;
    final file = File('${item['localPath']}');
    if (!file.existsSync()) {
      await _dropFromQueue(prefs, '${item['docId']}');
      continue;
    }

    await show('Uploading clips', '${raw.length} left · ${item['fileName']}');
    String? id;
    try {
      id = await drive.upload(
        file: file,
        fileName: '${item['fileName']}',
        speakerId: '${item['speakerId']}',
      );
    } catch (e) {
      id = null;
      drive.lastError = '$e';
    }

    if (id == null) {
      // Leave it queued; a later run or the app itself will try again.
      await note(BackgroundUpload._kUploaded,
          (prefs.getInt(BackgroundUpload._kUploaded) ?? 0) + sent);
      await quit(drive.lastError ?? 'Upload failed.');
      return;
    }

    try {
      await db.collection('clips').doc('${item['docId']}').set({
        'uploaded': true,
        'driveFileId': id,
        'uploadedUtc': DateTime.now().toUtc().toIso8601String(),
      }, SetOptions(merge: true));
    } catch (e) {
      // The file is in Drive, which is what matters. Firestore will catch up
      // when the app next opens.
      debugPrint('background Firestore mark: $e');
    }

    sent++;
    await _dropFromQueue(prefs, '${item['docId']}');
  }

  await note(BackgroundUpload._kUploaded,
      (prefs.getInt(BackgroundUpload._kUploaded) ?? 0) + sent);
  await quit('');
}

/// Takes one clip out of the queue by name.
///
/// The app may be working on the same list — it re-reads first, and removes
/// the entry it actually uploaded rather than whatever happens to be at the
/// front, so neither side can drop a clip the other still owes.
Future<void> _dropFromQueue(SharedPreferences prefs, String docId) async {
  await prefs.reload();
  final raw = prefs.getStringList(BackgroundUpload._queueKey) ?? const [];
  final kept = <String>[];
  for (final row in raw) {
    try {
      if ((jsonDecode(row) as Map<String, dynamic>)['docId'] == docId) continue;
    } catch (_) {
      // Unreadable row: keep it, the app will deal with it.
    }
    kept.add(row);
  }
  if (kept.length != raw.length) {
    await prefs.setStringList(BackgroundUpload._queueKey, kept);
  }
}
