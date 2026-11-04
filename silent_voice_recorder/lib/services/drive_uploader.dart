import 'dart:convert';
import 'dart:io';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';

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

  static const _kGranted = 'drive_granted';

  GoogleSignIn get _signIn => AuthService.instance.google;

  drive.DriveApi? _api;
  final Map<String, String> _phraseFolders = {};
  String? _rejectedFolderId;

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

  void reset() {
    _api = null;
    _phraseFolders.clear();
    _rejectedFolderId = null;
    corpusWritable = null;
    lastError = null;
  }

  /// Confirms this account can add files to the corpus folder.
  Future<bool> checkCorpusAccess() async {
    final api = _api;
    if (api == null) return false;
    try {
      final f = await api.files.get(
        corpusFolderId,
        $fields: 'id,name,capabilities(canAddChildren)',
      ) as drive.File;
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
  Future<String?> _findFolder(String name) async {
    final api = _api;
    if (api == null) return null;
    final found = await api.files.list(
      q: "name = '$name' and "
          "mimeType = 'application/vnd.google-apps.folder' and "
          "'$corpusFolderId' in parents and trashed = false",
      $fields: 'files(id)',
    );
    final files = found.files;
    return (files == null || files.isEmpty) ? null : files.first.id;
  }

  Future<String> _folder(String name) async {
    final existing = await _findFolder(name);
    if (existing != null) return existing;
    final created = await _api!.files.create(
      drive.File()
        ..name = name
        ..mimeType = 'application/vnd.google-apps.folder'
        ..parents = [corpusFolderId],
      $fields: 'id',
    );
    return created.id!;
  }

  /// Finds P01..P20 inside the corpus folder, creating it only if missing.
  Future<String> _phraseFolder(String phraseId) async {
    final cached = _phraseFolders[phraseId];
    if (cached != null) return cached;
    final id = await _folder(phraseId);
    _phraseFolders[phraseId] = id;
    return id;
  }

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
  }) async {
    if (_api == null) return null;
    if (!file.existsSync()) return null;
    if (corpusWritable != true && !await checkCorpusAccess()) return null;
    try {
      final parent = await _phraseFolder(phraseOf(fileName));

      final existing = await _api!.files.list(
        q: "name = '$fileName' and '$parent' in parents and trashed = false",
        $fields: 'files(id)',
      );
      final hits = existing.files;
      if (hits != null && hits.isNotEmpty) return hits.first.id;

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
    } catch (e) {
      lastError = 'Drive upload failed: $e';
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
      lastError = 'Could not write $fileName to Drive: $e';
      debugPrint(lastError);
      return null;
    }
  }

  // -------------------------------------------------------------- import
  /// Every video inside the P01..P20 folders. Used to find clips that were
  /// put in Drive by hand, before the app existed.
  Future<List<DriveClip>> scanCorpus(List<String> phraseIds) async {
    final api = _api;
    if (api == null) {
      lastError = 'Drive is not connected.';
      return const [];
    }
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
    return out;
  }

  /// Renames a file in place, so imported clips follow the same naming as
  /// everything the app records.
  Future<bool> rename(String fileId, String newName) async {
    try {
      await _api!.files.update(drive.File()..name = newName, fileId);
      return true;
    } catch (e) {
      lastError = 'Could not rename in Drive: $e';
      debugPrint(lastError);
      return false;
    }
  }

  // -------------------------------------------------------------- reject
  /// Moves a file out of its phrase folder into `_rejected`. The file is not
  /// destroyed: it can be looked at later, and it no longer trains anything.
  Future<bool> reject(String fileId) async {
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
      lastError = 'Could not move the file to $rejectedFolderName: $e';
      debugPrint(lastError);
      return false;
    }
  }
}
