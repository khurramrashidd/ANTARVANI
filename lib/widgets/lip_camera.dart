import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../app/l10n.dart';
import '../app/theme.dart';
import '../services/lip_reader.dart';
import '../services/model_service.dart';

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
  int _countdown = 0;
  double _progress = 0;

  bool get ready => _cam != null && _cam!.value.isInitialized && !_busy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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

  /// Counts down, then collects [card.frames] frames at [card.fps]. Returns
  /// the frames and the sensor orientation, or null if the camera is not
  /// available.
  Future<(List<RawFrame>, int)?> capture(ModelCard card) async {
    final cam = _cam;
    if (cam == null || !cam.value.isInitialized || _busy) return null;
    setState(() => _busy = true);
    final frames = <RawFrame>[];
    try {
      for (var n = 3; n >= 1; n--) {
        if (!mounted) return null;
        setState(() => _countdown = n);
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
      if (!mounted) return null;
      setState(() {
        _countdown = 0;
        _progress = 0;
      });

      final stepMs = 1000.0 / card.fps;
      final windowMs = card.frames * stepMs;
      final done = Completer<void>();
      Stopwatch? clock;
      await cam.startImageStream((img) {
        if (done.isCompleted || img.planes.isEmpty) return;
        clock ??= Stopwatch()..start();
        final ms = clock!.elapsedMilliseconds;
        if (frames.length < card.frames && ms >= frames.length * stepMs) {
          final plane = img.planes.first;
          frames.add(RawFrame(
            Uint8List.fromList(plane.bytes),
            img.width,
            img.height,
            plane.bytesPerRow >= img.width ? plane.bytesPerRow : img.width,
          ));
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
          _countdown = 0;
          _progress = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    final live = cam != null && cam.value.isInitialized;
    final recording = _busy && _countdown == 0;
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
                  _countdown > 0
                      ? tr('speak_get_ready')
                      : recording
                          ? tr('speak_now')
                          : tr('speak_waiting'),
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
            if (_countdown > 0)
              Center(
                child: Text('$_countdown',
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
