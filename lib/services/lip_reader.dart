import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'model_service.dart';

/// One camera frame kept for recognition: the NV21 bytes as they came off
/// the sensor (not yet turned upright).
class RawFrame {
  final Uint8List nv21;
  final int width;
  final int height;
  final int rowStride;
  const RawFrame(this.nv21, this.width, this.height, this.rowStride);
}

/// What the model said about one clip.
class LipResult {
  /// Probability per phrase, in label order.
  final Float32List probs;

  /// The clip's fingerprint, used for personalisation.
  final Float32List embedding;

  const LipResult(this.probs, this.embedding);

  /// Phrase indices, most likely first.
  List<int> get ranked {
    final idx = List<int>.generate(probs.length, (i) => i);
    idx.sort((a, b) => probs[b].compareTo(probs[a]));
    return idx;
  }
}

/// Where the mouth is in one upright frame.
class _Pose {
  final double mx, my; // mouth centre
  final double box; // crop side in source pixels
  final double theta; // tilt of the eye line
  const _Pose(this.mx, this.my, this.box, this.theta);

  static _Pose lerp(_Pose a, _Pose b, double t) => _Pose(
        a.mx + (b.mx - a.mx) * t,
        a.my + (b.my - a.my) * t,
        a.box + (b.box - a.box) * t,
        a.theta + (b.theta - a.theta) * t,
      );
}

/// Camera frames in, phrase probabilities out — all on the phone.
///
/// The crop made here must be the crop the model was trained on, or accuracy
/// falls for no visible reason. So this mirrors `antarvani_pipeline.py` step
/// for step: find the outer eye corners and the mouth corners, turn the face
/// so the eyes are level, cut a square centred on the mouth whose side is the
/// eye distance times `eyeBoxScale`, shrink to `size` x `size` greyscale.
/// The numbers come from the model card, so a retrained model that changes
/// them changes this too.
class LipReader {
  static final LipReader instance = LipReader._();
  LipReader._();

  /// ML Kit's eye landmarks are eye centres; training used the outer
  /// corners. Used only when the eye contour is missing on a frame.
  static const double _centreToCorner = 1.43;

  /// Run the face detector on every Nth frame and glide between them.
  static const int _detectEvery = 3;

