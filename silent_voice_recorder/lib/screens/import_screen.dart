import 'package:flutter/material.dart';

import '../models.dart';
import '../phrases.dart';
import '../services/drive_uploader.dart';
import '../services/id_allocator.dart';
import '../services/sync_service.dart';
import '../services/team.dart';

/// Adopts videos that were put into the Drive corpus folder by hand, before
/// the app existed.
///
/// It scans P01..P20, offers every file that is not already named the way the
/// app names things, issues one speaker ID and form number for the batch,
/// renames the files in Drive to Sxxx_Pyy_t01.mp4, and writes the Firestore
/// rows — so imported clips appear in the dashboard exactly like recorded
/// ones, and the training pipeline reads them without any special case.
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final _meta = SpeakerMeta();
  final _noteCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();

  bool _scanning = false;
  bool _scanned = false;
  bool _importing = false;
  String _status = '';
  String? _error;

  /// phraseId -> the file chosen for it (one take per phrase).
  final Map<String, DriveClip> _chosen = {};
  List<DriveClip> _found = const [];
  int _alreadyNamed = 0;
  SessionIds? _issued;

  static const _ageBands = ['18-25', '26-35', '36-50', '51-65', '65+'];
  static const _genders = ['Male', 'Female', 'Other', 'Prefer not to say'];

  @override
  void initState() {
    super.initState();
    _meta.fillAutoFields();
    _meta.tier = 'A';
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- scanning
  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
      _status = 'Looking in the Drive corpus folder…';
    });
    final sync = SyncService.instance;
    if (!sync.drive.signedIn && !await sync.connectDrive()) {
      setState(() {
        _scanning = false;
        _error = sync.drive.lastError ?? 'Could not connect to Drive.';
      });
      return;
    }
    try {
      final all = await sync.drive.scanCorpus(kPhrases.map((p) => p.id).toList());
      final loose = all.where((c) => !c.isAppNamed).toList();

      // One per phrase: if a folder holds several hand-made files, take the
      // oldest, which is almost always the original.
      final byPhrase = <String, DriveClip>{};
      for (final c in loose) {
        final existing = byPhrase[c.phraseId];
        if (existing == null ||
            (c.createdTime != null &&
                existing.createdTime != null &&
                c.createdTime!.isBefore(existing.createdTime!))) {
          byPhrase[c.phraseId] = c;
        }
      }
      setState(() {
        _found = loose;
        _alreadyNamed = all.length - loose.length;
        _chosen
          ..clear()
          ..addAll(byPhrase);
        _scanning = false;
        _scanned = true;
        _status = '';
      });
    } catch (e) {
      setState(() {
        _scanning = false;
        _error = 'Scan failed: $e';
      });
    }
  }

  bool get _ready =>
      _chosen.isNotEmpty &&
      _nameCtrl.text.trim().length >= 2 &&
      _meta.ageBand.isNotEmpty &&
      _meta.gender.isNotEmpty &&
      _meta.consentGiven &&
      _meta.adultConfirmed;

  // ------------------------------------------------------------ importing
  Future<void> _import() async {
    setState(() {
      _importing = true;
      _error = null;
    });
    final sync = SyncService.instance;

    final SessionIds ids;
    try {
      ids = await IdAllocator.allocate(deviceId: sync.deviceId);
    } catch (e) {
      setState(() {
        _importing = false;
        _error = '$e';
      });
      return;
    }

    _meta.speakerId = ids.speakerId;
    _meta.consentFormId = ids.formNo;
    _meta.name = _nameCtrl.text.trim();
    _meta.locationNote = _noteCtrl.text.trim();
    _meta.tier = 'A';
    await sync.saveSpeaker(_meta);

    final entries = _chosen.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    var done = 0;
    var failed = 0;

    for (final e in entries) {
      final phraseId = e.key;
      final clip = e.value;
      final label = kPhrases.indexWhere((p) => p.id == phraseId);
      final docId = '${ids.speakerId}_${phraseId}_t01';
      // Keep whatever extension the file actually has — .mov and .3gp are
      // just as readable by the pipeline, and renaming a .mov to .mp4 would
      // be a lie that breaks players later.
      final fileName = '$docId${_extensionOf(clip.name)}';

      setState(() => _status = 'Importing $phraseId (${done + 1}/${entries.length})…');

      final renamed = await sync.drive.rename(clip.fileId, fileName);
      if (!renamed) failed++;

      await sync.registerImportedClip({
        'docId': docId,
        'speakerId': ids.speakerId,
        'phraseId': phraseId,
        'label': label,
        'take': 1,
        'deviceId': 'imported',
        'retakes': 0,
        'capturedUtc': (clip.createdTime ?? DateTime.now())
            .toUtc()
            .toIso8601String(),
        'qcVerdict': 'pass',
        'qcFaceScore': 1.0,
        'qcMouthWidth': 0.0,
        'qcOverride': false,
        'fileBytes': clip.bytes,
        'fileName': renamed ? fileName : clip.name,
        'originalFileName': clip.name,
        'source': 'import',
        'status': 'ok',
        'uploaded': true,
        'driveFileId': clip.fileId,
        'importedBy': Team.email,
      });
      done++;
    }

    await sync.setSpeakerStatus(ids.speakerId, 'complete');

    if (!mounted) return;
    setState(() {
      _importing = false;
      _issued = ids;
      _status = failed == 0
          ? '$done clips imported.'
          : '$done clips imported, $failed could not be renamed in Drive '
              '(they are still registered under their old names).';
    });
  }

  /// '.mp4' from 'VID_20261018.mp4'. Falls back to .mp4 when a file has no
  /// extension at all, and refuses anything that is not a known video type.
  static String _extensionOf(String name) {
    const known = {'.mp4', '.mov', '.3gp', '.mkv', '.avi', '.webm', '.m4v'};
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '.mp4';
    final ext = name.substring(dot).toLowerCase();
    return known.contains(ext) ? ext : '.mp4';
  }

  // ----------------------------------------------------------------- view
  @override
  Widget build(BuildContext context) {
    if (_issued != null) return _doneView();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Clips already in Drive',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Finds the videos you put into P01–P20 by hand, gives them '
                  'one speaker ID and form number, renames them to the '
                  'standard name, and adds them to the dashboard. One take '
                  'per phrase.',
                  style: TextStyle(height: 1.4),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _scanning || _importing ? null : _scan,
                  icon: _scanning
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.search),
                  label: Text(_scanned ? 'Scan again' : 'Scan Drive'),
                ),
              ],
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(_error!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer)),
            ),
          ),
        ],
        if (_status.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(_status, style: Theme.of(context).textTheme.bodyMedium),
        ],
        if (_scanned) ...[
          const SizedBox(height: 16),
          _ScanSummary(
            phrases: _chosen.length,
            loose: _found.length,
            alreadyNamed: _alreadyNamed,
          ),
          const SizedBox(height: 12),
          _PhraseGrid(chosen: _chosen),
          if (_chosen.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Text('Who is in these clips?',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            TextField(
              controller: _nameCtrl,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Full name',
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 12),
            _Chips('Age band', _ageBands, _meta.ageBand,
                (v) => setState(() => _meta.ageBand = v)),
            _Chips('Gender', _genders, _meta.gender,
                (v) => setState(() => _meta.gender = v)),
            TextField(
              controller: _noteCtrl,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                hintText: 'e.g. pilot recordings, home, October',
              ),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _meta.adultConfirmed,
              onChanged: (v) =>
                  setState(() => _meta.adultConfirmed = v ?? false),
              title: const Text('Speaker is 18 or older'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _meta.consentGiven,
              onChanged: (v) => setState(() => _meta.consentGiven = v ?? false),
              title: const Text('Paper consent form signed'),
              subtitle: const Text(
                'Write the form number shown after the import on that form.',
                style: TextStyle(fontSize: 11),
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _meta.consentToPublishDataset,
              onChanged: (v) =>
                  setState(() => _meta.consentToPublishDataset = v ?? false),
              title: const Text('Agrees to dataset being published'),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _ready && !_importing ? _import : null,
              icon: _importing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.download_done),
              label: Text(_importing
                  ? 'Importing…'
                  : 'Import ${_chosen.length} clips as one speaker'),
            ),
          ],
        ],
      ],
    );
  }

  Widget _doneView() {
    final ids = _issued!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      children: [
        const Icon(Icons.check_circle, size: 72, color: Color(0xFF2E7D32)),
        const SizedBox(height: 16),
        Text(_status,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text('Speaker ID',
                    style: Theme.of(context).textTheme.bodySmall),
                Text(ids.speakerId,
                    style: const TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2)),
                const SizedBox(height: 14),
                const Text('Write this on the signed paper form:'),
                Text(ids.formNo,
                    style: const TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        OutlinedButton(
          onPressed: () => setState(() {
            _issued = null;
            _scanned = false;
            _chosen.clear();
            _found = const [];
            _status = '';
          }),
          child: const Text('Import another set'),
        ),
      ],
    );
  }
}

