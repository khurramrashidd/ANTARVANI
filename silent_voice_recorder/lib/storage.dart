import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// On-disk layout. Firestore is the manifest now, but the folder tree is kept
/// self-describing on purpose: if every other system fails, the folder alone
/// still carries the labels.
///
///   <external files dir>/silent_voice/data/S001/P01/S001_P01_t01.mp4
class Storage {
  static Directory? _root;

  static Future<Directory> root() async {
    if (_root != null) return _root!;
    final base = Platform.isAndroid
        ? (await getExternalStorageDirectory())!
        : await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/silent_voice');
    await dir.create(recursive: true);
    _root = dir;
    return dir;
  }

  static Future<Directory> dataDir() async {
    final dir = Directory('${(await root()).path}/data');
    await dir.create(recursive: true);
    return dir;
  }

  static Future<File> clipFile(
      String speakerId, String phraseId, int take) async {
    final dir = Directory('${(await dataDir()).path}/$speakerId/$phraseId');
    await dir.create(recursive: true);
    final name =
        '${speakerId}_${phraseId}_t${take.toString().padLeft(2, '0')}.mp4';
    return File('${dir.path}/$name');
  }

  /// Speaker metadata written beside the clips. This is the record of truth —
  /// Firestore is a mirror of it, not the other way round. If Firebase is off,
  /// misconfigured or the phone never goes online, nothing is lost.
  static Future<void> writeSessionMeta(Map<String, dynamic> meta) async {
    final id = meta['speakerId'] as String? ?? 'unknown';
    final dir = Directory('${(await dataDir()).path}/$id');
    await dir.create(recursive: true);
    await File('${dir.path}/session.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(meta));
  }

  /// One row per kept clip, appended as it is recorded. The preprocessing
  /// pipeline can read this directly if Firestore was never reachable.
  static Future<void> appendManifest(Map<String, dynamic> row) async {
    final f = File('${(await root()).path}/manifest.csv');
    const cols = [
      'speakerId', 'phraseId', 'label', 'take', 'fileName',
      'retakes', 'qcVerdict', 'qcFaceScore', 'fileBytes', 'capturedUtc',
    ];
    if (!f.existsSync()) {
      await f.writeAsString('${cols.join(",")}\n');
    }
    final line = cols.map((c) => '${row[c] ?? ''}').join(',');
    await f.writeAsString('$line\n', mode: FileMode.append);
  }

  static Future<String> rootPathForDisplay() async => (await root()).path;

  /// True once at least one clip exists for this speaker — used to decide
  /// whether an ID was really consumed or the session was abandoned.
  static Future<bool> speakerHasClips(String speakerId) async {
    final dir = Directory('${(await dataDir()).path}/$speakerId');
    if (!dir.existsSync()) return false;
    return dir
        .listSync(recursive: true)
        .any((f) => f is File && f.path.endsWith('.mp4'));
  }

  static Future<int> localBytes() async {
    final dir = await dataDir();
    if (!dir.existsSync()) return 0;
    var total = 0;
    for (final f in dir.listSync(recursive: true)) {
      if (f is File) total += f.lengthSync();
    }
    return total;
  }

  static String human(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
