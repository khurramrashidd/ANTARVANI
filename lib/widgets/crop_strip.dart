import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/model_service.dart';

/// The mouth frames exactly as the model received them.
///
/// A wrong answer has two very different causes — the model is weak, or the
/// crop missed the mouth — and no accuracy number tells them apart. Seeing
/// the strip does, in a second.
class CropStrip extends StatelessWidget {
  final Uint8List crops;
  final ModelCard card;
  final int show;

  const CropStrip({
    super.key,
    required this.crops,
    required this.card,
    this.show = 8,
  });

  Future<ui.Image?> _build() async {
    final n = card.size;
    final per = n * n;
    final total = crops.length ~/ per;
    if (total == 0) return null;
    final count = total < show ? total : show;

    // Pick evenly across the clip so the strip covers the whole phrase.
    final width = n * count;
    final rgba = Uint8List(width * n * 4);
    for (var c = 0; c < count; c++) {
      final frame = count == 1 ? 0 : (c * (total - 1) ~/ (count - 1));
      final base = frame * per;
      for (var y = 0; y < n; y++) {
        for (var x = 0; x < n; x++) {
          final g = crops[base + y * n + x];
          final o = ((y * width) + (c * n + x)) * 4;
          rgba[o] = g;
          rgba[o + 1] = g;
          rgba[o + 2] = g;
          rgba[o + 3] = 255;
        }
      }
    }

    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        rgba, width, n, ui.PixelFormat.rgba8888, done.complete);
    return done.future;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ui.Image?>(
        future: _build(),
        builder: (context, snap) {
          final img = snap.data;
          if (img == null) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('What the model saw',
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  height: 64,
                  width: double.infinity,
                  child: FittedBox(
                    fit: BoxFit.contain,
                    alignment: Alignment.centerLeft,
                    child: RawImage(image: img, filterQuality: FilterQuality.low),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Your mouth should sit in the middle of each square and fill '
                'most of it. If it does not, the crop is wrong, not the model.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          );
        },
      );
}
