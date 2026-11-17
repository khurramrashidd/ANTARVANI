import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../phrases.dart';
import 'team.dart';

/// Everything the phone needs to know about one trained model. Written by
/// the training notebook as a small .json file next to the .tflite.
class ModelCard {
  final String lang;
  final String name;
  final String tts;
  final int version;
  final String file; // file name of the .tflite
  final String url; // where to download it
  final String sha256;
  final int sizeBytes;
  final int frames; // 48
  final int size; // 88
  final double fps; // 16
  final double eyeBoxScale; // 1.6
  final int embeddingDim;
  final double alpha; // personalisation blend
  final double tau;
  final double minConfidence;
  final List<Phrase> labels;
  final int speakers;
  final int clips;
  final double? top1;
  final double? top3;
  final String trainedAt;
  final String notes;

  const ModelCard({
    required this.lang,
    required this.name,
    required this.tts,
    required this.version,
    required this.file,
    required this.url,
    required this.sha256,
    required this.sizeBytes,
    required this.frames,
    required this.size,
    required this.fps,
    required this.eyeBoxScale,
    required this.embeddingDim,
    required this.alpha,
    required this.tau,
    required this.minConfidence,
    required this.labels,
    required this.speakers,
    required this.clips,
    required this.top1,
    required this.top3,
    required this.trainedAt,
    required this.notes,
  });

  double get windowSeconds => frames / fps;

  Map<String, dynamic> toMap() => {
        'schema': 1,
        'lang': lang,
        'name': name,
        'tts': tts,
        'version': version,
        'file': file,
        'url': url,
        'sha256': sha256,
        'sizeBytes': sizeBytes,
        'frames': frames,
        'size': size,
        'fps': fps,
        'eyeBoxScale': eyeBoxScale,
        'embeddingDim': embeddingDim,
        'alpha': alpha,
        'tau': tau,
        'minConfidence': minConfidence,
        'labels': [
          for (final p in labels)
            {
              'id': p.id,
              'text': p.devanagari,
              'roman': p.roman,
              'english': p.english,
            }
        ],
        'speakers': speakers,
        'clips': clips,
        'top1': top1,
        'top3': top3,
        'trainedAt': trainedAt,
        'notes': notes,
      };

  /// Returns (card, null) or (null, why it cannot be used).
  /// [cardUrl] is where the .json came from; the .tflite sits beside it.
  static (ModelCard?, String?) parse(Map<String, dynamic> m,
      {String? cardUrl}) {
    final (lang, why) = Language.parse(m);
    if (lang == null) return (null, why);
    final version = (m['version'] as num?)?.toInt() ?? 0;
    final file = '${m['file'] ?? ''}';
    final sha = '${m['sha256'] ?? ''}'.toLowerCase();
    if (version <= 0) return (null, 'The card has no version number.');
    if (!file.endsWith('.tflite')) {
      return (null, 'The card does not name a .tflite file.');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
      return (null, 'The card has no checksum.');
    }
    var url = '${m['url'] ?? ''}';
    if (url.isEmpty && cardUrl != null) {
      final cut = cardUrl.lastIndexOf('/');
      if (cut > 8) url = '${cardUrl.substring(0, cut + 1)}$file';
    }
    if (!url.startsWith('https://')) {
      return (null, 'The model link must start with https://');
    }
    final frames = (m['frames'] as num?)?.toInt() ?? 48;
    final size = (m['size'] as num?)?.toInt() ?? 88;
    if (frames < 8 || frames > 128 || size < 32 || size > 160) {
      return (null, 'The card describes a clip shape this app cannot make.');
    }
    return (
      ModelCard(
        lang: lang.code,
        name: lang.name,
        tts: lang.tts,
        version: version,
        file: file,
        url: url,
        sha256: sha,
        sizeBytes: (m['sizeBytes'] as num?)?.toInt() ?? 0,
        frames: frames,
        size: size,
        fps: (m['fps'] as num?)?.toDouble() ?? 16,
        eyeBoxScale: (m['eyeBoxScale'] as num?)?.toDouble() ?? 1.6,
        embeddingDim: (m['embeddingDim'] as num?)?.toInt() ?? 192,
        alpha: (m['alpha'] as num?)?.toDouble() ?? 0.5,
        tau: (m['tau'] as num?)?.toDouble() ?? 0.1,
        minConfidence: (m['minConfidence'] as num?)?.toDouble() ?? 0.55,
        labels: lang.phrases,
        speakers: (m['speakers'] as num?)?.toInt() ?? 0,
        clips: (m['clips'] as num?)?.toInt() ?? 0,
        top1: (m['top1'] as num?)?.toDouble(),
        top3: (m['top3'] as num?)?.toDouble(),
        trainedAt: '${m['trainedAt'] ?? ''}',
        notes: '${m['notes'] ?? ''}',
      ),
      null
    );
  }

  /// "v3 · 24 speakers · 71% on new speakers"
  String get summary {
    final acc = top1 == null
        ? 'not evaluated'
        : '${(top1! * 100).round()}% on new speakers';
    return 'v$version · $speakers speakers · $acc';
  }
}

/// Keeps the recognition model on this phone equal to the one the admin
/// published — without a new APK.
///
/// The admin publishes one row per language, `models/{lang}`, naming a model
/// file and its checksum. Each phone watches the row for its language,
/// downloads the file when the version differs from what it has, checks the
/// checksum, and only then swaps it in. A failed or tampered download never
/// replaces a working model.
class ModelService extends ChangeNotifier {
  static final ModelService instance = ModelService._();
  ModelService._();

  static CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('models');

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;

  /// What the admin has published, by language.
  final Map<String, ModelCard> published = {};

  /// What is on this phone and verified, by language.
  final Map<String, ModelCard> installed = {};