class _ScanSummary extends StatelessWidget {
  final int phrases;
  final int loose;
  final int alreadyNamed;

  const _ScanSummary({
    required this.phrases,
    required this.loose,
    required this.alreadyNamed,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              phrases == 0
                  ? 'Nothing new to import'
                  : '$phrases phrases ready to import',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              phrases == 0
                  ? 'Every video in P01–P20 is already registered in the app.'
                  : '$loose unregistered files found; the oldest one in each '
                      'phrase folder is used. $alreadyNamed files are already '
                      'registered and were left alone.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _PhraseGrid extends StatelessWidget {
  final Map<String, DriveClip> chosen;
  const _PhraseGrid({required this.chosen});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final p in kPhrases)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: chosen.containsKey(p.id)
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  chosen.containsKey(p.id)
                      ? Icons.check_circle
                      : Icons.remove_circle_outline,
                  size: 15,
                  color: chosen.containsKey(p.id)
                      ? scheme.onPrimaryContainer
                      : scheme.outline,
                ),
                const SizedBox(width: 5),
                Text(p.id,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: chosen.containsKey(p.id)
                          ? scheme.onPrimaryContainer
                          : scheme.outline,
                    )),
              ],
            ),
          ),
      ],
    );
  }
}

class _Chips extends StatelessWidget {
  final String label;
  final List<String> options;
  final String value;
  final ValueChanged<String> onPick;
  const _Chips(this.label, this.options, this.value, this.onPick);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
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
