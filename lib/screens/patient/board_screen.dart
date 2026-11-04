import 'package:flutter/material.dart';

import '../../app/l10n.dart';
import '../../app/theme.dart';
import '../../phrases.dart';
import '../../services/speech_service.dart';

/// The 20 phrases as big buttons. Tap = the phone says it in Hindi.
/// Works today, with or without the model — the fallback when the camera
/// cannot be used.
class BoardScreen extends StatefulWidget {
  const BoardScreen({super.key});

  static const urgent = {'P02', 'P03', 'P12', 'P14'};

  static const icons = <String, IconData>{
    'P01': Icons.water_drop,
    'P02': Icons.sick,
    'P03': Icons.medical_services,
    'P04': Icons.restaurant,
    'P05': Icons.wc,
    'P06': Icons.air,
    'P07': Icons.lightbulb_outline,
    'P08': Icons.ac_unit,
    'P09': Icons.airline_seat_recline_normal,
    'P10': Icons.medication,
    'P11': Icons.bedtime,
    'P12': Icons.monitor_heart,
    'P13': Icons.home,
    'P14': Icons.record_voice_over,
    'P15': Icons.check_circle,
    'P16': Icons.cancel,
    'P17': Icons.favorite,
    'P18': Icons.pan_tool,
    'P19': Icons.window,
    'P20': Icons.bed,
  };

  @override
  State<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends State<BoardScreen> {
  String _q = '';

  bool _match(Phrase p) {
    if (_q.isEmpty) return true;
    final q = _q.toLowerCase();
    return p.devanagari.contains(_q) ||
        p.roman.toLowerCase().contains(q) ||
        p.english.toLowerCase().contains(q) ||
        phraseMeaning(p).toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final list = kPhrases.where(_match).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            onChanged: (v) => setState(() => _q = v.trim()),
            decoration: InputDecoration(
              hintText: tr('board_search'),
              prefixIcon: const Icon(Icons.search),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: Row(
            children: [
              const Icon(Icons.info_outline, size: 16),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(tr('board_tip'),
                      style: Theme.of(context).textTheme.bodySmall)),
            ],
          ),
        ),
        Expanded(
          child: AnimatedBuilder(
            animation: SpeechService.instance,
            builder: (context, _) => GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.05,
              ),
              itemCount: list.length,
              itemBuilder: (context, i) => _PhraseCard(phrase: list[i]),
            ),
          ),
        ),
      ],
    );
  }
}

class _PhraseCard extends StatelessWidget {
  final Phrase phrase;
  const _PhraseCard({required this.phrase});

  @override
  Widget build(BuildContext context) {
    final urgent = BoardScreen.urgent.contains(phrase.id);
    final color = urgent ? Brand.urgent : Brand.teal;
    final speaking = SpeechService.instance.speaking == phrase.devanagari;
    return Material(
      color: speaking
          ? color.withValues(alpha: 0.22)
          : Theme.of(context).cardTheme.color,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
            color: urgent ? color.withValues(alpha: 0.6) : Colors.transparent,
            width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => SpeechService.instance
            .say(phrase.devanagari, lang: 'hi-IN', source: 'board'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(BoardScreen.icons[phrase.id] ?? Icons.chat_bubble,
                      color: color, size: 28),
                  const Spacer(),
                  Icon(speaking ? Icons.volume_up : Icons.volume_up_outlined,
                      size: 20, color: color),
                ],
              ),
              const Spacer(),
              Text(phrase.devanagari,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 19, fontWeight: FontWeight.w800, height: 1.2)),
              const SizedBox(height: 4),
              Text(phraseMeaning(phrase),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
