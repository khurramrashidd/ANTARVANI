import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../phrases.dart';
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

/// One clip, enough of it to move the file and fix its record afterwards.
class MoveRef {
  final String docId;
  final String driveFileId;
  final String phraseId;

  /// The account that uploaded it. Drive lets that account move the file and
  /// refuses everyone else, so this is who has to finish the job.
  final String? ownerEmail;

  const MoveRef({
    required this.docId,
    required this.driveFileId,
    required this.phraseId,
    this.ownerEmail,
  });
}

/// Which part of the corpus a clip should sit in.
enum CorpusZone {
  /// P01..P20 — what the training pipeline reads.
  corpus,

  /// _in_progress/<speaker> — recorded, but the session is not finished.
  holding,

  /// _rejected — thrown out, kept for the QC numbers in the paper.
  rejected,
}

/// What a batch of file moves managed to do.
class MoveReport {
  final int moved;
  final int notAllowed;
  final int notFound;
  final int failed;

  /// Accounts that have to open the app and move their own clips.
  final List<String> blockedOwners;
  final String? error;

  const MoveReport({
    this.moved = 0,
    this.notAllowed = 0,
    this.notFound = 0,
    this.failed = 0,
    this.blockedOwners = const [],
    this.error,
  });

  const MoveReport.blocked(String why) : this(error: why);

  bool get ok => error == null && failed == 0 && notAllowed == 0;
  int get total => moved + notAllowed + notFound + failed;

  /// One line a person can act on.
  String get summary {
    if (error != null) return error!;
    if (total == 0) return 'Nothing to move.';
    final parts = <String>['$moved moved'];
    if (notAllowed > 0) {
      parts.add('$notAllowed belong to '
          '${blockedOwners.isEmpty ? "another account" : blockedOwners.join(", ")} '
          'and must be moved from their phone');
    }
    if (notFound > 0) parts.add('$notFound are no longer in Drive');
    if (failed > 0) parts.add('$failed failed');
    return parts.join('; ');
  }
}

/// What a whole-recording deletion managed to do.
/// What a rescan of this phone found.
class RescanReport {
  final int filesOnDisk;
  final int requeued;
  final int alreadyQueued;
  final int missing;
  final List<String> missingDocIds;
  final int orphanFiles;
  final String? error;

  const RescanReport({
    this.filesOnDisk = 0,
    this.requeued = 0,
    this.alreadyQueued = 0,
    this.missing = 0,
    this.missingDocIds = const [],
    this.orphanFiles = 0,
    this.error,
  });

