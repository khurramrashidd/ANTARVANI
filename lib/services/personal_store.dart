import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'lip_reader.dart';
import 'model_service.dart';

/// The patient's own samples — the "few shots" of few-shot personalisation.
///
/// What is kept is the mouth crop of each sample (small greyscale frames, no
/// audio, no face), on this phone only. From those the app computes one
/// fingerprint per phrase with whatever model is installed. Because the
/// crops are kept and not just the fingerprints, a model update does not
/// cost the patient their personalisation: the fingerprints are simply
/// recomputed with the new model the next time Speak opens.
class PersonalStore extends ChangeNotifier {
  static final PersonalStore instance = PersonalStore._();
  PersonalStore._();

  static const int maxPerPhrase = 5;

  String? _lang;
  int _version = -1;

  /// phrase id -> sample files, oldest first
  final Map<String, List<File>> _samples = {};

  /// file name -> fingerprint, for the installed model version
  final Map<String, Float32List> _emb = {};

  Future<Directory> _dir(String lang) async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/personal/$lang');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  static String _name(File f) => f.uri.pathSegments.last;

  int count(String phraseId) => _samples[phraseId]?.length ?? 0;
  int get phrasesDone => _samples.values.where((l) => l.isNotEmpty).length;
  int get total => _samples.values.fold(0, (a, l) => a + l.length);

  /// Reads what is stored for [card]'s language. Cheap; call before use.
  Future<void> open(ModelCard card) async {
    if (_lang == card.lang && _version == card.version) return;
    _lang = card.lang;
    _version = card.version;
    _samples.clear();
    _emb.clear();
    try {
      final d = await _dir(card.lang);
      final files = d
          .listSync()
          .whereType<File>()
          .where((f) => _name(f).endsWith('.lip'))
          .toList()
        ..sort((a, b) => _name(a).compareTo(_name(b)));
      for (final f in files) {
        final id = _name(f).split('_').first;
        (_samples[id] ??= []).add(f);
      }
      final cache = File('${d.path}/emb_v${card.version}.json');
      if (cache.existsSync()) {
        final m = jsonDecode(cache.readAsStringSync()) as Map<String, dynamic>;
        m.forEach((k, v) => _emb[k] = Float32List.fromList(
            (v as List).map((e) => (e as num).toDouble()).toList()));
      }
    } catch (e) {
      debugPrint('personal store open: $e');
    }
    notifyListeners();
  }

  Future<void> _saveCache() async {
    final lang = _lang;
    if (lang == null) return;
    try {
      final d = await _dir(lang);
      // Fingerprints from older model versions are of no use any more.
      for (final f in d.listSync().whereType<File>()) {
        final n = _name(f);
        if (n.startsWith('emb_v') && n != 'emb_v$_version.json') f.deleteSync();
      }
      await File('${d.path}/emb_v$_version.json').writeAsString(
          jsonEncode({for (final e in _emb.entries) e.key: e.value.toList()}));
    } catch (e) {
      debugPrint('personal cache save: $e');
    }
  }

  /// Number of samples whose fingerprint still has to be computed with the
  /// installed model (after a model update).
  int get stale => _samples.values
      .expand((l) => l)
      .where((f) => !_emb.containsKey(_name(f)))
      .length;

  /// Recomputes missing fingerprints. Call after [open] with the model
  /// loaded; a sample whose crop no longer fits the model is dropped.
  Future<void> refresh(LipReader reader, ModelCard card) async {
    final want = card.frames * card.size * card.size;
    var changed = false;
    for (final list in _samples.values) {
      for (final f in List<File>.from(list)) {
        if (_emb.containsKey(_name(f))) continue;
        try {
          final crops = Uint8List.fromList(gzip.decode(f.readAsBytesSync()));
          final r = crops.length == want ? reader.run(crops) : null;
          if (r == null) {
            f.deleteSync();
            list.remove(f);
          } else {
            _emb[_name(f)] = r.embedding;
          }
          changed = true;
        } catch (e) {
          debugPrint('refresh ${_name(f)}: $e');
        }
        // let the screen breathe between inferences
        await Future<void>.delayed(const Duration(milliseconds: 4));
      }
    }
    if (changed) {
      await _saveCache();
      notifyListeners();
    }
  }

  /// Keeps one sample of [phraseId]. The oldest goes when there are more
  /// than [maxPerPhrase].
  Future<void> add(String phraseId, Uint8List crops, LipResult r) async {
    final lang = _lang;
    if (lang == null) return;
    final d = await _dir(lang);
    final f = File(
        '${d.path}/${phraseId}_${DateTime.now().millisecondsSinceEpoch}.lip');
    await f.writeAsBytes(gzip.encode(crops), flush: true);
    final list = _samples[phraseId] ??= [];
    list.add(f);
    _emb[_name(f)] = r.embedding;
    while (list.length > maxPerPhrase) {
      final old = list.removeAt(0);
      _emb.remove(_name(old));
      try {
        old.deleteSync();
      } catch (_) {}
    }
    await _saveCache();
    notifyListeners();
  }

  Future<void> clearPhrase(String phraseId) async {
    for (final f in _samples.remove(phraseId) ?? const <File>[]) {
      _emb.remove(_name(f));
      try {
        f.deleteSync();
      } catch (_) {}
    }
    await _saveCache();
    notifyListeners();
  }

  Future<void> clearAll() async {
    for (final id in _samples.keys.toList()) {
      for (final f in _samples[id]!) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
    _samples.clear();
    _emb.clear();
    await _saveCache();
    notifyListeners();
  }

  /// label index -> mean fingerprint of that phrase's samples.
  Map<int, Float32List> prototypes(ModelCard card) {
    final out = <int, Float32List>{};
    for (var c = 0; c < card.labels.length; c++) {
      final files = _samples[card.labels[c].id] ?? const <File>[];
      final embs = [
        for (final f in files)
          if (_emb[_name(f)] != null) _emb[_name(f)]!
      ];
      if (embs.isEmpty) continue;
      final mean = Float32List(embs.first.length);
      for (final e in embs) {
        for (var i = 0; i < mean.length && i < e.length; i++) {
          mean[i] += e[i] / embs.length;
        }
      }
      out[c] = mean;
    }
    return out;
  }
}
