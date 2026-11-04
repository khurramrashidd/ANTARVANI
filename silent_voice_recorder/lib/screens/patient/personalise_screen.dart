import 'package:flutter/material.dart';

import '../../app/l10n.dart';
import '../../app/theme.dart';
import '../../phrases.dart';
import '../../widgets/common.dart';

/// Few-shot personalisation — the research contribution. The patient records
/// a few samples per phrase and the model adapts to their lips. Layout now;
/// recording + on-device adaptation arrive with the model.
class PersonaliseScreen extends StatelessWidget {
  const PersonaliseScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const learned = 0;
    final total = kPhrases.length;
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
                          value: learned / total,
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
                      const ComingSoonChip(),
                      const SizedBox(height: 8),
                      Text(trf('pers_progress', {'n': learned, 't': total}),
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(tr('pers_body'),
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.4)),
        const SizedBox(height: 16),
        for (final (i, key) in const [
          (1, 'pers_step1'),
          (2, 'pers_step2'),
          (3, 'pers_step3'),
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: Brand.indigo,
                  child: Text('$i',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(tr(key))),
              ],
            ),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: null,
          icon: const Icon(Icons.fiber_manual_record),
          label: Text(tr('pers_start')),
        ),
      ],
    );
  }
}
