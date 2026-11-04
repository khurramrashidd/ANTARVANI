import 'package:flutter/material.dart';

import '../models.dart';
import '../phrases.dart';
import '../services/sync_service.dart';

/// Fixes a speaker's details after the session — a misspelled name, the wrong
/// age band, a tick that was missed. Only the fields on this screen are
/// written, so nothing recorded by the phone is overwritten.
class SpeakerEditScreen extends StatefulWidget {
  final String speakerId;
  final Map<String, dynamic> existing;

  const SpeakerEditScreen({
    super.key,
    required this.speakerId,
    required this.existing,
  });

  @override
  State<SpeakerEditScreen> createState() => _SpeakerEditScreenState();
}

class _SpeakerEditScreenState extends State<SpeakerEditScreen> {
  late final SpeakerMeta _m = SpeakerMeta.fromMap(widget.existing);
  late final TextEditingController _name =
      TextEditingController(text: _m.name);
  late final TextEditingController _note =
      TextEditingController(text: _m.locationNote);
  bool _saving = false;

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
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final name = _name.text.trim();
    try {
      await SyncService.instance.updateSpeaker(widget.speakerId, {
        'name': name,
        'nameLower': name.toLowerCase(),
        'tier': _m.tier,
        'ageBand': _m.ageBand,
        'gender': _m.gender,
        'firstLanguage': _m.firstLanguage,
        'fluentHindi': _m.fluentHindi,
        'facialHair': _m.facialHair,
        'glasses': _m.glasses,
        'lighting': _m.lighting,
        'phoneMount': _m.phoneMount,
        'locationNote': _note.text.trim(),
        'consentGiven': _m.consentGiven,
        'consentToPublishDataset': _m.consentToPublishDataset,
        'adultConfirmed': _m.adultConfirmed,
        'targetClips': kPhrases.length * (_m.tier == 'B' ? Tier.b.takes : Tier.a.takes),
      });
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${widget.speakerId} updated')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Edit ${widget.speakerId}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Full name',
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 14),
          Text('Tier', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'A', label: Text('A · 1 take')),
              ButtonSegment(value: 'B', label: Text('B · 10 takes')),
            ],
            selected: {_m.tier == 'B' ? 'B' : 'A'},
            onSelectionChanged: (s) => setState(() => _m.tier = s.first),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 10),
            child: Text(
              'Changing the tier changes how many clips this speaker is '
              'expected to have, and so what "missing" means.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          _Chips('Age band', _ageBands, _m.ageBand,
              (v) => setState(() => _m.ageBand = v)),
          _Chips('Gender', _genders, _m.gender,
              (v) => setState(() => _m.gender = v)),
          _Chips('First language', _languages, _m.firstLanguage, (v) {
            setState(() {
              _m.firstLanguage = v;
              _m.fluentHindi = v == 'Hindi' || _m.fluentHindi;
            });
          }),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Fluent Hindi speaker'),
            value: _m.fluentHindi,
            onChanged: (v) => setState(() => _m.fluentHindi = v),
          ),
          _Chips('Facial hair', _facialHair, _m.facialHair,
              (v) => setState(() => _m.facialHair = v)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Wearing glasses'),
            value: _m.glasses,
            onChanged: (v) => setState(() => _m.glasses = v),
          ),
          _Chips('Lighting', _lighting, _m.lighting,
              (v) => setState(() => _m.lighting = v)),
          _Chips('Phone', _mounts, _m.phoneMount,
              (v) => setState(() => _m.phoneMount = v)),
          TextField(
            controller: _note,
            decoration: const InputDecoration(labelText: 'Location note'),
          ),
          const SizedBox(height: 16),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Speaker is 18 or older'),
            value: _m.adultConfirmed,
            onChanged: (v) => setState(() => _m.adultConfirmed = v ?? false),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Paper consent form signed'),
            value: _m.consentGiven,
            onChanged: (v) => setState(() => _m.consentGiven = v ?? false),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Agrees to dataset being published'),
            value: _m.consentToPublishDataset,
            onChanged: (v) =>
                setState(() => _m.consentToPublishDataset = v ?? false),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _saving || _name.text.trim().length < 2 ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save_outlined),
            label: Text(_saving ? 'Saving…' : 'Save changes'),
          ),
        ],
      ),
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
