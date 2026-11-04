import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// City and current weather for the sidebar header.
///
/// Location: coarse only (city level is all we show). Weather: Open-Meteo,
/// free and keyless. Cached for 30 minutes so opening the menu is instant.
class WeatherService extends ChangeNotifier {
  static final WeatherService instance = WeatherService._();
  WeatherService._();

  static const _cacheKey = 'weather_cache_v1';
  static const _maxAge = Duration(minutes: 30);

  String? city;
  double? tempC;
  int? code;
  bool locationDenied = false;
  bool loading = false;
  DateTime? _fetchedAt;

  bool get hasData => tempC != null;

  /// 'w_clear', 'w_rain' … — a key for tr().
  String get conditionKey {
    final c = code ?? 0;
    if (c == 0 || c == 1) return 'w_clear';
    if (c <= 3) return 'w_cloudy';
    if (c == 45 || c == 48) return 'w_fog';
    if (c >= 51 && c <= 57) return 'w_drizzle';
    if ((c >= 61 && c <= 67) || (c >= 80 && c <= 82)) return 'w_rain';
    if ((c >= 71 && c <= 77) || c == 85 || c == 86) return 'w_snow';
    if (c >= 95) return 'w_storm';
    return 'w_cloudy';
  }

  Future<void> refresh({bool askPermission = false}) async {
    if (loading) return;
    if (_fetchedAt != null && DateTime.now().difference(_fetchedAt!) < _maxAge) {
      return;
    }
    loading = true;
    notifyListeners();
    try {
      await _loadCache();
      if (_fetchedAt != null &&
          DateTime.now().difference(_fetchedAt!) < _maxAge) {
        return;
      }

      if (!await Geolocator.isLocationServiceEnabled()) {
        locationDenied = true;
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied && askPermission) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        locationDenied = true;
        return;
      }
      locationDenied = false;

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 15),
        ),
      );

      try {
        final marks =
            await placemarkFromCoordinates(pos.latitude, pos.longitude);
        if (marks.isNotEmpty) {
          final m = marks.first;
          city = [m.locality, m.subAdministrativeArea, m.administrativeArea]
              .firstWhere((s) => s != null && s.isNotEmpty, orElse: () => null);
        }
      } catch (e) {
        debugPrint('reverse geocode failed: $e');
      }

      final uri = Uri.parse('https://api.open-meteo.com/v1/forecast'
          '?latitude=${pos.latitude.toStringAsFixed(3)}'
          '&longitude=${pos.longitude.toStringAsFixed(3)}'
          '&current=temperature_2m,weather_code&timezone=auto');
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        final cur = (jsonDecode(res.body) as Map<String, dynamic>)['current']
            as Map<String, dynamic>;
        tempC = (cur['temperature_2m'] as num).toDouble();
        code = (cur['weather_code'] as num).toInt();
        _fetchedAt = DateTime.now();
        await _saveCache();
      }
    } catch (e) {
      debugPrint('weather failed: $e');
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _loadCache() async {
    if (hasData) return;
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_cacheKey);
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      city = m['city'] as String?;
      tempC = (m['tempC'] as num?)?.toDouble();
      code = (m['code'] as num?)?.toInt();
      final at = m['at'] as String?;
      _fetchedAt = at == null ? null : DateTime.tryParse(at);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _saveCache() async {
    try {
      await (await SharedPreferences.getInstance()).setString(
          _cacheKey,
          jsonEncode({
            'city': city,
            'tempC': tempC,
            'code': code,
            'at': _fetchedAt?.toIso8601String(),
          }));
    } catch (_) {}
  }
}