  bool downloading = false;
  double progress = 0; // 0..1
  String? error;
  bool _loadedDisk = false;
  bool listening = false;

  ModelCard? get current => installed[PhraseBook.code];
  ModelCard? get wanted => published[PhraseBook.code];
  bool get upToDate =>
      current != null && (wanted == null || wanted!.version == current!.version);

  Future<Directory> _dir(String lang) async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/models/$lang');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<File> fileFor(String lang) async =>
      File('${(await _dir(lang)).path}/model.tflite');

  Future<void> _loadDisk() async {
    if (_loadedDisk) return;
    _loadedDisk = true;
    try {
      final base = await getApplicationSupportDirectory();
      final root = Directory('${base.path}/models');
      if (!root.existsSync()) return;
      for (final d in root.listSync().whereType<Directory>()) {
        final card = File('${d.path}/card.json');
        final model = File('${d.path}/model.tflite');
        if (!card.existsSync() || !model.existsSync()) continue;
        final (c, _) = ModelCard.parse(
            jsonDecode(card.readAsStringSync()) as Map<String, dynamic>);
        if (c != null) installed[c.lang] = c;
      }
    } catch (e) {
      debugPrint('model disk scan: $e');
    }
  }

  /// Call once someone is signed in.
  Future<void> start() async {
    await _loadDisk();
    notifyListeners();
    _sub ??= _col.snapshots().listen((snap) {
      published.clear();
      for (final d in snap.docs) {
        final (c, why) = ModelCard.parse({...d.data(), 'lang': d.id});
        if (c == null) {
          debugPrint('model ${d.id} ignored: $why');
        } else {
          published[c.lang] = c;
        }
      }
      listening = true;
      notifyListeners();
      unawaited(sync());
    }, onError: (Object e) {
      debugPrint('models watch failed: $e');
      _sub?.cancel();
      _sub = null;
    });
  }

  /// Brings the model for the language in use up to date. Safe to call often.
  Future<void> sync() async {
    await _loadDisk();
    final want = wanted;
    if (want == null || downloading) return;
    if (current?.version == want.version && current?.sha256 == want.sha256) {
      return;
    }
    downloading = true;
    progress = 0;
    error = null;
    notifyListeners();
    try {
      final bytes = await fetchVerified(want, onProgress: (p) {
        progress = p;
        notifyListeners();
      });
      final dir = await _dir(want.lang);
      final tmp = File('${dir.path}/model.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename('${dir.path}/model.tflite');
      await File('${dir.path}/card.json')
          .writeAsString(jsonEncode(want.toMap()), flush: true);
      installed[want.lang] = want;
    } catch (e) {
      error = '$e'.replaceFirst('Exception: ', '');
      debugPrint('model download failed: $e');
    } finally {
      downloading = false;
      notifyListeners();
    }
  }

  /// Downloads the model and refuses it unless the checksum matches.
  static Future<Uint8List> fetchVerified(ModelCard card,
      {void Function(double)? onProgress}) async {
    final client = http.Client();
    try {
      final res = await client
          .send(http.Request('GET', Uri.parse(card.url)))
          .timeout(const Duration(seconds: 40));
      if (res.statusCode != 200) {
        throw Exception('The model link answered ${res.statusCode}.');
      }
      final total = res.contentLength ?? card.sizeBytes;
      final out = BytesBuilder(copy: false);
      await for (final chunk
          in res.stream.timeout(const Duration(seconds: 40))) {
        out.add(chunk);
        if (total > 0) onProgress?.call((out.length / total).clamp(0.0, 1.0).toDouble());
      }
      final bytes = out.takeBytes();
      if (sha256.convert(bytes).toString() != card.sha256) {
        throw Exception('The downloaded model does not match its checksum. '
            'It was not installed.');
      }
      return bytes;
    } on TimeoutException {
      throw Exception('The download timed out. Check the connection.');
    } finally {
      client.close();
    }
  }

  // ------------------------------------------------------------- admin
  /// Reads a model card from [cardUrl], downloads the model it names to
  /// prove the link and checksum are good, and only then publishes it.
  /// Returns (card, null) or (null, message).
  Future<(ModelCard?, String?)> inspect(String cardUrl) async {
    final link = cardUrl.trim();
    if (!link.startsWith('https://') || !link.endsWith('.json')) {
      return (null, 'Paste the link of the model card — it starts with '
          'https:// and ends in .json');
    }
    Map<String, dynamic> map;
    try {
      final r =
          await http.get(Uri.parse(link)).timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) {
        return (null, 'The link answered ${r.statusCode}. If the repository '
            'is private, the phones cannot download from it.');
      }
      map = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (e) {
      return (null, 'Could not read the card: $e');
    }
    final (card, why) = ModelCard.parse(map, cardUrl: link);
    if (card == null) return (null, why);
    try {
      await fetchVerified(card);
    } catch (e) {
      return (null, '$e'.replaceFirst('Exception: ', ''));
    }
    return (card, null);
  }

  Future<String?> publish(ModelCard card) async {
    try {
      await _col.doc(card.lang).set({
        ...card.toMap(),
        'publishedBy': Team.email,
        'publishedAt': FieldValue.serverTimestamp(),
      });
      return null;
    } on FirebaseException catch (e) {
      return e.code == 'permission-denied'
          ? 'Only an admin can publish a model. If you are one, run setup '
              'once so the new rules are deployed.'
          : 'Could not publish: ${e.code}';
    }
  }

  /// Takes the model away from every phone for this language.
  Future<String?> withdraw(String lang) async {
    try {
      await _col.doc(lang).delete();
      return null;
    } on FirebaseException catch (e) {
      return 'Could not withdraw: ${e.code}';
    }
  }
}
