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
import 'id_allocator.dart';
import 'team.dart';

/// Just enough about a clip to delete it.
class ClipRef {
  final String docId;
  final String? driveFileId;

  /// Whoever recorded it — and therefore owns the file in Drive.
  final String? ownerEmail;

  const ClipRef({required this.docId, this.driveFileId, this.ownerEmail});
}

/// What a whole-recording deletion managed to do.
class DeleteReport {
  final bool ok;
  final String? error;
  final int deleted;
  final int trashed;
  final int stranded;
  final List<String> pendingOwners;

  const DeleteReport({
    required this.ok,
    this.error,
    this.deleted = 0,
    this.trashed = 0,
    this.stranded = 0,
    this.pendingOwners = const [],
  });

  const DeleteReport.blocked(String message)
      : ok = false,
        error = message,
        deleted = 0,
        trashed = 0,
        stranded = 0,
        pendingOwners = const [];

  /// One sentence for the person who pressed the button.
  String get message {
    if (!ok) return error ?? 'Nothing was deleted.';
    final parts = <String>[];
    if (deleted > 0) parts.add('$deleted deleted');
    if (trashed > 0) parts.add("$trashed sent to the owner's bin");
    if (stranded > 0) {
      parts.add('$stranded could only be moved out of the corpus');
    }
    final who = pendingOwners.isEmpty ? '' : ' Ask ${pendingOwners.join(", ")} '
        'to open the app and finish deleting those.';
    return 'Records cleared and the number is back in the pool. '
        '${parts.isEmpty ? "No files to remove." : "${parts.join(", ")}."}$who';
  }
}

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

  /// Wipes a whole recording and hands its number back.
  ///
  /// Drive only lets the account that uploaded a file destroy it, so clips
  /// recorded on someone else's phone cannot always be removed from here.
  /// Those are taken out of the corpus and renamed instead, and the result
  /// says plainly who still has to finish the job. Either way the records go
  /// and the number is reusable.
  Future<DeleteReport> deleteSpeakerCompletely({
    required String speakerId,
    required String formNo,
    required List<ClipRef> clips,
    required String reason,
  }) async {
    final withFiles = clips.where((c) => c.driveFileId != null).toList();
    var deleted = 0;
    var trashed = 0;
    final stranded = <ClipRef>[];

    if (withFiles.isNotEmpty) {
      if (!drive.signedIn && !await drive.connect(interactive: false)) {
        return DeleteReport.blocked(
            'Connect Drive first — the videos have to go before the number '
            'can be reused.');
      }
      for (final c in withFiles) {
        switch (await drive.deleteForever(c.driveFileId!)) {
          case DriveDeleteOutcome.deleted:
            deleted++;
          case DriveDeleteOutcome.trashed:
            trashed++;
          case DriveDeleteOutcome.movedAside:
            stranded.add(c);
          case DriveDeleteOutcome.failed:
            return DeleteReport.blocked(drive.lastError ??
                'Could not remove every video from Drive. Nothing was '
                    'changed; try again.');
        }
      }
    }

    final owners = stranded
        .map((c) => c.ownerEmail)
        .whereType<String>()
        .toSet()
        .toList();

    try {
      await _db.collection('deletions').add({
        'speakerId': speakerId,
        'consentFormId': formNo,
        'clips': clips.length,
        'filesDeleted': deleted,
        'filesTrashed': trashed,
        'filesStranded': stranded.length,
        // Who still has to open the app and finish the job.
        'pendingOwners': owners,
        'pendingFileIds':
            stranded.map((c) => c.driveFileId).whereType<String>().toList(),
        'reason': reason,
        'deletedBy': Team.email,
        'deletedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('tombstone failed: $e');
    }

    try {
      // Firestore batches take 500 writes; a speaker holds at most 200 clips.
      final batch = _db.batch();
      for (final c in clips) {
        batch.delete(this.clips.doc(c.docId));
      }
      await batch.commit();
      await IdAllocator.release([speakerId]);
    } catch (e) {
      return DeleteReport.blocked(
          'The videos were handled, but clearing the records failed: $e');
    }

    try {
      final dir = await Storage.dataDir();
      final folder = Directory('${dir.path}/$speakerId');
      if (folder.existsSync()) await folder.delete(recursive: true);
    } catch (_) {}

    notifyListeners();
    return DeleteReport(
      ok: true,
      deleted: deleted,
      trashed: trashed,
      stranded: stranded.length,
      pendingOwners: owners,
    );
  }

  /// Destroys files an earlier deletion could not touch, now that the person
  /// who uploaded them is the one signed in.
  Future<int> deleteStrandedFiles(List<String> fileIds) async {
    if (!drive.signedIn && !await drive.connect(interactive: false)) return 0;
    var gone = 0;
    for (final id in fileIds) {
      final r = await drive.deleteForever(id);
      if (r == DriveDeleteOutcome.deleted || r == DriveDeleteOutcome.trashed) {
        gone++;
      }
    }
    return gone;
  }

  /// Writes the Firestore row for a clip that was already in Drive before the
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
