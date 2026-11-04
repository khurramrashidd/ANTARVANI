import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../storage.dart';
import 'auth_service.dart';
import 'drive_uploader.dart';
import 'team.dart';

/// The shared index across all four phones.
///
/// Firebase is initialised once in main.dart, before this runs. Every write
/// goes to local disk first and is mirrored to Firestore second, so a missing
/// signal never costs a recording — Firestore queues offline writes and sends
/// them when a connection appears. Only the video bytes need their own queue,
/// because Drive has no offline mode.
class SyncService extends ChangeNotifier {
  static final SyncService instance = SyncService._();
  SyncService._();

  static const _queueKey = 'upload_queue_v1';

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final DriveUploader drive = DriveUploader();

  String deviceId = '';
  String deviceName = '';

  /// Who is recording: always the signed-in person, no separate prompt.
  String get operator => Team.signedIn ? Team.displayName : '';
  bool _driveTried = false;
  Timer? _beat;

  bool _uploading = false;
  int _pendingCount = 0;
  String _status = 'idle';

  int get pendingCount => _pendingCount;
  String get status => _status;
  bool get uploading => _uploading;

  CollectionReference<Map<String, dynamic>> get clips =>
      _db.collection('clips');
  CollectionReference<Map<String, dynamic>> get speakers =>
      _db.collection('speakers');
  CollectionReference<Map<String, dynamic>> get devices =>
      _db.collection('devices');

  /// Never throws: nothing here may stop someone recording a volunteer who is
  /// already sitting in front of them.
  Future<void> init() async {
    // Must be set before any other Firestore call.
    try {
      _db.settings = const Settings(persistenceEnabled: true);
    } catch (e) {
      debugPrint('Firestore settings already applied: $e');
    }

    try {
      if (Platform.isAndroid) {
        final info = await DeviceInfoPlugin().androidInfo;
        deviceId = info.id;
        deviceName = '${info.manufacturer} ${info.model}';
      } else {
        deviceId = 'unknown';
        deviceName = 'unknown';
      }
    } catch (e) {
      deviceId = 'unknown';
      deviceName = 'unknown';
    }

    _pendingCount = (await _readQueue()).length;

    // Once we know who is signed in, and they are on the team, reconnect
    // Drive quietly (only works if they granted it before).
    AuthService.instance.addListener(_onAuthChanged);
    _onAuthChanged();

    // Any connection at all triggers a drain — Wi-Fi or mobile data.
    Connectivity().onConnectivityChanged.listen((result) {
      final online = result.any((r) => r != ConnectivityResult.none);
      if (online) drainQueue();
    });
    unawaited(drainQueue());

    notifyListeners();
  }

  void _onAuthChanged() {
    final p = AuthService.instance.profile;
    if (p == null || !p.isTeam) {
      _beat?.cancel();
      _beat = null;
    } else {
      // Presence for the team chat: "active now" means seen in 10 minutes.
      _beat ??= Timer.periodic(
          const Duration(minutes: 4), (_) => unawaited(_touchDevice()));
    }
    if (p == null) {
      if (_driveTried) {
        drive.reset();
        _driveTried = false;
        notifyListeners();
      }
      return;
    }
    if (p.isTeam && !_driveTried) {
      _driveTried = true;
      unawaited(_touchDevice());
      unawaited(drive.connect(interactive: false).then((ok) {
        notifyListeners();
        if (ok) drainQueue();
      }));
    }
  }

  /// Called from the "Connect Drive" button. May show Google's screens.
  Future<bool> connectDrive() async {
    final ok = await drive.connect(interactive: true);
    notifyListeners();
    if (ok) unawaited(drainQueue());
    return ok;
  }

