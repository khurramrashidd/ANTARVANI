import 'package:flutter/material.dart';

import '../../app/l10n.dart';
import '../../app/theme.dart';
import '../../widgets/common.dart';

/// Silent speech: the camera watches the lips, the model names the phrase,
/// the phone says it aloud. Layout is final; recognition arrives with the
/// trained TFLite model.
class SpeakScreen extends StatelessWidget {
  const SpeakScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Text(tr('speak_hint'), style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 16),
        // Camera area with the lip guide
        AspectRatio(
          aspectRatio: 3 / 4,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0D1433),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(Icons.face_outlined,
                    size: 160, color: Colors.white.withValues(alpha: 0.10)),
                // Lip frame
                Positioned(
                  bottom: 120,
                  child: Container(
                    width: 170,
                    height: 90,
                    decoration: BoxDecoration(
                      border: Border.all(color: Brand.amber, width: 3),
                      borderRadius: BorderRadius.circular(45),
                    ),
                  ),
                ),
                Positioned(
                  top: 16,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(tr('speak_waiting'),
                        style: const TextStyle(color: Colors.white)),
                  ),
                ),
                const Positioned(top: 16, right: 16, child: ComingSoonChip()),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Result card
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('speak_result'),
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 8),
                Text('—',
                    style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface)),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: const LinearProgressIndicator(value: 0, minHeight: 8),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(tr('speak_soon')))),
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(tr('speak_start')),
        ),
        const SizedBox(height: 10),
        Text(tr('speak_soon'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