  final FaceDetector _faces = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableContours: true,
      enableLandmarks: true,
    ),
  );

  Interpreter? _interp;
  ModelCard? _card;
  int _probsOut = 0;
  int _embOut = 1;

  ModelCard? get card => _card;

  /// Loads (or reloads, after a model update) the interpreter. Returns null
  /// when ready, or a message.
  Future<String?> ensureLoaded() async {
    final want = ModelService.instance.current;
    if (want == null) return 'no-model';
    if (_interp != null &&
        _card?.lang == want.lang &&
        _card?.version == want.version) {
      return null;
    }
    try {
      _interp?.close();
      _interp = null;
      final file = await ModelService.instance.fileFor(want.lang);
      final interp = Interpreter.fromFile(file,
          options: InterpreterOptions()..threads = 4);
      final inShape = interp.getInputTensor(0).shape;
      final wantShape = [1, want.frames, want.size, want.size, 1];
      if (!listEquals(inShape, wantShape) ||
          interp.getInputTensor(0).type != TensorType.float32) {
        interp.close();
        return 'This model expects $inShape, the app makes $wantShape.';
      }
      final outs = interp.getOutputTensors();
      final p = outs.indexWhere((t) => t.shape.last == want.labels.length);
      if (p < 0 || outs.length < 2) {
        interp.close();
        return 'This model does not have the two outputs the app needs.';
      }
      _probsOut = p;
      _embOut = p == 0 ? 1 : 0;
      _interp = interp;
      _card = want;
      return null;
    } catch (e) {
      debugPrint('model load failed: $e');
      return 'Could not load the model: $e';
    }
  }

  // ----------------------------------------------------------- the crop
  static _Pose? _poseOf(Face f) {
    math.Point<int>? lm(FaceLandmarkType t) => f.landmarks[t]?.position;

    final ml = lm(FaceLandmarkType.leftMouth);
    final mr = lm(FaceLandmarkType.rightMouth);
    if (ml == null || mr == null) return null;

    // Outer eye corners: the two extreme points of the eye contours.
    var ax = 0.0, ay = 0.0, bx = 0.0, by = 0.0;
    var haveEyes = false;
    final pts = <math.Point<int>>[
      ...?f.contours[FaceContourType.leftEye]?.points,
      ...?f.contours[FaceContourType.rightEye]?.points,
    ];
    if (pts.length >= 8) {
      var lo = pts.first, hi = pts.first;
      for (final p in pts) {
        if (p.x < lo.x) lo = p;
        if (p.x > hi.x) hi = p;
      }
      ax = lo.x.toDouble();
      ay = lo.y.toDouble();
      bx = hi.x.toDouble();
      by = hi.y.toDouble();
      haveEyes = true;
    }
    var scale = 1.0;
    if (!haveEyes) {
      final el = lm(FaceLandmarkType.leftEye);
      final er = lm(FaceLandmarkType.rightEye);
      if (el == null || er == null) return null;
      final left = el.x <= er.x ? el : er;
      final right = el.x <= er.x ? er : el;
      ax = left.x.toDouble();
      ay = left.y.toDouble();
      bx = right.x.toDouble();
      by = right.y.toDouble();
      scale = _centreToCorner;
    }
    final dx = bx - ax, dy = by - ay;
    final eye = math.sqrt(dx * dx + dy * dy) * scale;
    if (eye < 8) return null;
    return _Pose((ml.x + mr.x) / 2, (ml.y + mr.y) / 2, eye,
        math.atan2(dy, dx));
  }

  /// Turns the raw frames of one clip into `frames` x `size` x `size` bytes.
  /// Returns (crops, null), or (null, reason) when the face was not found
  /// often enough to trust the clip.
  /// [fallback] crops the middle of the frame when no face was found, so a
  /// detector that fails on this phone is an inconvenience rather than a
  /// dead end. The guess is worse than a real detection and the caller is
  /// expected to say so.
  Future<(Uint8List?, String?)> crop(
      List<RawFrame> raw, int sensorOrientation, ModelCard card,
      {bool fallback = false}) async {
    if (raw.length < card.frames ~/ 3) return (null, 'short');
    final rotation = InputImageRotationValue.fromRawValue(sensorOrientation) ??
        InputImageRotation.rotation270deg;

    // Hold the last frame if the camera delivered fewer than asked — the
    // same thing training does with a short video.
    final frames = List<RawFrame>.generate(
        card.frames, (i) => raw[math.min(i, raw.length - 1)]);

    final poses = List<_Pose?>.filled(card.frames, null);
    var tried = 0, found = 0;
    for (var i = 0; i < card.frames; i += _detectEvery) {
      if (i >= raw.length) break;
      tried++;
      final f = frames[i];
      try {
        final faces = await _faces.processImage(InputImage.fromBytes(
          bytes: f.nv21,
          metadata: InputImageMetadata(
            size: Size(f.width.toDouble(), f.height.toDouble()),
            rotation: rotation,
            format: InputImageFormat.nv21,
            bytesPerRow: f.rowStride,
          ),
        ));
        if (faces.isEmpty) continue;
        faces.sort((a, b) => (b.boundingBox.width * b.boundingBox.height)
            .compareTo(a.boundingBox.width * a.boundingBox.height));
        final pose = _poseOf(faces.first);
        if (pose != null) {
          poses[i] = pose;
          found++;
        }
      } catch (e) {
        debugPrint('face detect: $e');
      }
    }
    if (tried == 0 || found / tried < 0.6) {
      if (!fallback) return (null, 'no-face');
      // Where a face usually sits when somebody holds a phone up to speak.
      final f = frames.first;
      final upright = sensorOrientation % 180 == 90;
      final w = (upright ? f.height : f.width).toDouble();
      final h = (upright ? f.width : f.height).toDouble();
      final guess = _Pose(w / 2, h * 0.62, h * 0.30, 0);
      for (var i = 0; i < card.frames; i++) {
        poses[i] = guess;
      }
    }

    // Fill the gaps: glide between detections, hold at the ends.
    final known = <int>[
      for (var i = 0; i < poses.length; i++)
        if (poses[i] != null) i
    ];
    _Pose at(int i) {
      if (poses[i] != null) return poses[i]!;
      var before = -1, after = -1;
      for (final k in known) {
        if (k < i) before = k;
        if (k > i) {
          after = k;
          break;
        }
      }
      if (before < 0) return poses[after]!;
      if (after < 0) return poses[before]!;
      return _Pose.lerp(
          poses[before]!, poses[after]!, (i - before) / (after - before));
    }

    final n = card.size;
    final out = Uint8List(card.frames * n * n);
    final rot = sensorOrientation % 360;
    for (var i = 0; i < card.frames; i++) {
      _warp(frames[i], rot, at(i), card.eyeBoxScale, n, out, i * n * n);
    }
    return (out, null);
  }

  /// Samples one upright, eye-levelled, mouth-centred square out of a raw
  /// sensor frame. Pixels outside the frame are black, as in training.
  /// Checked against the training code's cv2.warpAffine on the same image:
  /// with these exact offsets the two produce identical pixels.
  static void _warp(RawFrame f, int rot, _Pose p, double boxScale, int n,
      Uint8List out, int offset) {
    final w = f.width, h = f.height, stride = f.rowStride;
    final y = f.nv21;
    final s = (p.box * boxScale) / n;
    final c = math.cos(p.theta) * s, sn = math.sin(p.theta) * s;
    final half = n / 2;
    var o = offset;
    for (var oy = 0; oy < n; oy++) {
      final v = oy - half;
      for (var ox = 0; ox < n; ox++) {
        final u = ox - half;
        // position in the upright image
        final ux = p.mx + c * u - sn * v;
        final uy = p.my + sn * u + c * v;
        // ... and where that is in the sensor's own orientation
        double rx, ry;
        switch (rot) {
          case 90:
            rx = uy;
            ry = h - 1 - ux;
          case 180:
            rx = w - 1 - ux;
            ry = h - 1 - uy;
          case 270:
            rx = w - 1 - uy;
            ry = ux;
          default:
            rx = ux;
            ry = uy;
        }
        final x0 = rx.floor(), y0 = ry.floor();
        if (x0 < 0 || y0 < 0 || x0 >= w - 1 || y0 >= h - 1) {
          out[o++] = 0;
          continue;
        }
        final fx = rx - x0, fy = ry - y0;
        final i0 = y0 * stride + x0;
        final i1 = i0 + stride;
        final top = y[i0] + (y[i0 + 1] - y[i0]) * fx;
        final bot = y[i1] + (y[i1 + 1] - y[i1]) * fx;
        out[o++] = (top + (bot - top) * fy).round();
      }
    }
  }

  // ---------------------------------------------------------- inference
  /// Runs the model on crops made by [crop]. Null if no model is loaded.
  LipResult? run(Uint8List crops) {
    final interp = _interp, card = _card;
    if (interp == null || card == null) return null;
    final input = Float32List(crops.length);
    for (var i = 0; i < crops.length; i++) {
      input[i] = crops[i] / 255.0;
    }
    final outs = interp.getOutputTensors();
    int count(int i) => outs[i].shape.fold(1, (a, b) => a * b);
    final probs = Float32List(count(_probsOut));
    final emb = Float32List(count(_embOut));
    interp.runForMultipleInputs(
      [input.buffer],
      {_probsOut: probs.buffer, _embOut: emb.buffer},
    );
    return LipResult(probs, emb);
  }

  /// The same blend the notebook evaluates: nearest-prototype matching over
  /// the phrases the patient has recorded, mixed with the base model inside
  /// the probability the base model already gave those phrases.
  static Float32List personalise(
      LipResult r, Map<int, Float32List> prototypes, ModelCard card) {
    if (prototypes.isEmpty) return r.probs;
    final out = Float32List.fromList(r.probs);
    final e = r.embedding;
    var en = 0.0;
    for (final v in e) {
      en += v * v;
    }
    en = math.sqrt(en) + 1e-8;
    final cls = prototypes.keys.where((c) => c < out.length).toList()..sort();
    if (cls.isEmpty) return out;
    final scores = <double>[];
    var best = double.negativeInfinity;
    for (final c in cls) {
      final p = prototypes[c]!;
      var dot = 0.0, pn = 0.0;
      final len = math.min(p.length, e.length);
      for (var i = 0; i < len; i++) {
        dot += p[i] * e[i];
        pn += p[i] * p[i];
      }
      final s = dot / ((math.sqrt(pn) + 1e-8) * en) / card.tau;
      scores.add(s);
      if (s > best) best = s;
    }
    var z = 0.0, mass = 0.0;
    for (var i = 0; i < cls.length; i++) {
      scores[i] = math.exp(scores[i] - best);
      z += scores[i];
      mass += r.probs[cls[i]];
    }
    for (var i = 0; i < cls.length; i++) {
      final c = cls[i];
      out[c] = (1 - card.alpha) * r.probs[c] +
          card.alpha * mass * scores[i] / z;
    }
    return out;
  }
}
