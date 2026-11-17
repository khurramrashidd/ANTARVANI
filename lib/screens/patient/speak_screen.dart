import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/l10n.dart';
import '../../app/theme.dart';
import '../../phrases.dart';
import '../../services/language_service.dart';
import '../../services/lip_reader.dart';
import '../../services/model_service.dart';
import '../../services/personal_store.dart';
import '../../services/speech_service.dart';
import '../../widgets/lip_camera.dart';

/// Silent speech: the camera watches the lips, the model names the phrase,
/// the phone says it aloud.
///
/// The model is not part of the app. It is downloaded from wherever the
/// admin published it and replaced whenever a newer one is published, so
/// this screen has to cope with "none yet", "downloading" and "ready".
class SpeakScreen extends StatefulWidget {
  const SpeakScreen({super.key});

  @override
  State<SpeakScreen> createState() => _SpeakScreenState();
}

class _SpeakScreenState extends State<SpeakScreen> {
  final _camKey = GlobalKey<LipCameraState>();

  bool _working = false; // cropping + inference
  bool _refreshing = false; // personal samples being recomputed
  String? _message; // a problem to show
  ModelCard? _card; // the card the current result belongs to
  List<int> _ranked = const [];
  Float32List? _probs;
  int? _spoken; // label index that was said aloud
  int _personalN = 0;

  @override
  void initState() {
    super.initState();
    ModelService.instance.addListener(_onModel);
    unawaited(ModelService.instance.sync());
    unawaited(_prepare());
  }

  @override
  void dispose() {
    ModelService.instance.removeListener(_onModel);
    super.dispose();
  }

  void _onModel() {
    if (!mounted) return;
    setState(() {});
    unawaited(_prepare());
  }

  /// Loads the installed model and brings personal samples up to date.
  Future<void> _prepare() async {
    final card = ModelService.instance.current;
    if (card == null || _refreshing) return;
    final problem = await LipReader.instance.ensureLoaded();
    if (!mounted) return;
    if (problem != null) {
      setState(() => _message = problem == 'no-model' ? null : problem);
      return;
    }
    final store = PersonalStore.instance;
    await store.open(card);
    if (store.stale > 0) {
      if (mounted) setState(() => _refreshing = true);
      await store.refresh(LipReader.instance, card);
    }
    if (mounted) {
      setState(() {
        _refreshing = false;
        _personalN = store.total;
      });
    }
  }

