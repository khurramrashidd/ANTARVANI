import 'package:flutter/material.dart';

import '../../app/l10n.dart';
import '../../services/speech_service.dart';

/// Type anything; the phone reads it aloud in the chosen voice.
class TypeScreen extends StatefulWidget {
  const TypeScreen({super.key});

  @override
  State<TypeScreen> createState() => _TypeScreenState();
}

class _TypeScreenState extends State<TypeScreen> {
  final _ctrl = TextEditingController();
  late String _voice = ttsLangForUi;

  static const _voices = {'hi-IN': 'हिन्दी', 'mr-IN': 'मराठी', 'en-IN': 'English'};

  static const _quick = {
    'en-IN': ['Hello', 'Thank you', 'Please', 'Sorry', 'Come here', 'Later'],
    'hi-IN': ['नमस्ते', 'धन्यवाद', 'कृपया', 'माफ़ कीजिए', 'यहाँ आओ', 'बाद में'],
    'mr-IN': ['नमस्कार', 'धन्यवाद', 'कृपया', 'माफ करा', 'इकडे या', 'नंतर'],
  };

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _speak() => SpeechService.instance
      .say(_ctrl.text.trim(), lang: _voice, source: 'type');

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        TextField(
          controller: _ctrl,
          minLines: 4,
          maxLines: 8,
          style: const TextStyle(fontSize: 22, height: 1.35),
          decoration: InputDecoration(hintText: tr('type_hint')),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text('${tr('voice_lang')}:  '),
            Expanded(
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: _voices.entries
                    .map((e) => ButtonSegment(value: e.key, label: Text(e.value)))
                    .toList(),
                selected: {_voice},
                onSelectionChanged: (s) => setState(() => _voice = s.first),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52)),
                onPressed: () => setState(_ctrl.clear),
                icon: const Icon(Icons.backspace_outlined),
                label: Text(tr('type_clear')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: _speak,
                icon: const Icon(Icons.volume_up),
                label: Text(tr('type_speak')),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text(tr('type_quick'), style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final w in _quick[_voice]!)
              ActionChip(
                label: Text(w, style: const TextStyle(fontSize: 16)),
                onPressed: () {
                  final t = _ctrl.text.trim();
                  _ctrl.text = t.isEmpty ? w : '$t $w';
                  _ctrl.selection =
                      TextSelection.collapsed(offset: _ctrl.text.length);
                },
              ),
          ],
        ),
      ],
    );
  }
}
