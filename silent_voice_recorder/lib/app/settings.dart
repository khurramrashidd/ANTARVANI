import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Language and light/dark mode. English and light mode are the defaults.
/// Saved on the phone, so each person keeps their own choice.
class AppSettings extends ChangeNotifier {
  static final AppSettings instance = AppSettings._();
  AppSettings._();

  static const languages = {'en': 'English', 'hi': 'हिन्दी', 'mr': 'मराठी'};

  String _lang = 'en';
  bool _dark = false;

  String get lang => _lang;
  bool get dark => _dark;
  ThemeMode get themeMode => _dark ? ThemeMode.dark : ThemeMode.light;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final l = p.getString('lang');
    _lang = languages.containsKey(l) ? l! : 'en';
    _dark = p.getBool('dark') ?? false;
  }

  Future<void> setLang(String code) async {
    if (!languages.containsKey(code) || code == _lang) return;
    _lang = code;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString('lang', code);
  }

  Future<void> setDark(bool v) async {
    if (v == _dark) return;
    _dark = v;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool('dark', v);
  }
}