  /// Edits a speaker row without touching anything the editor did not set —
  /// used by "Edit a speaker", which may be run by someone who was not the
  /// collector, on a different phone.
  Future<void> updateSpeaker(String speakerId, Map<String, dynamic> fields) =>
      speakers.doc(speakerId).set({
        ...fields,
        'editedBy': Team.email,
        'editedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

  /// Marks a speaker in_progress / complete / cancelled.
  Future<void> setSpeakerStatus(String speakerId, String status) async {
    try {
      await speakers.doc(speakerId).set({
        'status': status,
        'statusAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('speaker status failed: $e');
    }
  }

  /// Heartbeat read by the dashboard's phone list and the chat presence bar.
  Future<void> _touchDevice() async {
    if (deviceId.isEmpty) return;
    try {
      await devices.doc(deviceId).set({
        'deviceName': deviceName,
        'operator': operator,
        'pending': _pendingCount,
        'driveAccount': drive.accountEmail,
        'corpusWritable': drive.corpusWritable,
        'lastSeen': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('device heartbeat failed: $e');
    }
  }

  Future<void> saveSpeaker(SpeakerMeta meta) async {
    meta.deviceId = deviceId;
    meta.operator = operator;
    final map = meta.toMap();

    // Local disk is the record of truth and never fails for lack of a network.
    await Storage.writeSessionMeta(map);

    try {
      await speakers.doc(meta.speakerId).set(map, SetOptions(merge: true));
    } catch (e) {
      debugPrint('speaker mirror failed: $e');
    }
  }

  // ---------------------------------------------------------------- clips
  Future<void> recordClip(ClipRecord clip) async {
    final map = clip.toMap();
    // Who recorded it, so the dashboard can show per-collector totals.
    map['collectorEmail'] = Team.email;
    map['collectorName'] = operator;

    // Local manifest first — the preprocessing pipeline can read this even if
    // the phone never goes online.
    await Storage.appendManifest(map);

    unawaited(clips.doc(clip.docId).set(map).catchError((Object e) {
      debugPrint('clip mirror failed: $e');
    }));

    await _enqueue(clip);
    unawaited(drainQueue());
  }

  /// Throws a clip away. Nothing is destroyed: the Drive file moves to
  /// `_rejected`, the Firestore row stays with status `rejected` and a
  /// reason, and only the copy on this phone is deleted.
  ///
  /// Returns null on success, or a message to show the user.
  Future<String?> rejectClip(
    String docId, {
    required String reason,
    String? driveFileId,
    String? localPath,
  }) async {
    // 1. Drive, if it ever got there.
    if (driveFileId != null && driveFileId.isNotEmpty) {
      if (!drive.signedIn && !await drive.connect(interactive: false)) {
        return 'Connect Drive first, then reject this clip.';
      }
      if (!await drive.reject(driveFileId)) {
        return drive.lastError ?? 'Could not move the file in Drive.';
      }
    }

    // 2. Take it out of the upload queue if it never got there.
    final q = await _readQueue();
    final before = q.length;
    q.removeWhere((e) => e['docId'] == docId);
    if (q.length != before) await _writeQueue(q);

    // 3. The record stays; the pipeline skips anything not 'ok'.
    try {
      await clips.doc(docId).set({
        'status': 'rejected',
        'rejectedReason': reason,
        'rejectedBy': Team.email,
        'rejectedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      return 'Marked in Drive, but Firestore refused: $e';
    }

    // 4. The copy on this phone.
    if (localPath != null && localPath.isNotEmpty) {
      try {
        final f = File(localPath);
        if (f.existsSync()) await f.delete();
      } catch (_) {}
    }

    notifyListeners();
    return null;
  }

  /// Writes the Firestore row for a clip that was already in Drive before the
  /// app existed. There is no local file and nothing to upload.
  Future<void> registerImportedClip(Map<String, dynamic> map) =>
      clips.doc(map['docId'] as String).set(map, SetOptions(merge: true));

  // ------------------------------------------------------------ the queue
  Future<List<Map<String, dynamic>>> _readQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_queueKey) ?? [];
    return raw
        .map((s) => jsonDecode(s) as Map<String, dynamic>)
        .toList(growable: true);
  }

  Future<void> _writeQueue(List<Map<String, dynamic>> q) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_queueKey, q.map(jsonEncode).toList());
    _pendingCount = q.length;
    notifyListeners();
  }

  Future<void> _enqueue(ClipRecord clip) async {
    final q = await _readQueue();
    q.add(clip.toQueueJson());
    await _writeQueue(q);
    unawaited(_touchDevice());
  }

  /// Uploads everything queued, oldest first. Safe to call repeatedly — it
  /// returns immediately if a drain is already running.
  Future<void> drainQueue() async {
    if (_uploading) return;
    if (!drive.signedIn) {
      _status = 'not signed in';
      notifyListeners();
      return;
    }
    final conn = await Connectivity().checkConnectivity();
    if (conn.every((r) => r == ConnectivityResult.none)) {
      _status = 'offline';
      notifyListeners();
      return;
    }

    _uploading = true;
    _status = 'uploading';
    notifyListeners();

    try {
      var q = await _readQueue();
      while (q.isNotEmpty) {
        final item = q.first;
        final file = File(item['localPath'] as String);

        if (!file.existsSync()) {
          // Nothing to upload — drop it rather than block the queue forever.
          q.removeAt(0);
          await _writeQueue(q);
          continue;
        }

        final id = await drive.upload(
          file: file,
          fileName: item['fileName'] as String,
          speakerId: item['speakerId'] as String,
        );

        if (id == null) {
          _status = drive.lastError ?? 'upload failed, will retry';
          break; // stays queued; the next connectivity event retries
        }

        unawaited(clips.doc(item['docId'] as String).set({
          'uploaded': true,
          'driveFileId': id,
          'uploadedUtc': DateTime.now().toUtc().toIso8601String(),
        }, SetOptions(merge: true)).catchError((Object _) {}));

        q.removeAt(0);
        await _writeQueue(q);
        _status = '${q.length} left';
        notifyListeners();
      }
      if (q.isEmpty) _status = 'all uploaded';
    } finally {
      _uploading = false;
      unawaited(_touchDevice());
      notifyListeners();
    }
  }

  /// Local files are kept until confirmed in Drive. This clears the ones that
  /// are safely uploaded, freeing space mid-collection.
  Future<int> purgeUploadedLocalFiles(Directory dataDir) async {
    final q = await _readQueue();
    final queued = q.map((e) => e['localPath'] as String).toSet();
    var freed = 0;
    if (!dataDir.existsSync()) return 0;
    for (final f in dataDir.listSync(recursive: true)) {
      if (f is File && f.path.endsWith('.mp4') && !queued.contains(f.path)) {
        freed += f.lengthSync();
        await f.delete();
      }
    }
    return freed;
  }
}