  Future<void> _go() async {
    final card = ModelService.instance.current;
    final cam = _camKey.currentState;
    if (card == null || cam == null || _working) return;
    setState(() {
      _message = null;
      _ranked = const [];
      _probs = null;
      _spoken = null;
    });
    await SpeechService.instance.stop();
    final shot = await cam.capture(card);
    if (!mounted) return;
    if (shot == null) {
      setState(() => _message = tr('speak_camera_error'));
      return;
    }
    setState(() => _working = true);
    try {
      final problem = await LipReader.instance.ensureLoaded();
      if (problem != null) throw StateError(problem);
      final (crops, why) = await LipReader.instance.crop(shot.$1, shot.$2, card);
      if (crops == null) {
        if (mounted) {
          setState(() => _message =
              why == 'no-face' ? tr('speak_no_face') : tr('speak_failed'));
        }
        return;
      }
      // One frame for the "reading" state to paint before the model runs.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final raw = LipReader.instance.run(crops);
      if (raw == null) throw StateError('model not loaded');
      final store = PersonalStore.instance;
      await store.open(card);
      final probs =
          LipReader.personalise(raw, store.prototypes(card), card);
      final ranked = LipResult(probs, raw.embedding).ranked;
      if (!mounted) return;
      setState(() {
        _card = card;
        _probs = probs;
        _ranked = ranked;
        _personalN = store.total;
      });
      if (probs[ranked.first] >= card.minConfidence) {
        await _say(ranked.first);
      }
    } catch (e) {
      debugPrint('speak failed: $e');
      if (mounted) setState(() => _message = tr('speak_failed'));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _say(int label) async {
    final card = _card;
    if (card == null || label >= card.labels.length) return;
    setState(() => _spoken = label);
    await SpeechService.instance
        .say(card.labels[label].devanagari, lang: card.tts, source: 'speak');
  }

  @override
  Widget build(BuildContext context) {
    final models = ModelService.instance;
    final card = models.current;
    final text = Theme.of(context).textTheme;

    if (card == null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
        children: [
          Icon(
              models.downloading
                  ? Icons.downloading_rounded
                  : Icons.cloud_off_outlined,
              size: 64,
              color: Brand.teal),
          const SizedBox(height: 16),
          if (models.downloading) ...[
            Text(
                trf('speak_downloading',
                    {'p': (models.progress * 100).round()}),
                textAlign: TextAlign.center,
                style: text.titleMedium),
            const SizedBox(height: 16),
            LinearProgressIndicator(
                value: models.progress == 0 ? null : models.progress,
                minHeight: 8),
          ] else if (models.error != null && models.wanted != null) ...[
            Text(trf('speak_model_error', {'e': models.error!}),
                textAlign: TextAlign.center, style: text.titleMedium),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: models.sync,
              icon: const Icon(Icons.refresh),
              label: Text(tr('speak_retry')),
            ),
          ] else
            Text(
                trf('speak_no_model',
                    {'lang': LanguageService.instance.current.name}),
                textAlign: TextAlign.center,
                style: text.titleMedium?.copyWith(height: 1.4)),
        ],
      );
    }

    final top = _ranked.isEmpty ? null : _ranked.first;
    final sure =
        top != null && _probs != null && _probs![top] >= card.minConfidence;
    Phrase label(int i) => (_card ?? card).labels[i];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Text(tr('speak_hint'), style: text.bodyLarge),
        const SizedBox(height: 12),
        LipCamera(key: _camKey),
        const SizedBox(height: 12),
        if (_refreshing)
          _Note(icon: Icons.sync, text: tr('speak_updating_personal')),
        if (_message != null)
          _Note(icon: Icons.info_outline, text: _message!, warn: true),
        if (_working)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 3)),
                const SizedBox(width: 12),
                Text(tr('speak_reading'), style: text.titleMedium),
              ],
            ),
          ),
        if (top != null && !_working)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(sure ? tr('speak_result') : tr('speak_unsure'),
                      style: text.labelLarge),
                  const SizedBox(height: 8),
                  if (sure) ...[
                    Text(label(top).devanagari,
                        style: const TextStyle(
                            fontSize: 28, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(phraseMeaning(label(top)), style: text.bodyMedium),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                                value: _probs![top].clamp(0.0, 1.0).toDouble(),
                                minHeight: 8),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text('${(_probs![top] * 100).round()}%'),
                        IconButton(
                          tooltip: tr('type_speak'),
                          onPressed: () => _say(top),
                          icon: const Icon(Icons.volume_up_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(tr('speak_alt'), style: text.bodySmall),
                    const SizedBox(height: 6),
                  ],
                  for (final i in _ranked.skip(sure ? 1 : 0).take(sure ? 2 : 3))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(56),
                          alignment: Alignment.centerLeft,
                          side: BorderSide(
                              color: _spoken == i ? Brand.teal : Brand.indigo,
                              width: _spoken == i ? 2.5 : 1),
                        ),
                        onPressed: () => _say(i),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(label(i).devanagari,
                                  style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700)),
                            ),
                            Text('${(_probs![i] * 100).round()}%',
                                style: text.bodySmall),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(60)),
          onPressed: _working || _refreshing ? null : _go,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(top == null ? tr('speak_start') : tr('speak_again')),
        ),
        const SizedBox(height: 12),
        Text(
          [
            trf('speak_model_info', {'lang': card.name, 'v': card.version}),
            if (_personalN > 0) trf('speak_personalised', {'n': _personalN}),
            if (models.downloading)
              trf('speak_downloading', {'p': (models.progress * 100).round()}),
          ].join(' · '),
          textAlign: TextAlign.center,
          style: text.bodySmall,
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool warn;
  const _Note({required this.icon, required this.text, this.warn = false});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: warn ? Brand.urgent : Brand.teal),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ],
        ),
      );
}
