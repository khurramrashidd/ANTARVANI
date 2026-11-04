import 'package:flutter/material.dart';

import '../../app/l10n.dart';
import '../../services/speech_service.dart';

/// What the patient said, newest first. Tap to say it again.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  @override
  void initState() {
    super.initState();
    SpeechService.instance.ensureLoaded();
  }

  static String _time(DateTime t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  static IconData _icon(String source) => switch (source) {
        'type' => Icons.keyboard,
        'quick' => Icons.bolt,
        'speak' => Icons.record_voice_over,
        _ => Icons.grid_view,
      };

  @override
  Widget build(BuildContext context) {
    final s = SpeechService.instance;
    return AnimatedBuilder(
      animation: s,
      builder: (context, _) {
        final items = s.history;
        if (items.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.history, size: 56),
                  const SizedBox(height: 12),
                  Text(tr('hist_empty'), textAlign: TextAlign.center),
                ],
              ),
            ),
          );
        }
        final now = DateTime.now();
        bool isToday(DateTime d) =>
            d.year == now.year && d.month == now.month && d.day == now.day;

        final rows = <Widget>[];
        String? lastHeader;
        for (final it in items) {
          final header = isToday(it.at) ? tr('hist_today') : tr('hist_earlier');
          if (header != lastHeader) {
            rows.add(Padding(
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
              child: Text(header,
                  style: Theme.of(context).textTheme.titleSmall),
            ));
            lastHeader = header;
          }
          rows.add(Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              child: ListTile(
                leading: Icon(_icon(it.source)),
                title: Text(it.text,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600)),
                subtitle: Text(isToday(it.at)
                    ? _time(it.at)
                    : '${it.at.day} ${months[it.at.month - 1]} · ${_time(it.at)}'),
                trailing: IconButton(
                  icon: const Icon(Icons.replay),
                  onPressed: () =>
                      s.say(it.text, lang: it.lang, source: it.source),
                ),
              ),
            ),
          ));
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          children: [
            ...rows,
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: s.clearHistory,
              icon: const Icon(Icons.delete_outline),
              label: Text(tr('hist_clear')),
            ),
          ],
        );
      },
    );
  }
}
