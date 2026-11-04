import 'dart:math';
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Live quality control on the camera preview, entirely on-device.
///
/// Why the preview and not the recorded file: Android cannot reliably run a
/// frame stream and video recording at the same time, and extracting frames
/// from an MP4 in Flutter needs ffmpeg, whose free builds were retired. So we
/// gate on the preview instead, which is where framing problems actually show.
class FrameCheck {
  final bool faceFound;
  final double mouthWidth; // fraction of frame width
  final double centreOffset; // 0 = centred, 1 = at the edge
  final double lipAperture; // normalised by face width
  final String? problem; // null when the frame is good

  const FrameCheck({
    required this.faceFound,
    required this.mouthWidth,
    required this.centreOffset,
    required this.lipAperture,
    required this.problem,
  });

  bool get ok => problem == null;

  static const bad = FrameCheck(
    faceFound: false,
    mouthWidth: 0,
    centreOffset: 1,
    lipAperture: 0,
    problem: 'No face detected',
  );
}

class FaceQc {
  static const double minMouthWidth = 0.10; // phone too far away below this
  static const double maxCentreOffset = 0.30;
  static const double minMotion = 0.012; // std of lip aperture over a window

  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableContours: true,
      enableLandmarks: true,
    ),
  );

  bool _busy = false;

  void dispose() => _detector.close();

  /// Convert a camera frame to the format ML Kit wants. The controller must be
  /// created with `imageFormatGroup: ImageFormatGroup.nv21`, which gives a
  /// single-plane image ML Kit accepts directly.
  InputImage? _toInputImage(CameraImage image, CameraDescription cam) {
    final rotation =
        InputImageRotationValue.fromRawValue(cam.sensorOrientation);
    if (rotation == null || image.planes.isEmpty) return null;
    return InputImage.fromBytes(
      bytes: image.planes.first.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  /// Analyse one preview frame. Returns null if a check is already running —
  /// ML Kit is slower than the camera, so frames are deliberately dropped.
  Future<FrameCheck?> check(CameraImage image, CameraDescription cam) async {
    if (_busy) return null;
    _busy = true;
    try {
      final input = _toInputImage(image, cam);
      if (input == null) return FrameCheck.bad;
      final faces = await _detector.processImage(input);
      if (faces.isEmpty) return FrameCheck.bad;

      // Largest face wins — in a busy room there may be a passer-by.
      faces.sort((a, b) => (b.boundingBox.width * b.boundingBox.height)
          .compareTo(a.boundingBox.width * a.boundingBox.height));
      final f = faces.first;
      final frameW = image.width.toDouble();
      final frameH = image.height.toDouble();

      final upper = f.contours[FaceContourType.upperLipBottom]?.points;
      final lower = f.contours[FaceContourType.lowerLipTop]?.points;

      double mouthW;
      double aperture = 0;
      if (upper != null && upper.length > 2 && lower != null && lower.length > 2) {
        final xs = upper.map((p) => p.x.toDouble());
        mouthW = (xs.reduce(max) - xs.reduce(min)) / frameW;
        final uy = upper.map((p) => p.y.toDouble()).reduce((a, b) => a + b) /
            upper.length;
        final ly = lower.map((p) => p.y.toDouble()).reduce((a, b) => a + b) /
            lower.length;
        aperture = (ly - uy).abs() / max(f.boundingBox.width, 1);
      } else {
        // Contours unavailable on this frame — estimate from the face box.
        mouthW = f.boundingBox.width * 0.45 / frameW;
      }

      final cx = f.boundingBox.center.dx;
      final cy = f.boundingBox.center.dy;
      final offset = max(
        (cx - frameW / 2).abs() / (frameW / 2),
        (cy - frameH / 2).abs() / (frameH / 2),
      );

      String? problem;
      if (mouthW < minMouthWidth) {
        problem = 'Move the phone closer';
      } else if (offset > maxCentreOffset) {
        problem = 'Centre the face';
      } else if ((f.headEulerAngleY ?? 0).abs() > 20) {
        problem = 'Look straight at the camera';
      }

      return FrameCheck(
        faceFound: true,
        mouthWidth: mouthW,
        centreOffset: offset,
        lipAperture: aperture,
        problem: problem,
      );
    } catch (e) {
      debugPrint('FaceQc error: $e');
      return null;
    } finally {
      _busy = false;
    }
  }

  /// True when lip aperture varied enough across the window to count as
  /// visible articulation. Used once per session, not per clip.
  static bool motionDetected(List<double> apertures) {
    if (apertures.length < 8) return false;
    final mean = apertures.reduce((a, b) => a + b) / apertures.length;
    final variance = apertures
            .map((a) => (a - mean) * (a - mean))
            .reduce((a, b) => a + b) /
        apertures.length;
    return sqrt(variance) >= minMotion;
  }
}
