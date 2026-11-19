import 'dart:convert';
import 'dart:io';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phrases.dart';
import 'auth_service.dart';

/// What happened when we tried to destroy a file.
enum DriveDeleteOutcome {
  /// Gone for good.
  deleted,

  /// In its owner's bin; Drive empties that by itself after 30 days.
  trashed,

  /// Still in Drive, but out of the corpus and renamed DELETED_… because
  /// only its owner can destroy it.
  movedAside,

  /// Nothing worked.
  failed,
}

/// What happened when we tried to move a file between corpus folders.
enum DriveMoveOutcome {
  /// It is in its new folder.
  moved,

  /// Drive refused: the file belongs to another account and this one may
  /// read it but not move it. Its owner has to do it from their own phone.
  notAllowed,

  /// No such file any more — already moved, or deleted by its owner.
  notFound,

  /// Something else went wrong; [DriveUploader.lastError] says what.
  failed,
}

/// One video sitting in the Drive corpus folder.
class DriveClip {
  final String fileId;
  final String name;
  final String phraseId;
  final int bytes;
  final DateTime? createdTime;

  const DriveClip({
    required this.fileId,
    required this.name,
    required this.phraseId,
    required this.bytes,
    this.createdTime,
  });

  /// True for files the app itself wrote: S014_P03_t01.mp4
  bool get isAppNamed => RegExp(r'^S\d+_P\d{2}_t\d{2}\.').hasMatch(name);
}

/// Uploads clips into the ONE shared corpus folder in khurramrashid0786's
/// Drive, sorted into the phrase folders the training pipeline reads:
///
///   <corpus folder>/P03/S014_P03_t01.mp4
///
/// The Firebase project lives in the 6893 account; that does not matter here.
/// Drive calls act as whoever is signed in on the phone, so each team member
/// must have Editor access to the corpus folder (0786 shares it once).
///
/// Scope is full `drive`, because `drive.file` cannot write into a folder the
/// app did not create — and the corpus folder was made by hand in Drive.
class DriveUploader {
  /// https://drive.google.com/drive/folders/1Hw76NlkEjJdCsD40TY-YhA4qBIlGVqex
  static const String corpusFolderId = '1Hw76NlkEjJdCsD40TY-YhA4qBIlGVqex';
  static const String corpusOwner = 'khurramrashid0786@gmail.com';

  /// Rejected clips move here: out of P01..P20 so the pipeline ignores them,
  /// but still recoverable and countable for the paper's QC numbers.
  static const String rejectedFolderName = '_rejected';

  /// Where files land when their owner is someone else, so they cannot be
  /// destroyed from this phone. Out of the corpus, clearly named, waiting.
  static const String deletedFolderName = '_deleted';

  /// Sessions that are still short of their target sit here, one folder per
  /// speaker, until they are finished:
  ///
  ///   <corpus>/_in_progress/S011/S011_P03_t01.mp4
  ///
  /// The training pipeline reads P01..P20 and ignores every folder whose
  /// name does not match, so a half-recorded volunteer cannot leak into a
  /// model by accident — and counting the files in one folder tells you
  /// exactly how far that volunteer has got.
  ///
  /// When the session is finished the app moves its clips into P01..P20.
  /// The move is done by the account that uploaded them, because Drive lets
  /// an account move its own files and nobody else's.
  static const String inProgressFolderName = '_in_progress';

  /// Speaker IDs master has rejected, one per line, at the top of the corpus
  /// folder. The notebook reads it and leaves those speakers out, which
  /// takes effect the moment it is written — no files have to move for a
  /// rejection to count.
  static const String skipListFileName = '_skip_speakers.txt';

  static const _kGranted = 'drive_granted';

  GoogleSignIn get _signIn => AuthService.instance.google;

  drive.DriveApi? _api;
  final Map<String, String> _phraseFolders = {};
  final Map<String, String> _langRoots = {};
  String? _rejectedFolderId;
  String? _deletedFolderId;
  String? _holdingFolderId;
  final Map<String, String> _speakerFolders = {};

  /// Why the last operation failed, in words the operator can act on.
  String? lastError;