  bool get nothingHere => filesOnDisk == 0 && missing > 0;
}

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
    _completeCache.remove(speakerId);
    try {
      await speakers.doc(speakerId).set({
        'status': status,
        'statusAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('speaker status failed: $e');
    }
  }

  /// Takes a whole session out of the corpus without destroying it.
  ///
  /// Two different things were being conflated before: a session that is no
  /// good, and a number that should go back into the pool. A rejected session
  /// keeps its row and its number — the clips stay where they are, the
  /// volunteer can re-record, and master can put it back with
  /// [restoreSpeaker]. Counting it out of every total is enough to make the
  /// numbers honest; nothing has to be deleted to achieve that.
  ///
  /// To get the number back as well, use [deleteSpeakerCompletely], which
  /// removes the clips first so none are orphaned.
  Future<void> rejectSpeaker(String speakerId, String why) async {
    _completeCache.remove(speakerId);
    await speakers.doc(speakerId).set({
      'status': 'rejected',
      'rejectedReason': why,
      'rejectedBy': Team.email,
      'rejectedAt': FieldValue.serverTimestamp(),
      'statusAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Puts a rejected session back, for when the volunteer has re-recorded.
  ///
  /// The status returned is worked out from what is actually there now, not
  /// from what it was before it was rejected: a session that is short of its
  /// target comes back as in_progress so it shows up under "Unfinished"
  /// instead of quietly counting as done.
  Future<void> restoreSpeaker(String speakerId,
      {required bool complete}) async {
    _completeCache.remove(speakerId);
    await speakers.doc(speakerId).set({
      'status': complete ? 'complete' : 'in_progress',
      'rejectedReason': FieldValue.delete(),
      'rejectedBy': FieldValue.delete(),
      'rejectedAt': FieldValue.delete(),
      'restoredBy': Team.email,
      'restoredAt': FieldValue.serverTimestamp(),
      'statusAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // ------------------------------------------------------------------
  //  Moving clips between the parts of the corpus
  // ------------------------------------------------------------------
  /// Moves one speaker's files into [zone] and fixes their records.
  ///
  /// Drive only lets the account that uploaded a file move it. That is not
  /// an error to hide: the clips that could not be moved are counted and
  /// their owners named, so the right person can be asked. Everything that
  /// could move, moves — one refusal never stops the rest.
  Future<MoveReport> moveSpeakerClips({
    required String speakerId,
    required CorpusZone zone,
    required List<MoveRef> clips,
  }) async {
    if (clips.isEmpty) return const MoveReport();
    if (!drive.signedIn && !await drive.connect(interactive: false)) {
      return const MoveReport.blocked(
          'Connect Drive first — the files have to move before this takes '
          'effect.');
    }

    var moved = 0, notAllowed = 0, notFound = 0, failed = 0;
    final blocked = <String>{};
    final done = <String>[];

    for (final c in clips) {
      final outcome = switch (zone) {
        CorpusZone.corpus =>
          await drive.moveIntoCorpus(c.driveFileId, c.phraseId),
        CorpusZone.holding =>
          await drive.moveIntoHolding(c.driveFileId, speakerId),
        CorpusZone.rejected =>
          await drive.reject(c.driveFileId) ? DriveMoveOutcome.moved : DriveMoveOutcome.failed,
      };
      switch (outcome) {
        case DriveMoveOutcome.moved:
          moved++;
          done.add(c.docId);
        case DriveMoveOutcome.notAllowed:
          notAllowed++;
          if (c.ownerEmail != null && c.ownerEmail!.isNotEmpty) {
            blocked.add(c.ownerEmail!);
          }
        case DriveMoveOutcome.notFound:
          notFound++;
        case DriveMoveOutcome.failed:
          failed++;
      }
    }

    // One flag per clip, so the dashboard knows what is still in the holding
    // folder without listing Drive every time it draws.
    if (done.isNotEmpty) {
      try {
        final batch = _db.batch();
        for (final id in done) {
          batch.set(this.clips.doc(id), {
            'inCorpus': zone == CorpusZone.corpus,
            'movedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
        await batch.commit();
      } catch (e) {
        debugPrint('move bookkeeping failed: $e');
      }
    }

    notifyListeners();
    return MoveReport(
      moved: moved,
      notAllowed: notAllowed,
      notFound: notFound,
      failed: failed,
      blockedOwners: blocked.toList()..sort(),
    );
  }

  /// Writes the rejected-speaker list the notebook reads, from whatever is
  /// rejected right now. Called after every reject and every restore, so the
  /// file on Drive is never a guess about what the dashboard shows.
  Future<bool> publishSkipList() async {
    try {
      final snap = await speakers.where('status', isEqualTo: 'rejected').get();
      if (!drive.signedIn && !await drive.connect(interactive: false)) {
        return false;
      }
      return await drive.writeSkipList(snap.docs.map((d) => d.id));
    } catch (e) {
      debugPrint('skip list failed: $e');
      return false;
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
    // Which phrase list this session was recorded against.
    map['lang'] = PhraseBook.code;

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
    map['lang'] = PhraseBook.code;

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
        return const DeleteReport.blocked(
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
      // The number goes back into the pool, so it may belong to somebody
      // else tomorrow. A leftover line in the skip list would quietly keep
      // that new volunteer out of training.
      unawaited(publishSkipList());
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

  /// Gives one volunteer read access to their own clips, so a Play button
  /// works on their phone. Returns how many were shared.
  Future<int> shareClipsWith({
    required String speakerId,
    required String email,
    required List<String> driveFileIds,
  }) async {
    if (!drive.signedIn && !await drive.connect(interactive: false)) return 0;
    var shared = 0;
    for (final id in driveFileIds) {
      if (await drive.shareWith(id, email)) shared++;
    }
    if (shared > 0) {
      try {
        await speakers.doc(speakerId).set({
          'sharedWith': FieldValue.arrayUnion([email]),
          'sharedAt': FieldValue.serverTimestamp(),
          'sharedBy': Team.email,
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint('share note failed: $e');
      }
    }
    return shared;
  }

  /// Releases a session that is linked to the wrong account — usually a
  /// collector who opened it while testing. The volunteer can then link it.
  Future<void> unlinkVolunteer(String speakerId) =>
      speakers.doc(speakerId).set({
        'claimedBy': FieldValue.delete(),
        'claimedAt': FieldValue.delete(),
        'claimProof': FieldValue.delete(),
        'codeProof': FieldValue.delete(),
        'unlinkedBy': Team.email,
        'unlinkedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

  /// Fills in an access code for a session recorded before codes existed.
  Future<String> giveAccessCode(String speakerId) async {
    final code = IdAllocator.newCode();
    await speakers.doc(speakerId).set({
      'accessCode': code,
      'accessCodeAddedBy': Team.email,
      'accessCodeAddedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    return code;
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
      clips.doc(map['docId'] as String).set(
          {...map, 'lang': PhraseBook.code}, SetOptions(merge: true));

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

  /// Takes one clip out of the queue by name, not by position.
  ///
  /// The background service works on this same list, so a clip may have been
  /// removed by the other side between the read and the write. Removing the
  /// first entry blindly would then drop somebody else's clip from the queue
  /// without uploading it.
  Future<void> _removeFromQueue(String docId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final q = await _readQueue();
    q.removeWhere((e) => e['docId'] == docId);
    await _writeQueue(q);
  }

  Future<void> _enqueue(ClipRecord clip) async {
    final q = await _readQueue();
    q.add(clip.toQueueJson());
    await _writeQueue(q);
    unawaited(_touchDevice());
  }

  /// Rebuilds the upload queue from what is actually on this phone.
  ///
  /// Three things have to agree: the files on disk, the rows in Firestore,
  /// and the queue in the phone's settings. They can drift apart — most
  /// easily by reinstalling the app, which wipes the files and the queue but
  /// leaves the rows, so the dashboard says clips are waiting while the
  /// phone has nothing to send and the upload button does nothing.
  ///
  /// So nothing here trusts the queue. It walks the disk, reads this
  /// person's unuploaded rows, and rebuilds the queue from the files that
  /// are really there. Rows whose file has gone are reported, not deleted:
  /// that is a decision for a person, not for a repair routine.
  Future<RescanReport> rescanLocalClips() async {
    try {
      final dir = await Storage.dataDir();
      final onDisk = <String, File>{};
      if (dir.existsSync()) {
        for (final e in dir.listSync(recursive: true)) {
          if (e is File && e.path.toLowerCase().endsWith('.mp4')) {
            onDisk[e.uri.pathSegments.last] = e;
          }
        }
      }

      final me = Team.email ?? '';
      if (me.isEmpty) {
        return RescanReport(
            filesOnDisk: onDisk.length, error: 'Not signed in.');
      }

      final q = await _readQueue();
      final queued = {for (final e in q) e['docId'] as String};

      final snap = await clips.where('collectorEmail', isEqualTo: me).get();
      var requeued = 0, already = 0, missing = 0;
      final missingIds = <String>[];
      final matched = <String>{};

      for (final d in snap.docs) {
        final m = d.data();
        if (m['uploaded'] == true) continue;
        if ((m['status'] as String? ?? 'ok') != 'ok') continue;
        final name = m['fileName'] as String? ?? '';
        final f = onDisk[name];
        if (f == null) {
          missing++;
          missingIds.add(d.id);
          continue;
        }
        matched.add(name);
        if (queued.contains(d.id)) {
          already++;
          continue;
        }
        q.add({
          'docId': d.id,
          'localPath': f.path,
          'fileName': name,
          'speakerId': '${m['speakerId'] ?? ''}',
        });
        requeued++;
      }

      if (requeued > 0) await _writeQueue(q);
      return RescanReport(
        filesOnDisk: onDisk.length,
        requeued: requeued,
        alreadyQueued: already,
        missing: missing,
        missingDocIds: missingIds,
        orphanFiles: onDisk.length - matched.length,
      );
    } catch (e) {
      debugPrint('rescan failed: $e');
      return RescanReport(error: '$e');
    }
  }

  /// Marks clips whose file no longer exists, so they stop being counted as
  /// waiting for ever. The rows are kept, with a reason, rather than deleted.
  Future<int> markLost(List<String> docIds, String why) async {
    var n = 0;
    for (final id in docIds) {
      try {
        await clips.doc(id).set({
          'status': 'lost',
          'lostReason': why,
          'lostBy': Team.email,
          'lostAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        n++;
      } catch (e) {
        debugPrint('markLost $id: $e');
      }
    }
    return n;
  }

  /// What the Upload now button does: repair first, then send, then say what
  /// happened. A button that silently does nothing is worse than an error.
  Future<String> uploadNow() async {
    final r = await rescanLocalClips();
    if (r.error != null) return 'Could not check this phone: ${r.error}';
    if (r.requeued > 0) {
      _status = '${r.requeued} found, uploading';
      notifyListeners();
    }
    await drainQueue();
    final left = _pendingCount;
    if (left == 0 && r.missing == 0) {
      return r.filesOnDisk == 0
          ? 'Nothing on this phone to upload.'
          : 'Everything on this phone is already in Drive.';
    }
    if (left == 0 && r.missing > 0) {
      return '${r.missing} clip(s) are listed as waiting but their files are '
          'not on this phone. Tap Rescan for what to do.';
    }
    return '$left clip(s) left — keep this screen open.';
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
    // A session can have been finished since the last drain, which changes
    // where its clips belong.
    _completeCache.clear();
    notifyListeners();

    try {
      var q = await _readQueue();
      while (q.isNotEmpty) {
        final item = q.first;
        final file = File(item['localPath'] as String);

        if (!file.existsSync()) {
          // Nothing to upload — drop it rather than block the queue forever.
          await _removeFromQueue(item['docId'] as String);
          q = await _readQueue();
          continue;
        }

        final speakerId = item['speakerId'] as String;
        final id = await drive.upload(
          file: file,
          fileName: item['fileName'] as String,
          speakerId: speakerId,
          speakerComplete: await _speakerIsComplete(speakerId),
        );

        if (id == null) {
          _status = drive.lastError ?? 'upload failed, will retry';
          break; // stays queued; the next connectivity event retries
        }

        unawaited(clips.doc(item['docId'] as String).set({
          'uploaded': true,
          'driveFileId': id,
          // Where it actually landed, so the dashboard can tell what is
          // still waiting in the holding folder without listing Drive.
          'inCorpus': _completeCache[speakerId] ?? false,
          'uploadedUtc': DateTime.now().toUtc().toIso8601String(),
        }, SetOptions(merge: true)).catchError((Object _) {}));

        await _removeFromQueue(item['docId'] as String);
        q = await _readQueue();
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

  /// Is this session finished? Decides whether a clip uploads straight into
  /// P01..P20 or waits in the holding folder.
  ///
  /// Cached for the length of one drain: a speaker does not finish halfway
  /// through their own upload queue, and asking Firestore once per clip for
  /// the same answer would be twenty reads for one session.
  final Map<String, bool> _completeCache = {};

  Future<bool> _speakerIsComplete(String speakerId) async {
    final cached = _completeCache[speakerId];
    if (cached != null) return cached;
    var complete = false;
    try {
      final doc = await speakers.doc(speakerId).get();
      complete = (doc.data()?['status'] as String?) == 'complete';
    } catch (e) {
      // Offline, or the row has not synced yet. The holding folder is the
      // safe answer: a clip that waits there is found and moved later, a
      // clip written into P01..P20 too early is not.
      debugPrint('speaker status lookup failed: $e');
    }
    _completeCache[speakerId] = complete;
    return complete;
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
