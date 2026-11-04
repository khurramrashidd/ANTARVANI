import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../app/l10n.dart';
import '../../app/theme.dart';
import '../../phrases.dart';
import '../../services/participant_service.dart';
import '../../services/team.dart';

/// A volunteer's own view of what the study holds about them.
///
/// They type the two numbers from their consent form; the server checks the
/// pair before letting them see anything, so one number alone is useless and
/// nobody can walk through the speaker numbers looking at names.
class MyClipsScreen extends StatefulWidget {
  const MyClipsScreen({super.key});

  @override
  State<MyClipsScreen> createState() => _MyClipsScreenState();
}

class _MyClipsScreenState extends State<MyClipsScreen> {
  final _speakerCtrl = TextEditingController();
  final _formCtrl = TextEditingController();
  final _svc = ParticipantService.instance;

  String? _speakerId;
  bool _busy = false;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _svc.remembered().then((id) {
      if (!mounted) return;
      setState(() {
        _speakerId = id;
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _speakerCtrl.dispose();
    _formCtrl.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await _svc.claim(
      speakerId: _speakerCtrl.text,
      formNo: _formCtrl.text,
    );
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    final id = await _svc.remembered();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _speakerId = id;
      _speakerCtrl.clear();
      _formCtrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!Team.signedIn) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(tr('mine_signin_first'), textAlign: TextAlign.center),
        ),
      );
    }
    return _speakerId == null ? _form(context) : _results(context, _speakerId!);
  }

  // --------------------------------------------------------------- the form
  Widget _form(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.badge_outlined, size: 32, color: Brand.teal),
                const SizedBox(height: 10),
                Text(tr('mine_intro'), style: const TextStyle(height: 1.4)),
                const SizedBox(height: 18),
                TextField(
                  controller: _speakerCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: tr('mine_speaker_id'),
                    hintText: 'S014',
                    prefixIcon: const Icon(Icons.tag),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _formCtrl,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: tr('mine_form_no'),
                    hintText: 'F014',
                    prefixIcon: const Icon(Icons.description_outlined),
                  ),
                ),
                const SizedBox(height: 10),
                Text(tr('mine_hint'),
                    style: Theme.of(context).textTheme.bodySmall),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(
                          color:
                              Theme.of(context).colorScheme.onErrorContainer),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _busy ? null : _check,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.search),
                  label:
                      Text(_busy ? tr('mine_checking') : tr('mine_show')),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------- the results
  Widget _results(BuildContext context, String speakerId) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: _svc.watchSpeaker(speakerId),
      builder: (context, snap) {
        if (snap.hasError || (snap.hasData && !snap.data!.exists)) {
          // The link was broken, or the row is gone.
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(tr('mine_none'), textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () async {
                      await _svc.forget();
                      if (mounted) setState(() => _speakerId = null);
                    },
                    child: Text(tr('mine_other')),
                  ),
                ],
              ),
            ),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final m = snap.data!.data() ?? const <String, dynamic>{};
        final pending = m['deletionRequested'] == true;

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _svc.watchClips(speakerId),
          builder: (context, clipSnap) {
            final docs = clipSnap.data?.docs ?? const [];
            final clips = docs.map((d) => d.data()).toList()
              ..sort((a, b) => '${a['phraseId']}${a['take']}'
                  .compareTo('${b['phraseId']}${b['take']}'));

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$speakerId · ${m['consentFormId'] ?? ''}',
                          style: const TextStyle(
                              fontSize: 22, fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 10),
                        _Row(tr('mine_name'), '${m['name'] ?? '—'}'),
                        _Row(tr('mine_age'), '${m['ageBand'] ?? '—'}'),
                        _Row(tr('mine_gender'), '${m['gender'] ?? '—'}'),
                        _Row(tr('mine_language'), '${m['firstLanguage'] ?? '—'}'),
                        _Row(tr('mine_lighting'), '${m['lighting'] ?? '—'}'),
                        _Row(tr('mine_recorded_on'), _date(m['sessionStartUtc'])),
                        _Row(
                          tr('mine_publish'),
                          m['consentToPublishDataset'] == true
                              ? tr('quick_yes')
                              : tr('quick_no'),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.mic_off_outlined, size: 16),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(tr('mine_no_audio'),
                                  style:
                                      Theme.of(context).textTheme.bodySmall),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (pending) ...[
                  const SizedBox(height: 12),
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          const Icon(Icons.schedule),
                          const SizedBox(width: 12),
                          Expanded(child: Text(tr('mine_delete_pending'))),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Text('${tr('mine_clips')} (${clips.where((c) => c['status'] != 'rejected').length})',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                if (clipSnap.hasError)
                  Text(tr('mine_none'))
                else if (!clipSnap.hasData)
                  const Center(child: CircularProgressIndicator())
                else if (clips.isEmpty)
                  Text(tr('mine_none'))
                else
                  for (final c in clips) _ClipTile(clip: c),
                const SizedBox(height: 24),
                if (!pending)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Brand.urgent,
                      minimumSize: const Size.fromHeight(50),
                    ),
                    onPressed: () => _askDelete(context, speakerId),
                    icon: const Icon(Icons.delete_outline),
                    label: Text(tr('mine_delete')),
                  ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () async {
                    await _svc.forget();
                    if (mounted) setState(() => _speakerId = null);
                  },
                  child: Text(tr('mine_other')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _askDelete(BuildContext context, String speakerId) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('mine_delete')),
        content: Text(tr('mine_delete_body')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Brand.urgent),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('mine_delete')),
          ),
        ],
      ),
    );
    if (go != true) return;
    final err = await _svc.requestDeletion(speakerId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(err ?? tr('mine_delete_sent'))),
    );
  }

  static String _date(Object? iso) {
    final t = DateTime.tryParse('${iso ?? ''}');
    if (t == null) return '—';
    final l = t.toLocal();
    return '${l.day} ${months[l.month - 1]} ${l.year}';
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  const _Row(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 118,
              child: Text(label,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            Expanded(
              child: Text(value.isEmpty ? '—' : value,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
}

class _ClipTile extends StatelessWidget {
  final Map<String, dynamic> clip;
  const _ClipTile({required this.clip});

  @override
  Widget build(BuildContext context) {
    final phraseId = clip['phraseId'] as String? ?? '';
    final idx = kPhrases.indexWhere((p) => p.id == phraseId);
    final phrase = idx < 0 ? null : kPhrases[idx];
    final rejected = clip['status'] == 'rejected';
    final uploaded = clip['uploaded'] == true;
    final color = rejected
        ? Colors.grey
        : uploaded
            ? const Color(0xFF2E7D32)
            : Brand.amber;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Card(
        child: ListTile(
          dense: true,
          leading: Icon(rejected ? Icons.delete_outline : Icons.movie,
              color: color),
          title: Text(
            phrase?.devanagari ?? phraseId,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              decoration: rejected ? TextDecoration.lineThrough : null,
            ),
          ),
          subtitle: Text(
            '${phrase == null ? phraseId : phraseMeaning(phrase)} · '
            '${tr('mine_take')} ${clip['take'] ?? 1}',
            style: const TextStyle(fontSize: 12),
          ),
          trailing: Text(
            rejected
                ? tr('mine_removed')
                : uploaded
                    ? tr('mine_kept')
                    : tr('mine_uploading'),
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: color),
          ),
        ),
      ),
    );
  }
}