  /// null = not checked yet, true = can write, false = no access.
  bool? corpusWritable;

  String? get accountEmail => _signIn.currentUser?.email;
  bool get signedIn => _api != null;

  /// Connects to Drive as the signed-in person.
  ///
  /// interactive: false — at startup. Never shows anything; works only if
  ///   this person already granted Drive access once.
  /// interactive: true — when a collector taps "Connect". Shows Google's
  ///   account and permission screens if needed.
  Future<bool> connect({required bool interactive}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var acct = _signIn.currentUser ?? await _signIn.signInSilently();
      if (acct == null && interactive) acct = await _signIn.signIn();
      if (acct == null) return false;

      if (!interactive && prefs.getBool(_kGranted) != true) return false;
      // Already granted -> returns at once without any screen.
      final granted = await _signIn.requestScopes([drive.DriveApi.driveScope]);
      if (!granted) {
        lastError = 'Drive permission was not given.';
        return false;
      }
      await prefs.setBool(_kGranted, true);

      final client = await _signIn.authenticatedClient();
      if (client == null) return false;
      _api = drive.DriveApi(client);
      await checkCorpusAccess();
      return true;
    } catch (e) {
      lastError = 'Drive connection failed: $e';
      debugPrint(lastError);
      return false;
    }
  }

  /// Google access tokens last about an hour, and the client built from one
  /// never renews itself. So a long collecting session, or a background
  /// upload hours after the app was last opened, fails every Drive call with
  /// `invalid_token` until the client is rebuilt — which is exactly what
  /// left clips sitting on phones with "Access was denied" against them.
  static bool tokenExpired(Object e) {
    final s = e.toString();
    return s.contains('invalid_token') ||
        s.contains('Invalid Credentials') ||
        s.contains('Access was denied') ||
        s.contains('UNAUTHENTICATED');
  }

  /// Throws away the stale token and builds a new client. Shows nothing on
  /// screen, so it is safe from the background service too.
  Future<bool> refreshAuth() async {
    try {
      final acct = _signIn.currentUser ?? await _signIn.signInSilently();
      if (acct == null) {
        lastError = 'Signed out of Google. Open the app and connect Drive '
            'again.';
        return false;
      }
      // Throw the dead token away first. Without this the next call hands
      // back the same expired one out of the platform's own cache, and the
      // retry fails exactly like the first attempt.
      try {
        await acct.clearAuthCache();
      } catch (e) {
        debugPrint('clearAuthCache: $e');
      }
      final client = await _signIn.authenticatedClient();
      if (client == null) {
        lastError = 'Google would not renew the Drive permission.';
        return false;
      }
      _api = drive.DriveApi(client);
      debugPrint('Drive token refreshed');
      return true;
    } catch (e) {
      lastError = 'Could not renew the Drive sign-in: $e';
      debugPrint(lastError);
      return false;
    }
  }

  /// Runs a Drive call; if the token had expired, renews it once and runs
  /// the call again. Anything else is left for the caller to report.
  ///
  /// Methods that already have their own error handling take the `retried`
  /// flag instead and call themselves once — same idea, without nesting a
  /// closure inside code that is already doing several steps.
  Future<T> _retrying<T>(Future<T> Function() call) async {
    try {
      return await call();
    } catch (e) {
      if (!tokenExpired(e)) rethrow;
      if (!await refreshAuth()) rethrow;
      return await call();
    }
  }

  void reset() {
    _api = null;
    _phraseFolders.clear();
    _langRoots.clear();
    _rejectedFolderId = null;
    _deletedFolderId = null;
    _holdingFolderId = null;
    _speakerFolders.clear();
    corpusWritable = null;
    lastError = null;
  }

  /// Confirms this account can add files to the corpus folder.
  Future<bool> checkCorpusAccess() async {
    final api = _api;
    if (api == null) return false;
    try {
      final f = await _retrying(() async => await (_api ?? api).files.get(
            corpusFolderId,
            $fields: 'id,name,capabilities(canAddChildren)',
          ) as drive.File);
      corpusWritable = f.capabilities?.canAddChildren ?? false;
      lastError = corpusWritable!
          ? null
          : '$accountEmail can view but not add to the corpus folder. '
              'Ask $corpusOwner to make it Editor.';
    } catch (e) {
      corpusWritable = false;
      lastError = '$accountEmail has no access to the corpus folder. '
          'Ask $corpusOwner to share it (Editor).';
      debugPrint('corpus check failed: $e');
    }
    return corpusWritable!;
  }

  // ------------------------------------------------------------- folders
  /// Folder name of a language inside the corpus: "lang_mr".
  static String langFolderName(String code) => 'lang_$code';

  /// Where the language in use keeps its P01.. folders. Hindi sits directly
  /// in the corpus folder (that is where the first recordings went); every
  /// other language has its own sub-folder, made on first use.
  Future<String> _root() async {
    final code = PhraseBook.code;
    if (code == 'hi') return corpusFolderId;
    final cached = _langRoots[code];
    if (cached != null) return cached;
    final id = await _childFolder(corpusFolderId, langFolderName(code));
    _langRoots[code] = id;
    return id;
  }

  Future<String?> _findChild(String parent, String name) async {
    final api = _api;
    if (api == null) return null;
    final found = await api.files.list(
      q: "name = '$name' and "
          "mimeType = 'application/vnd.google-apps.folder' and "
          "'$parent' in parents and trashed = false",
      $fields: 'files(id)',
    );
    final files = found.files;
    return (files == null || files.isEmpty) ? null : files.first.id;
  }

  Future<String> _childFolder(String parent, String name) async {
    final existing = await _findChild(parent, name);
    if (existing != null) return existing;
    final created = await _api!.files.create(
      drive.File()
        ..name = name
        ..mimeType = 'application/vnd.google-apps.folder'
        ..parents = [parent],
      $fields: 'id',
    );
    return created.id!;
  }

  Future<String?> _findFolder(String name) async {
    if (_api == null) return null;
    return _findChild(await _root(), name);
  }

  Future<String> _folder(String name) async =>
      _childFolder(await _root(), name);

  /// Writes phrases.json into a language's folder, replacing an older copy.
  /// The training notebook reads the phrase list from this file.
  Future<bool> writeLanguageSpec(String code, String json,
      {bool retried = false}) async {
    final api = _api;
    if (api == null) {
      lastError = 'Drive is not connected.';
      return false;
    }
    try {
      final parent = code == 'hi'
          ? corpusFolderId
          : await _childFolder(corpusFolderId, langFolderName(code));
      _langRoots[code] = parent;
      final old = await api.files.list(
        q: "name = 'phrases.json' and '$parent' in parents and "
            "trashed = false",
        $fields: 'files(id)',
      );
      final bytes = utf8.encode(json);
      final media = drive.Media(Stream.value(bytes), bytes.length,
          contentType: 'application/json');
      final hits = old.files ?? const <drive.File>[];
      if (hits.isNotEmpty && hits.first.id != null) {
        await api.files.update(drive.File(), hits.first.id!,
            uploadMedia: media);
      } else {
        await api.files.create(
          drive.File()
            ..name = 'phrases.json'
            ..parents = [parent],
          uploadMedia: media,
          $fields: 'id',
        );
      }
      lastError = null;
      return true;
    } catch (e) {
      if (!retried && tokenExpired(e) && await refreshAuth()) {
        return writeLanguageSpec(code, json, retried: true);
      }
      lastError = 'Could not write phrases.json: $e';
      debugPrint(lastError);
      return false;
    }
  }

  /// Writes the rejected-speaker list the notebook reads, replacing the old
  /// copy rather than piling up duplicates beside it.
  ///
  /// Written even when it is empty: an empty file is how the notebook knows
  /// nobody is excluded, where a missing one could equally mean the app has
  /// never written it.
  Future<bool> writeSkipList(Iterable<String> speakerIds,
      {bool retried = false}) async {
    final api = _api;
    if (api == null) {
      lastError = 'Drive is not connected.';
      return false;
    }
    final ids = speakerIds.toSet().toList()..sort();
    final body = StringBuffer()
      ..writeln('# Speakers master has rejected. The training notebook skips')
      ..writeln('# every ID listed here. Written by the app - do not edit by')
      ..writeln('# hand; put a session back from Speakers instead.')
      ..writeAll(ids.map((e) => '$e\n'));
    try {
      final bytes = utf8.encode(body.toString());
      final media = drive.Media(Stream.value(bytes), bytes.length,
          contentType: 'text/plain');
      final old = await api.files.list(
        q: "name = '$skipListFileName' and '$corpusFolderId' in parents and "
            "trashed = false",
        $fields: 'files(id)',
      );
      final hits = old.files ?? const <drive.File>[];
      if (hits.isNotEmpty && hits.first.id != null) {
        await api.files
            .update(drive.File(), hits.first.id!, uploadMedia: media);
      } else {
        await api.files.create(
          drive.File()
            ..name = skipListFileName
            ..parents = [corpusFolderId],
          uploadMedia: media,
          $fields: 'id',
        );
      }
      lastError = null;
      return true;
    } catch (e) {
      if (!retried && tokenExpired(e) && await refreshAuth()) {
        return writeSkipList(ids, retried: true);
      }
      lastError = 'Could not write $skipListFileName: $e';
      debugPrint(lastError);
      return false;
    }
  }

  /// Finds P01..P20 inside the corpus folder, creating it only if missing.
  Future<String> _phraseFolder(String phraseId) async {
    final key = '${PhraseBook.code}/$phraseId';
    final cached = _phraseFolders[key];
    if (cached != null) return cached;
    final id = await _folder(phraseId);
    _phraseFolders[key] = id;
    return id;
  }

  /// `_in_progress/S011`, made on first use.
  Future<String> holdingFolder(String speakerId) async {
    final key = '${PhraseBook.code}/$speakerId';
    final cached = _speakerFolders[key];
    if (cached != null) return cached;
    _holdingFolderId ??= await _folder(inProgressFolderName);
    final id = await _childFolder(_holdingFolderId!, speakerId);
    _speakerFolders[key] = id;
    return id;
  }

  /// Moves a file into another folder of the corpus, taking it out of
  /// whatever folder it is in now.
  ///
  /// This is the one operation the whole holding-folder idea rests on, and
  /// it is the one Drive is fussiest about: an account can move a file it
  /// uploaded, and cannot move one somebody else uploaded, however much
  /// access it has to the folder around it. So the outcome is reported
  /// rather than thrown, and the caller tells the person whose phone has to
  /// finish the job.
  Future<DriveMoveOutcome> moveTo(String fileId, String toFolderId,
      {bool retried = false}) async {
    final api = _api;
    if (api == null) {
      lastError = 'Drive is not connected.';
      return DriveMoveOutcome.failed;
    }
    try {
      final current =
          await api.files.get(fileId, $fields: 'parents') as drive.File;
      final parents = current.parents ?? const <String>[];
      if (parents.length == 1 && parents.first == toFolderId) {
        lastError = null;
        return DriveMoveOutcome.moved; // already where it belongs
      }
      await api.files.update(
        drive.File(),
        fileId,
        addParents: toFolderId,
        removeParents: parents.isEmpty ? null : parents.join(','),
      );
      lastError = null;
      return DriveMoveOutcome.moved;
    } catch (e) {
      if (!retried && tokenExpired(e) && await refreshAuth()) {
        return moveTo(fileId, toFolderId, retried: true);
      }
      final msg = e.toString();
      if (msg.contains('404') || msg.contains('notFound')) {
        return DriveMoveOutcome.notFound;
      }
      if (msg.contains('403') ||
          msg.contains('insufficient') ||
          msg.contains('forbidden')) {
        lastError = 'Drive will only let the account that uploaded this clip '
            'move it.';
        return DriveMoveOutcome.notAllowed;
      }
      lastError = 'Could not move the file: $e';
      debugPrint(lastError);
      return DriveMoveOutcome.failed;
    }
  }

  /// Out of the holding folder and into P01..P20, where training reads.
  Future<DriveMoveOutcome> moveIntoCorpus(String fileId, String phraseId) async =>
      moveTo(fileId, await _phraseFolder(phraseId));

  /// Back into the holding folder — a session that was finished and is not
  /// any more, or one being un-rejected before it is complete again.
  Future<DriveMoveOutcome> moveIntoHolding(
          String fileId, String speakerId) async =>
      moveTo(fileId, await holdingFolder(speakerId));

  /// A link that opens this exact file in Drive, in a browser or the Drive app.
  static String webLink(String fileId) =>
      'https://drive.google.com/file/d/$fileId/view';

  /// Where the file sits inside the corpus folder: "P03/S014_P03_t01.mp4".
  static String pathOf(String phraseId, String fileName) =>
      '$phraseId/$fileName';

  /// "S014_P03_t01.mp4" -> "P03". Works for clips queued by older builds too.
  static String phraseOf(String fileName) {
    final m = RegExp(r'_(P\d{2})_').firstMatch(fileName);
    return m?.group(1) ?? 'unsorted';
  }

  // -------------------------------------------------------------- upload
  /// Uploads one clip. Returns the Drive file id, or null on failure so the
  /// caller can leave it queued and retry later. If the same file name is
  /// already in the folder (an earlier attempt that lost its reply), returns
  /// that file instead of making a duplicate.
  Future<String?> upload({
    required File file,
    required String fileName,
    required String speakerId,
    bool speakerComplete = false,
  }) async {
    if (_api == null) return null;
    if (!file.existsSync()) return null;
    if (corpusWritable != true && !await checkCorpusAccess()) return null;
    try {
      // Everything here goes through _retrying: the folder lookup and the
      // upload are both ordinary Drive calls, and the token can expire
      // between one clip and the next.
      return await _retrying<String?>(() async {
        // A finished session uploads straight into P01..P20; anything still
        // short of its target goes to the holding folder and is moved in
        // when it is done. Deciding here rather than moving everything later
        // keeps the number of moves — the one call Drive may refuse — down
        // to the clips that actually need one.
        final parent = speakerComplete
            ? await _phraseFolder(phraseOf(fileName))
            : await holdingFolder(speakerId);

        final existing = await _api!.files.list(
          q: "name = '$fileName' and '$parent' in parents and trashed = false",
          $fields: 'files(id)',
        );
        final hits = existing.files;
        // Already there — an earlier run uploaded it. Nothing is duplicated.
        if (hits != null && hits.isNotEmpty) return hits.first.id;

        // The stream is opened inside the retry, so a second attempt reads
        // the file from the beginning instead of from an exhausted stream.
        final media = drive.Media(file.openRead(), file.lengthSync(),
            contentType: 'video/mp4');
        final created = await _api!.files.create(
          drive.File()
            ..name = fileName
            ..parents = [parent]
            ..appProperties = {'speakerId': speakerId},
          uploadMedia: media,
          $fields: 'id',
        );
        lastError = null;
        return created.id;
      });
    } catch (e) {
      lastError = tokenExpired(e)
          ? 'Google sign-in has expired and could not be renewed. Open the '
              'app, go to Corpus and tap Connect Drive.'
          : 'Drive upload failed: $e';
      debugPrint('Drive upload failed for $fileName: $e');
      return null;
    }
  }

  /// Writes a text file (the manifest) into the top of the corpus folder,
  /// beside P01..P20. Returns the file id.
  Future<String?> uploadText({
    required String fileName,
    required String text,
    String contentType = 'text/csv',
    bool retried = false,
  }) async {
    final api = _api;
    if (api == null) {
      lastError = 'Drive is not connected.';
      return null;
    }
    try {
      final bytes = utf8.encode(text);
      final created = await api.files.create(
        drive.File()
          ..name = fileName
          ..parents = [corpusFolderId],
        uploadMedia: drive.Media(Stream.value(bytes), bytes.length,
            contentType: contentType),
        $fields: 'id',
      );
      lastError = null;
      return created.id;
    } catch (e) {
      if (!retried && tokenExpired(e) && await refreshAuth()) {
        return uploadText(
            fileName: fileName,
            text: text,
            contentType: contentType,
            retried: true);
      }
      lastError = 'Could not write $fileName to Drive: $e';
      debugPrint(lastError);
      return null;
    }
  }

  // -------------------------------------------------------------- import
  /// Every video inside the P01..P20 folders. Used to find clips that were
  /// put in Drive by hand, before the app existed.
  Future<List<DriveClip>> scanCorpus(List<String> phraseIds,
      {bool retried = false}) async {
    final api = _api;
    if (api == null) {
      lastError = 'Drive is not connected.';
      return const [];
    }
    try {
      return await _scan(api, phraseIds);
    } catch (e) {
      if (!retried && tokenExpired(e) && await refreshAuth()) {
        return scanCorpus(phraseIds, retried: true);
      }
      lastError = 'Could not read the corpus folder: $e';
      debugPrint(lastError);
      return const [];
    }
  }

  Future<List<DriveClip>> _scan(
      drive.DriveApi api, List<String> phraseIds) async {
    final out = <DriveClip>[];
    for (final phraseId in phraseIds) {
      final folderId = await _findFolder(phraseId);
      if (folderId == null) continue; // phrase never recorded
      String? pageToken;
      do {
        final res = await api.files.list(
          q: "'$folderId' in parents and trashed = false and "
              "mimeType contains 'video/'",
          $fields: 'nextPageToken,files(id,name,size,createdTime)',
          pageSize: 200,
          pageToken: pageToken,
        );
        for (final f in res.files ?? const <drive.File>[]) {
          out.add(DriveClip(
            fileId: f.id!,
            name: f.name ?? '',
            phraseId: phraseId,
            bytes: int.tryParse(f.size ?? '0') ?? 0,
            createdTime: f.createdTime,
          ));
        }
        pageToken = res.nextPageToken;
      } while (pageToken != null);
    }

    // Unfinished sessions wait in _in_progress/<speaker>. They are part of
    // the corpus even though training does not read them yet, so a scan
    // that skipped them would report clips as missing from Drive when they
    // are sitting right there.
    final holding = await _findFolder(inProgressFolderName);
    if (holding != null) {
      final folders = await api.files.list(
        q: "'$holding' in parents and trashed = false and "
            "mimeType = 'application/vnd.google-apps.folder'",
        $fields: 'files(id)',
        pageSize: 200,
      );
      for (final f in folders.files ?? const <drive.File>[]) {
        if (f.id == null) continue;
        String? pageToken;
        do {
          final res = await api.files.list(
            q: "'${f.id}' in parents and trashed = false and "
                "mimeType contains 'video/'",
            $fields: 'nextPageToken,files(id,name,size,createdTime)',
            pageSize: 200,
            pageToken: pageToken,
          );
          for (final v in res.files ?? const <drive.File>[]) {
            final pid = phraseOf(v.name ?? '');
            if (!phraseIds.contains(pid)) continue;
            out.add(DriveClip(
              fileId: v.id!,
              name: v.name ?? '',
              phraseId: pid,
              bytes: int.tryParse(v.size ?? '0') ?? 0,
              createdTime: v.createdTime,
            ));
          }
          pageToken = res.nextPageToken;
        } while (pageToken != null);
      }
    }
    return out;
  }

  /// Renames a file in place, so imported clips follow the same naming as
  /// everything the app records.
  Future<bool> rename(String fileId, String newName,
      {bool retried = false}) async {
    try {
      await _api!.files.update(drive.File()..name = newName, fileId);
      return true;
    } catch (e) {
      if (!retried && tokenExpired(e) && await refreshAuth()) {
        return rename(fileId, newName, retried: true);
      }
      lastError = 'Could not rename in Drive: $e';
      debugPrint(lastError);
      return false;
    }
  }

  /// What actually happened to a file we tried to destroy.
  ///
  /// Google Drive only lets the **owner** of a file delete it, and the owner
  /// is whoever uploaded it — not whoever owns the folder it sits in. So a
  /// clip Kinza recorded cannot be destroyed from Khurram's phone, however
  /// senior he is. The fallbacks keep it out of the corpus either way.
  Future<DriveDeleteOutcome> deleteForever(String fileId,
      {bool retried = false}) async {
    final api = _api;
    if (api == null) {
      lastError = 'Drive is not connected.';
      return DriveDeleteOutcome.failed;
    }

    // 1. The real thing — works when this account uploaded the file.
    try {
      await api.files.delete(fileId);
      lastError = null;
      return DriveDeleteOutcome.deleted;
    } catch (e) {
      final msg = '$e';
      // Already gone counts as success: the goal is that it is not there.
      if (msg.contains('404') || msg.contains('notFound')) {
        return DriveDeleteOutcome.deleted;
      }
      // An hour-old sign-in reads as "Access was denied", which looks like
      // the owner-only rule below but is not: renew and try once more.
      if (!retried && tokenExpired(e) && await refreshAuth()) {
        return deleteForever(fileId, retried: true);
      }
      if (!msg.contains('403') && !msg.contains('insufficient')) {
        lastError = 'Could not delete in Drive: $e';
        debugPrint(lastError);
        return DriveDeleteOutcome.failed;
      }
    }

    // 2. Someone else owns it. The bin still empties by itself after 30 days.
    try {
      await api.files.update(drive.File()..trashed = true, fileId);
      lastError = null;
      return DriveDeleteOutcome.trashed;
    } catch (e) {
      debugPrint('trash refused too: $e');
    }

    // 3. Last resort: out of P01..P20 and renamed, so it can never be
    //    mistaken for corpus data while its owner gets round to deleting it.
    try {
      _deletedFolderId ??= await _folder(deletedFolderName);
      final current =
          await api.files.get(fileId, $fields: 'name,parents') as drive.File;
      final parents = (current.parents ?? const <String>[]).join(',');
      await api.files.update(
        drive.File()..name = 'DELETED_${current.name ?? fileId}',
        fileId,
        addParents: _deletedFolderId,
        removeParents: parents.isEmpty ? null : parents,
      );
      lastError = null;
      return DriveDeleteOutcome.movedAside;
    } catch (e) {
      lastError = 'Could not remove the file from Drive: $e';
      debugPrint(lastError);
      return DriveDeleteOutcome.failed;
    }
  }

  /// Lets one person read one file. Used so a volunteer can watch their own
  /// clips without the corpus folder being open to anyone with a link.
  ///
  /// Any editor of the folder can do this, not only the uploader — sharing is
  /// a lighter permission than deleting.
  Future<bool> shareWith(String fileId, String email,
      {bool retried = false}) async {
    final api = _api;
    if (api == null) {
      lastError = 'Drive is not connected.';
      return false;
    }
    try {
      await api.permissions.create(
        drive.Permission()
          ..role = 'reader'
          ..type = 'user'
          ..emailAddress = email,
        fileId,
        sendNotificationEmail: false,
      );
      lastError = null;
      return true;
    } catch (e) {
      final msg = '$e';
      // Already shared is success: the goal is that they can watch it.
      if (msg.contains('alreadyExists') || msg.contains('duplicate')) {
        return true;
      }
      if (!retried && tokenExpired(e) && await refreshAuth()) {
        return shareWith(fileId, email, retried: true);
      }
      lastError = 'Could not share the file: $e';
      debugPrint(lastError);
      return false;
    }
  }

  // -------------------------------------------------------------- reject
  /// Moves a file out of its phrase folder into `_rejected`. The file is not
  /// destroyed: it can be looked at later, and it no longer trains anything.
  Future<bool> reject(String fileId, {bool retried = false}) async {
    final api = _api;
    if (api == null) {
      lastError = 'Drive is not connected.';
      return false;
    }
    try {
      _rejectedFolderId ??= await _folder(rejectedFolderName);
      final current =
          await api.files.get(fileId, $fields: 'parents') as drive.File;
      final parents = (current.parents ?? const <String>[]).join(',');
      await api.files.update(
        drive.File(),
        fileId,
        addParents: _rejectedFolderId,
        removeParents: parents.isEmpty ? null : parents,
      );
      lastError = null;
      return true;
    } catch (e) {
      if (!retried && tokenExpired(e) && await refreshAuth()) {
        return reject(fileId, retried: true);
      }
      lastError = 'Could not move the file to $rejectedFolderName: $e';
      debugPrint(lastError);
      return false;
    }
  }
}
