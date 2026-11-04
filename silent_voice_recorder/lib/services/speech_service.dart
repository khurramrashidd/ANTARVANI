import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One thing the patient said.
class SpokenItem {
  final String text;
  final String source; // board | type | quick | speak | sos
  final DateTime at;
  final String lang;

  const SpokenItem(this.text, this.source, this.at, this.lang);

  Map<String, dynamic> toJson() =>
      {'t': text, 's': source, 'a': at.toIso8601String(), 'l': lang};

  static SpokenItem? fromJson(Map<String, dynamic> m) {
    final at = DateTime.tryParse(m['a'] as String? ?? '');
    if (at == null) return null;
    return SpokenItem(m['t'] as String? ?? '', m['s'] as String? ?? '', at,
        m['l'] as String? ?? 'hi-IN');
  }
}

/// Text-to-speech plus the patient's history. History stays on this phone.
class SpeechService extends ChangeNotifier {
  static final SpeechService instance = SpeechService._();
  SpeechService._();

  static const _histKey = 'speech_history_v1';
  static const _maxHistory = 300;

  final FlutterTts _tts = FlutterTts();
  bool _inited = false;
  List<SpokenItem> _history = [];
  String? speaking;

  List<SpokenItem> get history => List.unmodifiable(_history);

  Future<void> _init() async {
    if (_inited) return;
    _inited = true;
    try {
      await _tts.awaitSpeakCompletion(true);
      await _tts.setSpeechRate(0.45);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
    } catch (e) {
      debugPrint('tts init: $e');
    }
    await _loadHistory();
  }

  /// Speaks [text] in [lang] (e.g. hi-IN) and logs it. If the phone has no
  /// voice for that language it falls back to the default voice.
  Future<void> say(String text,
      {required String lang, String source = 'board', bool log = true}) async {
    if (text.trim().isEmpty) return;
    await _init();
    speaking = text;
    notifyListeners();
    if (log) _add(SpokenItem(text, source, DateTime.now(), lang));
    try {
      await _tts.stop();
      final ok = await _tts.isLanguageAvailable(lang);
      if (ok == true) await _tts.setLanguage(lang);
      await _tts.speak(text);
    } catch (e) {
      debugPrint('tts speak: $e');
    } finally {
      speaking = null;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
    speaking = null;
    notifyListeners();
  }

  Future<void> ensureLoaded() => _init();

  void _add(SpokenItem item) {
    _history.insert(0, item);
    if (_history.length > _maxHistory) {
      _history = _history.sublist(0, _maxHistory);
    }
    notifyListeners();
    _saveHistory();
  }

  Future<void> clearHistory() async {
    _history = [];
    notifyListeners();
    await _saveHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final raw =
          (await SharedPreferences.getInstance()).getStringList(_histKey) ?? [];
      _history = raw
          .map((s) => SpokenItem.fromJson(jsonDecode(s) as Map<String, dynamic>))
          .whereType<SpokenItem>()
          .toList();
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _saveHistory() async {
    try {
      await (await SharedPreferences.getInstance()).setStringList(
          _histKey, _history.map((h) => jsonEncode(h.toJson())).toList());
    } catch (_) {}
  }
}

/// The caregiver's name and number, kept on this phone.
class Caregiver {
  static const _kName = 'caregiver_name';
  static const _kPhone = 'caregiver_phone';

  static Future<(String, String)> load() async {
    final p = await SharedPreferences.getInstance();
    return (p.getString(_kName) ?? '', p.getString(_kPhone) ?? '');
  }

  static Future<void> save(String name, String phone) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kName, name.trim());
    await p.setString(_kPhone, phone.trim());
  }
}
