import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/theme.dart';
import '../models.dart';
import '../phrases.dart';
import '../services/id_allocator.dart';
import '../services/sync_service.dart';
import '../storage.dart';
import 'record_screen.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  SpeakerMeta _meta = SpeakerMeta();
  final _locationCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  Tier _tier = Tier.a;
  bool _demo = false;
  String _storagePath = '';
  bool _ready = false;
  bool _starting = false;

  static const _ageBands = ['18-25', '26-35', '36-50', '51-65', '65+'];
  static const _genders = ['Male', 'Female', 'Other', 'Prefer not to say'];
  static const _languages = [
    'Hindi', 'Marathi', 'Gujarati', 'Urdu', 'Bengali', 'English', 'Other'
  ];
  static const _facialHair = ['None', 'Stubble', 'Moustache', 'Beard'];
  static const _lighting = [
    'Daylight, bright', 'Indoor, bright', 'Indoor, dim', 'Mixed / backlit'
  ];
  static const _mounts = ['Propped / tripod', 'Handheld'];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _locationCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await [Permission.camera].request();
    _storagePath = await Storage.rootPathForDisplay();
    await _meta.fillAutoFields();
    if (mounted) setState(() => _ready = true);
  }

  /// What still has to be filled in. A grey button that will not say why is
  /// worse than no button at all, so the button always works and this list is
  /// what it shows when something is missing.
  List<String> get _missing => _demo
      ? const <String>[]
      : [
        if (_nameCtrl.text.trim().length < 2) 'the volunteer\'s full name',
        if (_meta.ageBand.isEmpty) 'age band',
        if (_meta.gender.isEmpty) 'gender',
        if (_meta.firstLanguage.isEmpty) 'first language',
        if (_meta.facialHair.isEmpty) 'facial hair',
        if (_meta.lighting.isEmpty) 'lighting',
        if (_meta.phoneMount.isEmpty) 'how the phone is held',
        if (!_meta.adultConfirmed) 'the tick: speaker is 18 or older',
        if (!_meta.consentGiven) 'the tick: paper consent form signed',
      ];

  bool get _complete => _missing.isEmpty;

  Future<void> _showMissing() async {
    final missing = _missing;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(missing.length == 1
            ? 'One thing left'
            : '${missing.length} things left'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Fill these in before recording:'),
            const SizedBox(height: 10),
            for (final m in missing)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('•  '),
                    Expanded(child: Text(m)),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _start() async {
    if (_starting) return;

    if (_demo) {
      // No number, no records, no upload. Just the camera.
      final meta = SpeakerMeta()
        ..speakerId = 'DEMO'
        ..consentFormId = 'DEMO'
        ..name = 'Demo'
        ..tier = _tier.code;
      await meta.fillAutoFields();
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => RecordScreen(
          meta: meta,
          takes: _tier.takes,
          demo: true,
          title: 'Demo finished',
        ),
      ));
      return;
    }

    setState(() => _starting = true);
    final SessionIds ids;
    try {
      ids = await IdAllocator.allocate(deviceId: SyncService.instance.deviceId);
    } catch (e) {
      if (mounted) {
        setState(() => _starting = false);
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('No speaker ID yet'),
            content: Text('$e'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c), child: const Text('OK')),
            ],
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() => _starting = false);

    // The number is now reserved for this person whatever happens next.
    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: const Text('Speaker number issued'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(ids.speakerId,
                style: const TextStyle(
                    fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: 2)),
            const SizedBox(height: 8),
            const Text('Write this on the paper consent form:'),
            Text(ids.formNo,
                style: const TextStyle(
                    fontSize: 32, fontWeight: FontWeight.w700, letterSpacing: 2)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel session'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('Written ${ids.formNo} — record'),
          ),
        ],
      ),
    );

    final sync = SyncService.instance;
    if (go != true) {
      // Nothing was recorded, so the number goes straight back into the pool
      // instead of sitting there as a dead "cancelled" row.
      await IdAllocator.release([ids.speakerId]);
      return;
    }

    _meta.speakerId = ids.speakerId;
    _meta.consentFormId = ids.formNo;
    _meta.tier = _tier.code;
    _meta.name = _nameCtrl.text.trim();
    _meta.locationNote = _locationCtrl.text.trim();
    await sync.saveSpeaker(_meta);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RecordScreen(meta: _meta, takes: _tier.takes),
    ));

    final wrote = await Storage.speakerHasClips(ids.speakerId);
    if (wrote) {
      await sync.setSpeakerStatus(ids.speakerId, 'complete');
    } else {
      // Walked away before the first clip — hand the number back.
      await IdAllocator.release([ids.speakerId]);
    }

    // Fresh form for the next volunteer; keep the conditions, they rarely change.
    final next = SpeakerMeta()
      ..lighting = _meta.lighting
      ..phoneMount = _meta.phoneMount;
    await next.fillAutoFields();
    _nameCtrl.clear();
    if (mounted) setState(() => _meta = next);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) return const Center(child: CircularProgressIndicator());

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const _DriveBanner(),
        _ModeSwitch(
          demo: _demo,
          onChanged: (v) => setState(() => _demo = v),
        ),
        if (!_demo) ...[
          const _Checklist(),
          const _NextIdCard(),
        ],
        const SizedBox(height: 12),
        if (!_demo) ...[
        const _Label('Tier'),
        SegmentedButton<Tier>(
          segments: const [
            ButtonSegment(value: Tier.a, label: Text('A · 1 take')),
            ButtonSegment(value: Tier.b, label: Text('B · 10 takes')),
          ],
          selected: {_tier},
          onSelectionChanged: (s) => setState(() => _tier = s.first),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            '${kPhrases.length * _tier.takes} clips · about '
            '${_tier == Tier.a ? 5 : 30} minutes'
            '${_tier == Tier.b ? " · for the personalisation study" : ""}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 16),
        const _Label('Speaker'),
        TextField(
          controller: _nameCtrl,
          textCapitalization: TextCapitalization.words,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Full name',
            hintText: 'as written on the consent form',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 10),
          child: Text(
            'Kept in the private project database so you can find this person '
            'again or honour a deletion request. Never published with the '
            'dataset.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        _Chips('Age band', _ageBands, _meta.ageBand,
            (v) => setState(() => _meta.ageBand = v)),
        _Chips('Gender', _genders, _meta.gender,
            (v) => setState(() => _meta.gender = v)),
        _Chips('First language', _languages, _meta.firstLanguage, (v) {
          setState(() {
            _meta.firstLanguage = v;
            _meta.fluentHindi = v == 'Hindi';
          });
        }),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Fluent Hindi speaker'),
          value: _meta.fluentHindi,
          onChanged: (v) => setState(() => _meta.fluentHindi = v),
        ),
        _Chips('Facial hair', _facialHair, _meta.facialHair,
            (v) => setState(() => _meta.facialHair = v)),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Wearing glasses'),
          value: _meta.glasses,
          onChanged: (v) => setState(() => _meta.glasses = v),
        ),
        const SizedBox(height: 8),
        const _Label('Conditions'),
        _Chips('Lighting', _lighting, _meta.lighting,
            (v) => setState(() => _meta.lighting = v)),
        _Chips('Phone', _mounts, _meta.phoneMount,
            (v) => setState(() => _meta.phoneMount = v)),
        TextField(
          controller: _locationCtrl,
          decoration: const InputDecoration(
            labelText: 'Location note',
            hintText: 'e.g. library seminar room, window on left',
          ),
        ),
        const SizedBox(height: 20),
        const _Label('Consent'),
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Read aloud to the volunteer:\n\n'
                  '"We will record short silent video clips of your face. '
                  'No audio is recorded. Your name is kept privately by our '
                  'team so we can find your clips again, and is never '
                  'published. You can stop at any time and ask us to delete '
                  'your clips."',
                  style: TextStyle(height: 1.4),
                ),
                const SizedBox(height: 10),
                const Text(
                  'The form number is issued when you press Start, and shown '
                  'big on screen to copy onto the paper form.',
                  style: TextStyle(fontSize: 12),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Speaker is 18 or older'),
                  subtitle: const Text(
                    'This study does not record anyone under 18. A minor needs '
                    'verifiable parental consent and separate ethics approval.',
                    style: TextStyle(fontSize: 11),
                  ),
                  value: _meta.adultConfirmed,
                  onChanged: (v) =>
                      setState(() => _meta.adultConfirmed = v ?? false),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Paper consent form signed'),
                  value: _meta.consentGiven,
                  onChanged: (v) =>
                      setState(() => _meta.consentGiven = v ?? false),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Agrees to dataset being published'),
                  value: _meta.consentToPublishDataset,
                  onChanged: (v) => setState(
                      () => _meta.consentToPublishDataset = v ?? false),
                ),
              ],
            ),
          ),
        ),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: _starting ? null : (_complete ? _start : _showMissing),
          icon: _starting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(_demo ? Icons.science_outlined : Icons.videocam),
          label: Text(_starting
              ? 'Getting speaker ID…'
              : _demo
                  ? 'Start demo'
                  : 'Start recording'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
        if (_missing.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Still to fill in: ${_missing.join(", ")}',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 14),
        Text('Saving to:\n$_storagePath',
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// Shows the next number the shared counter will issue. Only a preview —
/// the real number is reserved when Start is pressed.
/// Real or demo. A demo records nothing anywhere: no speaker number is taken,
/// no row is written, nothing reaches Drive, and each clip is deleted as soon
/// as it has been played back. For showing the app to your guide, or letting
/// a nervous volunteer try it once before the real thing.
class _ModeSwitch extends StatelessWidget {
  final bool demo;
  final ValueChanged<bool> onChanged;
  const _ModeSwitch({required this.demo, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: demo ? Brand.amber.withValues(alpha: 0.18) : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                      value: false,
                      icon: Icon(Icons.videocam),
                      label: Text('Real')),
                  ButtonSegment(
                      value: true,
                      icon: Icon(Icons.science_outlined),
                      label: Text('Demo')),
                ],
                selected: {demo},
                onSelectionChanged: (s) => onChanged(s.first),
              ),
              const SizedBox(height: 8),
              Text(
                demo
                    ? 'Practice run. No speaker number is used, nothing is '
                        'written to the shared records, and the clips are '
                        'deleted as you go. Safe to show anyone.'
                    : 'A real session. The clips become part of the dataset.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ticked once at the start of a recording day. Nothing here blocks you — it
/// is the list of things that, forgotten, waste a volunteer's time: a flat
/// battery halfway through, no paper forms, a phone with no room left.
class _Checklist extends StatefulWidget {
  const _Checklist();

  @override
  State<_Checklist> createState() => _ChecklistState();
}

class _ChecklistState extends State<_Checklist> {
  static const _items = [
    ('Phone charged above 50%', Icons.battery_charging_full),
    ('Paper consent forms and a pen ready', Icons.description_outlined),
    ('Phone propped at eye level, not handheld', Icons.stay_primary_portrait),
    ('Light on the face, not behind it', Icons.wb_sunny_outlined),
    ('Quiet spot where they can mouth words without feeling watched',
        Icons.volume_off_outlined),
  ];

  static const _key = 'checklist_day';

  Set<int> _done = {};
  bool _loaded = false;
  bool _open = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static String get _today {
    final d = DateTime.now();
    return '${d.year}-${d.month}-${d.day}';
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getStringList(_key) ?? const [];
    // First entry is the day it was ticked; a new day starts fresh.
    final fresh = saved.isNotEmpty && saved.first == _today;
    if (!mounted) return;
    setState(() {
      _done = fresh ? saved.skip(1).map(int.parse).toSet() : {};
      _loaded = true;
      _open = _done.length < _items.length;
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
        _key, [_today, ..._done.map((e) => '$e')]);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final all = _done.length == _items.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: all
            ? null
            : Theme.of(context).colorScheme.tertiaryContainer.withValues(alpha: 0.5),
        child: Column(
          children: [
            ListTile(
              dense: true,
              leading: Icon(all ? Icons.task_alt : Icons.checklist,
                  color: all ? const Color(0xFF2E7D32) : null),
              title: Text(
                all
                    ? 'Ready to record'
                    : 'Before you start — ${_done.length}/${_items.length}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              trailing: Icon(_open ? Icons.expand_less : Icons.expand_more),
              onTap: () => setState(() => _open = !_open),
            ),
            if (_open)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Column(
                  children: [
                    for (var i = 0; i < _items.length; i++)
                      CheckboxListTile(
                        dense: true,
                        value: _done.contains(i),
                        onChanged: (v) {
                          setState(() {
                            if (v == true) {
                              _done.add(i);
                            } else {
                              _done.remove(i);
                            }
                            if (_done.length == _items.length) _open = false;
                          });
                          _save();
                        },
                        secondary: Icon(_items[i].$2, size: 20),
                        title: Text(_items[i].$1,
                            style: const TextStyle(fontSize: 13)),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The number the next volunteer will get. Recycled numbers come first, so
/// an abandoned session leaves no hole in the set.
class _NextIdCard extends StatelessWidget {
  const _NextIdCard();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SessionIds?>(
      stream: IdAllocator.watchNext(),
      builder: (context, nextSnap) {
        final next = nextSnap.data;
        return StreamBuilder<List<int>>(
          stream: IdAllocator.watchFree(),
          builder: (context, freeSnap) {
            final free = freeSnap.data ?? const <int>[];
            final recycled = next != null && free.contains(next.number);
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Next speaker',
                                  style: Theme.of(context).textTheme.bodySmall),
                              Text(next?.speakerId ?? '—',
                                  style: const TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.bold)),
                              Text('form ${next?.formNo ?? "—"} · issued on Start',
                                  style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                        StreamBuilder<int>(
                          stream: IdAllocator.watchIssued(),
                          builder: (context, issued) => Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text('${issued.data ?? 0}',
                                  style: const TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.bold)),
                              Text('issued, all collectors',
                                  style: Theme.of(context).textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (recycled)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Reusing ${next.speakerId} — an earlier session with '
                          'that number recorded nothing, so the number went '
                          'back into the pool.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Tells a collector when clips cannot reach Drive yet, with the fix.
class _DriveBanner extends StatelessWidget {
  const _DriveBanner();

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.instance;
    return AnimatedBuilder(
      animation: sync,
      builder: (context, _) {
        final d = sync.drive;
        if (d.signedIn && d.corpusWritable == true) {
          return const SizedBox.shrink();
        }
        final scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Card(
            color: scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.cloud_off, color: scheme.onErrorContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      d.signedIn
                          ? (d.lastError ?? 'No access to the corpus folder.')
                          : 'Drive not connected. Clips are kept on this '
                              'phone until you connect.',
                      style: TextStyle(color: scheme.onErrorContainer),
                    ),
                  ),
                  if (!d.signedIn)
                    TextButton(
                      onPressed: () => sync.connectDrive(),
                      child: const Text('Connect'),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 6),
        child: Text(text.toUpperCase(),
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(letterSpacing: 1.1)),
      );
}

class _Chips extends StatelessWidget {
  final String label;
  final List<String> options;
  final String value;
  final ValueChanged<String> onPick;
  const _Chips(this.label, this.options, this.value, this.onPick);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              children: options
                  .map((o) => ChoiceChip(
                        label: Text(o),
                        selected: value == o,
                        onSelected: (_) => onPick(o),
                      ))
                  .toList(),
            ),
          ],
        ),
      );
}
