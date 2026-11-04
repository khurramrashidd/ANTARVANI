import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'team.dart';

/// Keeps every phone on the same build.
///
/// The master admin publishes one row — `config/release` — naming the build
/// number of the APK they uploaded and where to get it. Any phone running an
/// older build is locked until it updates, so the team never ends up
/// comparing results from two different versions of the recorder.
///
/// The row is read through Firestore's offline cache, so a phone that was
/// told to update and then went offline stays told.
class ReleaseService extends ChangeNotifier {
  static final ReleaseService instance = ReleaseService._();
  ReleaseService._();

  static DocumentReference<Map<String, dynamic>> get _doc =>
      FirebaseFirestore.instance.collection('config').doc('release');

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;

  /// This phone, from pubspec.yaml's `version:` line.
  int localBuild = 0;
  String localVersion = '';

  int requiredBuild = 0;
  String requiredVersion = '';
  String url = '';
  String notes = '';
  String publishedBy = '';

  bool _ready = false;

  /// False until we know both numbers. Nothing is blocked before then.
  bool get ready => _ready;

  bool get updateRequired =>
      _ready && requiredBuild > 0 && localBuild > 0 && requiredBuild > localBuild;

  Future<void> start() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      localVersion = pkg.version;
      localBuild = int.tryParse(pkg.buildNumber) ?? 0;
    } catch (e) {
      debugPrint('package info failed: $e');
    }
    _sub ??= _doc.snapshots().listen((d) {
      final m = d.data();
      requiredBuild = (m?['build'] as num?)?.toInt() ?? 0;
      requiredVersion = m?['versionName'] as String? ?? '';
      url = m?['url'] as String? ?? '';
      notes = m?['notes'] as String? ?? '';
      publishedBy = m?['publishedBy'] as String? ?? '';
      _ready = true;
      notifyListeners();
    }, onError: (Object e) {
      // Rules refused, or no connection yet. Never block on a guess.
      debugPrint('release watch failed: $e');
      _ready = true;
      notifyListeners();
    });
    // If Firestore never answers (first run, no signal) stop waiting so the
    // app opens normally.
    Future<void>.delayed(const Duration(seconds: 6), () {
      if (!_ready) {
        _ready = true;
        notifyListeners();
      }
    });
  }

  /// Master admin only — the rules enforce it too.
  Future<void> publish({
    required int build,
    required String versionName,
    required String url,
    required String notes,
  }) =>
      _doc.set({
        'build': build,
        'versionName': versionName.trim(),
        'url': url.trim(),
        'notes': notes.trim(),
        'publishedBy': Team.email,
        'publishedAt': FieldValue.serverTimestamp(),
      });

  /// Undo a wrong number. Without this, publishing build 99 by mistake would
  /// lock everyone out — including the person who has to fix it.
  Future<void> clear() => _doc.set({
        'build': 0,
        'url': '',
        'notes': '',
        'versionName': '',
        'publishedBy': Team.email,
        'publishedAt': FieldValue.serverTimestamp(),
      });
}
