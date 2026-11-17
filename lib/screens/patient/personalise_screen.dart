import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/l10n.dart';
import '../../app/theme.dart';
import '../../phrases.dart';
import '../../services/language_service.dart';
import '../../services/lip_reader.dart';
import '../../services/model_service.dart';
import '../../services/personal_store.dart';
import '../../widgets/lip_camera.dart';

/// Few-shot personalisation — the research contribution.
///
/// The patient mouths each phrase a few times. Nothing is retrained: each
/// sample becomes a fingerprint, the fingerprints of a phrase are averaged,
/// and at recognition time the phrase whose average is nearest pulls the
/// answer towards it. That is cheap enough to run on any phone, works from
/// the first sample, and survives a model update.
class PersonaliseScreen extends StatefulWidget {
  const PersonaliseScreen({super.key});

  @override
  State<PersonaliseScreen> createState() => _PersonaliseScreenState();
}

class _PersonaliseScreenState extends State<PersonaliseScreen> {
  final _store = PersonalStore.instance;
  final _models = ModelService.instance;

  @override
  void initState() {
    super.initState();
    _store.addListener(_changed);
    _models.addListener(_changed);
    unawaited(_models.sync());
    unawaited(_open());
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    _models.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    unawaited(_open());
  }

  Future<void> _open() async {
    final card = _models.current;
    if (card != null) await _store.open(card);
  }

  String _samplesOf(Phrase p) => trf('pers_samples',
      {'n': _store.count(p.id), 'm': PersonalStore.maxPerPhrase});

  Future<void> _clearAll() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(tr('pers_clear_confirm')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('pers_clear'))),
        ],
      ),
    );
    if (go == true) await _store.clearAll();
  }

  @override
  Widget build(BuildContext context) {
    final card = _models.current;
    final text = Theme.of(context).textTheme;
    if (card == null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
        children: [
          const Icon(Icons.tune, size: 64, color: Brand.teal),
          const SizedBox(height: 16),
          Text(tr('pers_need_model'),
              textAlign: TextAlign.center, style: text.titleMedium),
          const SizedBox(height: 8),
          Text(
              _models.downloading
                  ? trf('speak_downloading',
                      {'p': (_models.progress * 100).round()})
                  : trf('speak_no_model',
                      {'lang': LanguageService.instance.current.name}),
              textAlign: TextAlign.center),
        ],
      );
    }

    final total = card.labels.length;
    final learned = card.labels.where((p) => _store.count(p.id) > 0).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                SizedBox(
                  width: 84,
                  height: 84,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox.expand(
                        child: CircularProgressIndicator(
                          value: total == 0 ? 0 : learned / total,
                          strokeWidth: 8,
                          backgroundColor: Brand.teal.withValues(alpha: 0.15),
                        ),
                      ),
                      Text('$learned/$total',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(trf('pers_progress', {'n': learned, 't': total}),
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text(tr('pers_body'), style: text.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        for (final (i, key) in const [
          (1, 'pers_step1'),
          (2, 'pers_step2'),
          (3, 'pers_step3'),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 13,
                  backgroundColor: Brand.indigo,
                  child: Text('$i',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(tr(key))),
              ],
            ),
          ),
        const SizedBox(height: 8),
        for (final p in card.labels)
          Card(
            child: ListTile(
              title: Text(p.devanagari,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${phraseMeaning(p)}\n${_samplesOf(p)}'),
              isThreeLine: true,
              trailing: Icon(
                _store.count(p.id) > 0
                    ? Icons.check_circle
                    : Icons.fiber_manual_record,
                color: _store.count(p.id) > 0 ? Brand.teal : Brand.urgent,
              ),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => PersonaliseRecordScreen(phrase: p))),
            ),
          ),
        const SizedBox(height: 12),
        Text(tr('pers_private'),
            textAlign: TextAlign.center, style: text.bodySmall),
        if (_store.total > 0) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _clearAll,
            icon: const Icon(Icons.delete_outline),
            label: Text(tr('pers_clear')),
          ),
        ],
      ],
    );
  }
}

/// Records samples of one phrase.
class PersonaliseRecordScreen extends StatefulWidget {
  final Phrase phrase;
  const PersonaliseRecordScreen({super.key, required this.phrase});

  @override
  State<PersonaliseRecordScreen> createState() =>
      _PersonaliseRecordScreenState();
}

class _PersonaliseRecordScreenState extends State<PersonaliseRecordScreen> {
  final _camKey = GlobalKey<LipCameraState>();
  final _store = PersonalStore.instance;
  bool _working = false;
  String? _note;
  bool _noteIsProblem = false;

  Future<void> _record() async {
    final card = ModelService.instance.current;
    final cam = _camKey.currentState;
    if (card == null || cam == null || _working) return;
    setState(() => _note = null);
    final shot = await cam.capture(card);
    if (!mounted) return;
    if (shot == null) {
      setState(() {
        _note = tr('speak_camera_error');
        _noteIsProblem = true;
      });
      return;
    }
    setState(() => _working = true);
    try {
      final problem = await LipReader.instance.ensureLoaded();
      if (problem != null) throw StateError(problem);
      final (crops, why) =
          await LipReader.instance.crop(shot.$1, shot.$2, card);
      if (crops == null) {
        if (mounted) {
          setState(() {
            _note = why == 'no-face' ? tr('speak_no_face') : tr('speak_failed');
            _noteIsProblem = true;
          });
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final r = LipReader.instance.run(crops);
      if (r == null) throw StateError('model not loaded');
      await _store.open(card);
      await _store.add(widget.phrase.id, crops, r);
      final heard = card.labels[r.ranked.first].devanagari;
      if (mounted) {
        setState(() {
          _note = trf('pers_saved', {'p': heard});
          _noteIsProblem = false;
        });
      }
    } catch (e) {
      debugPrint('personalise failed: $e');
      if (mounted) {
        setState(() {
          _note = tr('speak_failed');
          _noteIsProblem = true;
        });
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.phrase;
    final n = _store.count(p.id);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('pers_record_title')),
        actions: [
          if (n > 0)
            IconButton(
              tooltip: tr('pers_clear_one'),
              onPressed: _working
                  ? null
                  : () async {
                      await _store.clearPhrase(p.id);
                      if (mounted) setState(() => _note = null);
                    },
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(p.devanagari,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
          Text(phraseMeaning(p), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          LipCamera(key: _camKey),
          const SizedBox(height: 12),
          Text(
              trf('pers_samples',
                  {'n': n, 'm': PersonalStore.maxPerPhrase}),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium),
          if (_working)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(tr('speak_reading'), textAlign: TextAlign.center),
            ),
          if (_note != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_note!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: _noteIsProblem ? Brand.urgent : Brand.teal,
                      fontWeight: FontWeight.w600)),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            style:
                FilledButton.styleFrom(minimumSize: const Size.fromHeight(60)),
            onPressed: _working ? null : _record,
            icon: const Icon(Icons.fiber_manual_record),
            label: Text(tr('pers_record')),
          ),
        ],
      ),
    );
  }
}
