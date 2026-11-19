import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'lip_reader.dart';

/// Reads frames back out of a recorded video, through the Kotlin in
/// `android/app/.../FrameExtractor.kt`.
///
/// Recognition used to run on frames grabbed from the live preview. Reading
/// the recorded file instead means Speak sees the same thing the training
/// clips were made from — same camera path, same resolution, same encoder —
/// rather than a lower-resolution preview stream that some phones hand over
/// in a different format entirely.
///
/// Everything here returns null rather than throwing. The caller falls back
/// to the live preview, so a phone where this does not work behaves as it
/// did before instead of losing Speak altogether.
class VideoFrames {
  static const MethodChannel _channel = MethodChannel('antarvani/frames');

  static bool _unavailable = false;

  /// True once the native side has been found missing, so later attempts
  /// skip straight to the fallback instead of failing again.
  static bool get unavailable => _unavailable;

  /// Asks the native side whether it is there, before anything is recorded.
  ///
  /// Without this the first attempt on a phone with no native half would
  /// count down, record, fail, and then count down again for the fallback.
  /// `close` with nothing open is a no-op, so it is a safe thing to ask.
  static Future<bool> probe() async {
    if (_unavailable) return false;
    try {
      await _channel.invokeMethod('close');
      return true;
    } on MissingPluginException {
      _unavailable = true;
      debugPrint('video frames: native side not present, using live preview');
      return false;
    } catch (_) {
      // It answered, which is all this needed to know.
      return true;
    }
  }

  static Future<(List<RawFrame>, int)?> read(
    String path, {
    required int count,
    required int stepMs,
    int startMs = 0,
    int maxWidth = 480,
    void Function(double)? onProgress,
  }) async {
    if (_unavailable) return null;
    var opened = false;
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>('open', {
        'path': path,
        'count': count,
        'stepMs': stepMs,
        'startMs': startMs,
        'maxWidth': maxWidth,
      });
      if (info == null) return null;
      opened = true;

      final w = (info['width'] as num?)?.toInt() ?? 0;
      final h = (info['height'] as num?)?.toInt() ?? 0;
      if (w < 2 || h < 2) return null;

      final frames = <RawFrame>[];
      for (var i = 0; i < count; i++) {
        final bytes =
            await _channel.invokeMethod<Uint8List>('frame', {'index': i});
        if (bytes == null || bytes.length < w * h) break;
        // Packed by the Kotlin side, so a row is exactly the width.
        frames.add(RawFrame(bytes, w, h, w));
        onProgress?.call((i + 1) / count);
      }
      if (frames.length < count ~/ 2) return null;

      // The retriever turns the frame upright itself, so there is no further
      // rotation for the cropper to undo.
      return (frames, 0);
    } on MissingPluginException {
      // An older build without the Kotlin half.
      _unavailable = true;
      debugPrint('video frames: native side not present, using live preview');
      return null;
    } catch (e) {
      debugPrint('video frames failed: $e');
      return null;
    } finally {
      if (opened) {
        try {
          await _channel.invokeMethod('close');
        } catch (_) {}
      }
    }
  }
}
