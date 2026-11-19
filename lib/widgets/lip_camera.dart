import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../app/l10n.dart';
import '../app/theme.dart';
import 'dart:io';

import '../services/camera_image.dart';
import '../services/lip_reader.dart';
import '../services/model_service.dart';
import '../services/video_frames.dart';

/// The front camera with a lip guide, able to capture one clip's worth of
/// frames for the recogniser. Used by Speak and by Personalise.
///
/// Frames are taken from the live preview stream, not from a recorded video
/// file: nothing is written to storage, and no audio is ever opened.
class LipCamera extends StatefulWidget {
  const LipCamera({super.key});

  @override
  State<LipCamera> createState() => LipCameraState();
}

class LipCameraState extends State<LipCamera> with WidgetsBindingObserver {
  CameraController? _cam;
  bool _failed = false;
  bool _busy = false;
  bool _opening = false;
  int _countdownN = 0;
  bool _reading = false;
  double _progress = 0;

  bool get ready => _cam != null && _cam!.value.isInitialized && !_busy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Settles which capture path to use before the person taps Start.
    unawaited(VideoFrames.probe());
    _open();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cam?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Android takes the camera away in the background; ask for it again.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      final old = _cam;
      _cam = null;
      old?.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && _cam == null) {
      _open();
    }
  }

  Future<void> _open() async {
    // The permission prompt pauses and resumes the app, which would start a
    // second camera while the first is still opening.
    if (_opening) return;
    _opening = true;
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw StateError('no camera');
      final desc = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cams.first,
      );
      final ctrl = CameraController(
        desc,
        ResolutionPreset.medium,
        enableAudio: false, // never
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      setState(() {
        _cam = ctrl;
        _failed = false;
      });
    } catch (e) {
      debugPrint('lip camera: $e');
      if (mounted) setState(() => _failed = true);
    } finally {
      _opening = false;
    }
  }

  /// Counts down, then captures one clip's worth of frames.
  ///
  /// It records a real video first and reads the frames back out of the file,
  /// which is exactly how the training clips were made. If that path is not
  /// available on this phone it falls back to the live preview stream, which
  /// is how this worked before and still works — just at preview quality.
  Future<(List<RawFrame>, int)?> capture(ModelCard card) async {
    final cam = _cam;
    if (cam == null || !cam.value.isInitialized || _busy) return null;

    if (!VideoFrames.unavailable) {
      final shot = await _captureVideo(card, cam);
      if (shot != null) return shot;
    }
    return _captureLive(card, cam);
  }

  /// Records [card.windowSeconds] of video, pulls the frames out, then throws
  /// the file away. Nothing is kept: this is recognition, not collection.
  Future<(List<RawFrame>, int)?> _captureVideo(
      ModelCard card, CameraController cam) async {
    if (_busy) return null;
    setState(() => _busy = true);
    File? file;
    try {
      await _countdown();
      if (!mounted) return null;
      setState(() => _progress = 0);

      await cam.startVideoRecording();
      final windowMs = (card.windowSeconds * 1000).round();
      final started = DateTime.now();
      while (DateTime.now().difference(started).inMilliseconds < windowMs) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!mounted) break;
        setState(() => _progress =
            DateTime.now().difference(started).inMilliseconds / windowMs);
      }
      final shot = await cam.stopVideoRecording();
      file = File(shot.path);

      if (mounted) setState(() => _reading = true);
      final frames = await VideoFrames.read(
        shot.path,
        count: card.frames,
        stepMs: (1000 / card.fps).round(),
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      return frames;
    } catch (e) {
      debugPrint('video capture failed: $e');
      return null;
    } finally {
      try {
        if (file != null && file.existsSync()) file.deleteSync();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _busy = false;
          _reading = false;
          _countdownN = 0;
          _progress = 0;
        });
      }
    }
  }

  Future<void> _countdown() async {
    for (var n = 3; n >= 1; n--) {
      if (!mounted) return;
      setState(() => _countdownN = n);
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    if (mounted) setState(() => _countdownN = 0);
  }

  /// The original path: frames straight off the preview stream.
  Future<(List<RawFrame>, int)?> _captureLive(
      ModelCard card, CameraController cam) async {
    if (_busy) return null;
    setState(() => _busy = true);
    final frames = <RawFrame>[];
    try {
      await _countdown();
      if (!mounted) return null;
      setState(() => _progress = 0);

      final stepMs = 1000.0 / card.fps;
      final windowMs = card.frames * stepMs;
      final done = Completer<void>();
      Stopwatch? clock;
      await cam.startImageStream((img) {
        if (done.isCompleted || img.planes.isEmpty) return;
        clock ??= Stopwatch()..start();
        final ms = clock!.elapsedMilliseconds;
        if (frames.length < card.frames && ms >= frames.length * stepMs) {
          // Packed here, not taken from the first plane: see camera_image.dart.
          final f = nv21FrameOf(img);
          frames.add(RawFrame(f.bytes, f.width, f.height, f.rowStride));
          if (mounted && frames.length % 4 == 0) {
            setState(() => _progress = frames.length / card.frames);
          }
        }
        if (frames.length >= card.frames || ms > windowMs + 600) {
          done.complete();
        }
      });
      await done.future.timeout(Duration(milliseconds: windowMs.round() + 4000),
          onTimeout: () {});
      try {
        await cam.stopImageStream();
      } catch (_) {}
      return (frames, cam.description.sensorOrientation);
    } catch (e) {
      debugPrint('capture failed: $e');
      return null;
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _countdownN = 0;
          _progress = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    final live = cam != null && cam.value.isInitialized;
    final recording = _busy && _countdownN == 0 && !_reading;
    return AspectRatio(
      aspectRatio: 3 / 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xFF0D1433)),
            if (live)
              FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: cam.value.previewSize?.height ?? 480,
                  height: cam.value.previewSize?.width ?? 640,
                  child: CameraPreview(cam),
                ),
              )
            else
              Center(
                child: _failed
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(tr('speak_camera_error'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white)),
                      )
                    : const CircularProgressIndicator(),
              ),
            // Lip guide: where the mouth should sit.
            Align(
              alignment: const Alignment(0, 0.42),
              child: Container(
                width: 170,
                height: 90,
                decoration: BoxDecoration(
                  border: Border.all(
                      color: recording ? Brand.urgent : Brand.amber, width: 3),
                  borderRadius: BorderRadius.circular(45),
                ),
              ),
            ),
            Align(
              alignment: const Alignment(0, -0.92),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _reading
                      ? tr('speak_reading')
                      : _countdownN > 0
                          ? tr('speak_get_ready')
                          : recording
                              ? tr('speak_now')
                              : tr('speak_waiting'),
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
            if (_countdownN > 0)
              Center(
                child: Text('$_countdownN',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 96,
                        fontWeight: FontWeight.w800)),
              ),
            if (recording)
              Align(
                alignment: Alignment.bottomCenter,
                child: LinearProgressIndicator(
                    value: _progress, minHeight: 8, color: Brand.urgent),
              ),
          ],
        ),
      ),
    );
  }
}
