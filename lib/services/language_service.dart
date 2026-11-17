import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../phrases.dart';
import 'sync_service.dart';
import 'team.dart';

/// The languages this project works in, and which one this phone is using.
///
/// Hindi is built into the app. Any other language is one Firestore row,
/// `languages/{code}`, holding its phrase list. An admin adds it once; every
/// phone picks it up, collectors can then record it, and the training
/// notebook finds its phrase list in Drive next to the videos.
class LanguageService extends ChangeNotifier {
  static final LanguageService instance = LanguageService._();
  LanguageService._();

  static const _kCode = 'phrase_lang';
  static const _kCache = 'languages_cache_v1';

  static CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('languages');

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;

  List<Language> get languages => PhraseBook.all.values.toList()
    ..sort((a, b) => a.code == 'hi'
        ? -1
        : b.code == 'hi'
            ? 1
            : a.name.compareTo(b.name));

  String get code => PhraseBook.code;
  Language get current => PhraseBook.current;

  /// Reads the saved choice and the last known list from the phone, so the
  /// right language is in place before the first screen is drawn — even
  /// with no signal.
  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      for (final s in p.getStringList(_kCache) ?? const <String>[]) {
        final (lang, _) =
            Language.parse(jsonDecode(s) as Map<String, dynamic>);
        if (lang != null && lang.code != 'hi') PhraseBook.all[lang.code] = lang;
      }
      final saved = p.getString(_kCode);
      if (saved != null && PhraseBook.all.containsKey(saved)) {
        PhraseBook.code = saved;
      }
    } catch (e) {
      debugPrint('language cache: $e');
    }
  }

  /// Call once someone is signed in; the rules refuse the read before that.
  void watch() {
    _sub ??= _col.snapshots().listen((snap) async {
      final found = <String, Language>{'hi': PhraseBook.hindi};
      for (final d in snap.docs) {
        final (lang, why) = Language.parse({...d.data(), 'code': d.id});
        if (lang == null) {
          debugPrint('language ${d.id} ignored: $why');
        } else if (lang.code != 'hi') {
          found[lang.code] = lang;
        }
      }
      PhraseBook.all
        ..clear()
        ..addAll(found);
      if (!PhraseBook.all.containsKey(PhraseBook.code)) PhraseBook.code = 'hi';
      notifyListeners();
      try {
        final p = await SharedPreferences.getInstance();
        await p.setStringList(_kCache, [
          for (final l in found.values)
            if (l.code != 'hi') jsonEncode(l.toMap())
        ]);
      } catch (_) {}
    }, onError: (Object e) {
      debugPrint('languages watch failed: $e');
      _sub?.cancel();
      _sub = null;
    });
  }

  /// Returns null on success, or why the switch was refused.
  Future<String?> use(String code) async {
    if (code == PhraseBook.code) return null;
    if (!PhraseBook.all.containsKey(code)) return 'Unknown language.';
    // A queued clip is filed under the language in use when it uploads, so
    // switching with uploads waiting would put them in the wrong folder.
    final waiting = SyncService.instance.pendingCount;
    if (waiting > 0) {
      return '$waiting clip(s) are still uploading. Wait for them to finish, '
          'then switch language.';
    }
    PhraseBook.code = code;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(_kCode, code);
    return null;
  }

  /// Admin: add or replace a language. [source] is either a link to a
  /// phrases JSON file or the JSON text itself. Also writes phrases.json into
  /// the language's Drive folder, which is where the notebook looks for it.
  /// Returns (message, ok).
  Future<(String, bool)> add(String source) async {
    final text = source.trim();
    String body;
    if (text.startsWith('http')) {
      try {
        final r = await http
            .get(Uri.parse(text))
            .timeout(const Duration(seconds: 30));
        if (r.statusCode != 200) {
          return ('The link answered ${r.statusCode}. Open it in a browser '
              'to check it shows the JSON text.', false);
        }
        body = utf8.decode(r.bodyBytes);
      } catch (e) {
        return ('Could not open the link: $e', false);
      }
    } else {
      body = text;
    }
    Map<String, dynamic> map;
    try {
      map = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return ('That is not JSON. Use the template in pipeline/languages/.',
          false);
    }
    final (lang, why) = Language.parse(map);
    if (lang == null) return (why ?? 'Not usable.', false);
    if (lang.code == 'hi') {
      return ('Hindi is built into the app and cannot be replaced.', false);
    }
    final existing = PhraseBook.all[lang.code];
    if (existing != null && existing.phrases.length != lang.phrases.length) {
      return ('${existing.name} already has ${existing.phrases.length} '
          'phrases. The count cannot change once recording has started — the '
          'numbers are the training labels.', false);
    }
    try {
      await _col.doc(lang.code).set({
        ...lang.toMap(),
        'addedBy': Team.email,
        'addedAt': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (e) {
      return (e.code == 'permission-denied'
          ? 'Only an admin can add a language. If you are one, run setup once '
              'so the new rules are deployed.'
          : 'Could not save: ${e.code}', false);
    }
    final wrote = await SyncService.instance.drive.writeLanguageSpec(
        lang.code, const JsonEncoder.withIndent(' ').convert(lang.toMap()));
    if (wrote) {
      return ('${lang.name} added with ${lang.phrases.length} phrases. '
          'Choose it under Languages to start recording.', true);
    }
    final driveError =
        SyncService.instance.drive.lastError ?? 'Drive not connected';
    return ('${lang.name} added, but its phrases.json could not be written '
        'to Drive ($driveError). Connect Drive and add it again before training.',
        true);
  }
}
