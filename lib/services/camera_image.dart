import 'dart:typed_data';

import 'package:camera/camera.dart';

/// One camera frame packed the way ML Kit wants it.
class Nv21Frame {
  final Uint8List bytes;
  final int width;
  final int height;

  /// Always equal to [width]: the buffer below is packed tightly, with no
  /// padding at the end of a row.
  int get rowStride => width;

  const Nv21Frame(this.bytes, this.width, this.height);
}

/// Turns a camera frame into real NV21 bytes.
///
/// This is the bug that made the face check useless. The controller asks for
/// `ImageFormatGroup.nv21`, but the CameraX implementation — the default on
/// Android now — ignores that and delivers YUV_420_888 in three planes.
/// Handing ML Kit `planes.first.bytes` then passes only the luminance plane
/// while declaring it to be full NV21, which is two thirds of the bytes the
/// format promises. ML Kit throws on it, the error is swallowed, and every
/// clip ends up recorded with a face score of zero: not "no face found", but
/// "never actually looked".
///
/// So the planes are packed here instead of being trusted:
///   * one plane  -> already NV21, only the row padding needs removing
///   * three      -> copy Y row by row, then interleave V and U
Uint8List toNv21(CameraImage image) {
  final width = image.width;
  final height = image.height;
  final planes = image.planes;

  final ySize = width * height;
  final uvHeight = (height + 1) ~/ 2;
  final uvWidth = (width + 1) ~/ 2;
  final out = Uint8List(ySize + 2 * uvWidth * uvHeight);

  // ---- luminance, one row at a time so any row padding is dropped
  final y = planes[0];
  final yStride = y.bytesPerRow;
  var o = 0;
  if (yStride == width) {
    out.setRange(0, ySize, y.bytes);
    o = ySize;
  } else {
    for (var row = 0; row < height; row++) {
      final start = row * yStride;
      out.setRange(o, o + width, y.bytes, start);
      o += width;
    }
  }

  if (planes.length == 1) {
    // Genuinely NV21 already: the colour half follows the luminance.
    final rest = y.bytes.length - height * yStride;
    if (rest > 0) {
      final take = rest < out.length - o ? rest : out.length - o;
      out.setRange(o, o + take, y.bytes, height * yStride);
    }
    return out;
  }

  // ---- colour: NV21 wants V then U, interleaved, at half resolution
  final u = planes[1];
  final v = planes[2];
  final uvRowStride = u.bytesPerRow;
  final uvPixelStride = u.bytesPerPixel ?? 1;
  for (var row = 0; row < uvHeight; row++) {
    for (var col = 0; col < uvWidth; col++) {
      final i = row * uvRowStride + col * uvPixelStride;
      if (i < v.bytes.length) out[o++] = v.bytes[i];
      if (i < u.bytes.length) out[o++] = u.bytes[i];
      if (o >= out.length) return out;
    }
  }
  return out;
}

Nv21Frame nv21FrameOf(CameraImage image) =>
    Nv21Frame(toNv21(image), image.width, image.height);
