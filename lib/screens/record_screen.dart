import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models.dart';
import '../phrases.dart';
import '../app/theme.dart';
import '../services/face_qc.dart';
import '../services/sync_service.dart';
import '../storage.dart';

/// One thing to record: which phrase, and which take number it will be saved
/// as. Used to resume a half-finished speaker, or to redo a single phrase
/// after its clip was thrown away.
class RecordSlot {
  final int phraseIndex;
  final int take;
  const RecordSlot(this.phraseIndex, this.take);
}

class _Item {
  final int phraseIndex;
  final int take;
  int retakes = 0;
  _Item(this.phraseIndex, this.take);
}

enum _Stage { calibrate, idle, countdown, recording, review, done }

class RecordScreen extends StatefulWidget {
  final SpeakerMeta meta;
  final int takes;

  /// Exactly what to record. When given, `takes` is ignored — this is how a
  /// resumed session records only the gaps, and how a single phrase is redone.
  final List<RecordSlot>? only;

  /// Shown on the finish screen.
  final String title;

  /// A practice run. Nothing is written to Firestore, nothing reaches Drive,
  /// and the video files are deleted as soon as each one is reviewed.
  final bool demo;

  const RecordScreen({
    super.key,
    required this.meta,
    required this.takes,
    this.only,
    this.title = 'Session complete',
    this.demo = false,
  });

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  CameraController? _cam;
  CameraDescription? _desc;
  List<CameraDescription> _cams = const [];
  bool _switching = false;
  VideoPlayerController? _player;
  final FaceQc _qc = FaceQc();

  late final List<_Item> _queue;
  int _cursor = 0;
  _Stage _stage = _Stage.calibrate;
  int _countdown = RecSpec.countdownSeconds;
  Timer? _timer;
  File? _pending;
  String _error = '';

  // live QC state
  FrameCheck _last = FrameCheck.bad;
  bool _streaming = false;
  final List<double> _apertures = [];
  final List<bool> _recentFace = [];
  bool _calibrated = false;
  String _calibrateMsg = '';

  /// The operator chose to record even though the framing check was unhappy.
  /// Recorded with the clip so the dataset shows which ones were overridden.
  bool _overrode = false;

  @override
  void initState() {
    super.initState();
    _queue = widget.only != null
        ? [for (final s in widget.only!) _Item(s.phraseIndex, s.take)]
        : _buildQueue(widget.takes);
    // Nothing to do — the caller should not have opened this, but be safe.
    if (_queue.isEmpty) _stage = _Stage.done;
    _initCamera();
  }

  /// Phrases are shuffled within each take round. Without this, consecutive
  /// takes of one phrase share lighting, posture and fatigue, and the model
  /// learns the session instead of the phrase.
  List<_Item> _buildQueue(int takes) {
    final rng = Random();
    final out = <_Item>[];
    for (var t = 1; t <= takes; t++) {
      final order = List<int>.generate(kPhrases.length, (i) => i)..shuffle(rng);
      for (final p in order) {
        out.add(_Item(p, t));
      }
    }
    return out;
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        if (mounted) setState(() => _error = 'No camera on this device.');
        return;
      }
      _cams = cams;
      final front = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cams.first,
      );
      await _openCamera(front);
      if (!widget.demo) await SyncService.instance.saveSpeaker(widget.meta);
    } catch (e) {
      if (mounted) setState(() => _error = 'Camera failed: $e');
    }
  }

  Future<void> _openCamera(CameraDescription desc) async {
    final ctrl = CameraController(
      desc,
      ResolutionPreset.high, // 720p
      enableAudio: RecSpec.recordAudio, // false — never record audio
      imageFormatGroup: ImageFormatGroup.nv21, // what ML Kit wants
    );
    await ctrl.initialize();
    widget.meta.resolution =
        '${ctrl.value.previewSize?.height.toInt()}x${ctrl.value.previewSize?.width.toInt()}';
    widget.meta.cameraLens = desc.lensDirection.name;
    if (!mounted) {
      await ctrl.dispose();
      return;
    }
    setState(() {
      _cam = ctrl;
      _desc = desc;
    });
    await _startStream();
  }

  /// Front camera is the default — the volunteer can see themselves. The back
  /// camera is sharper, which helps when someone else holds the phone.
  Future<void> _switchCamera() async {
    if (_switching || _cams.length < 2) return;
    setState(() => _switching = true);
    try {
      final i = _cams.indexOf(_desc!);
      final next = _cams[(i + 1) % _cams.length];
      await _stopStream();
      final old = _cam;
      setState(() => _cam = null);
      await old?.dispose();
      _recentFace.clear();
      _apertures.clear();
      await _openCamera(next);
      if (!widget.demo) await SyncService.instance.saveSpeaker(widget.meta);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not switch camera: $e');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _startStream() async {
    final cam = _cam;
    if (cam == null || _streaming || cam.value.isStreamingImages) return;
    _streaming = true;
    await cam.startImageStream((image) async {
      final res = await _qc.check(image, _desc!);
      if (res == null || !mounted) return;
      _recentFace.add(res.faceFound);
      if (_recentFace.length > 30) _recentFace.removeAt(0);
      if (_stage == _Stage.calibrate && res.faceFound) {
        _apertures.add(res.lipAperture);
        if (_apertures.length > 90) _apertures.removeAt(0);
      }
      setState(() => _last = res);
    });
  }

  Future<void> _stopStream() async {
    final cam = _cam;
    if (cam == null || !_streaming) return;
    _streaming = false;
    if (cam.value.isStreamingImages) await cam.stopImageStream();
  }

  double get _faceScore => _recentFace.isEmpty
      ? 0
      : _recentFace.where((e) => e).length / _recentFace.length;

  @override
  void dispose() {
    _timer?.cancel();
    _qc.dispose();
    _cam?.dispose();
    _player?.dispose();
    super.dispose();
  }

  _Item get _item => _queue[_cursor];
  Phrase get _phrase => kPhrases[_item.phraseIndex];

  // --------------------------------------------------------- calibration
  void _runCalibration() {
    setState(() {
      _apertures.clear();
      _calibrateMsg = 'Mouth the phrase now…';
    });
    Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      final ok = FaceQc.motionDetected(_apertures);
      setState(() {
        _calibrated = ok;
        _calibrateMsg = ok
            ? 'Lip movement is clearly visible. Ready to record.'
            : 'Lip movement was too small to see. Ask them to '
                'articulate more clearly and try again.';
        if (ok) _stage = _Stage.idle;
      });
    });
  }

  // ------------------------------------------------------------ recording
  void _startCountdown({bool override = false}) {
    if (_cam == null || !_cam!.value.isInitialized) return;
    setState(() {
      _stage = _Stage.countdown;
      _countdown = RecSpec.countdownSeconds;
      _overrode = override;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (_countdown <= 1) {
        t.cancel();
        await _record();
      } else {
        setState(() => _countdown--);
      }
    });
  }

  Future<void> _record() async {
    try {
      // Android cannot stream frames and record video at once.
      await _stopStream();
      await _cam!.startVideoRecording();
      setState(() => _stage = _Stage.recording);
      await Future<void>.delayed(
          const Duration(milliseconds: RecSpec.clipMillis));
      final x = await _cam!.stopVideoRecording();
      final tmp = File(x.path);

      _player?.dispose();
      final p = VideoPlayerController.file(tmp);
      await p.initialize();
      await p.setLooping(true);
      await p.play();
      if (!mounted) return;
      setState(() {
        _pending = tmp;
        _player = p;
        _stage = _Stage.review;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Recording failed: $e';
        _stage = _Stage.idle;
      });
      await _startStream();
    }
  }

  String _verdict(int bytes) {
    if (bytes < 20 * 1024) return 'fail';
    if (_faceScore < 0.9) return 'warn';
    return 'pass';
  }

  Future<void> _keep() async {
    if (widget.demo) {
      // Practice run: the recording is discarded here and now.
      try {
        await _pending?.delete();
      } catch (_) {}
      _player?.dispose();
      _player = null;
      _pending = null;
      if (_cursor + 1 >= _queue.length) {
        setState(() => _stage = _Stage.done);
      } else {
        setState(() {
          _cursor++;
          _stage = _Stage.idle;
          _overrode = false;
        });
        await _startStream();
      }
      return;
    }

    final dest =
        await Storage.clipFile(widget.meta.speakerId, _phrase.id, _item.take);
    await _pending!.copy(dest.path);
    try {
      await _pending!.delete();
    } catch (_) {}

    final bytes = dest.lengthSync();
    await SyncService.instance.recordClip(ClipRecord(
      speakerId: widget.meta.speakerId,
      phraseId: _phrase.id,
      label: _item.phraseIndex,
      take: _item.take,
      localPath: dest.path,
      deviceId: SyncService.instance.deviceId,
      retakes: _item.retakes,
      capturedUtc: DateTime.now().toUtc().toIso8601String(),
      qcVerdict: _verdict(bytes),
      qcOverride: _overrode,
      qcFaceScore: double.parse(_faceScore.toStringAsFixed(3)),
      qcMouthWidth: double.parse(_last.mouthWidth.toStringAsFixed(4)),
      fileBytes: bytes,
    ));

    _player?.dispose();
    _player = null;
    _pending = null;

    if (_cursor + 1 >= _queue.length) {
      setState(() => _stage = _Stage.done);
    } else {
      setState(() {
        _cursor++;
        _stage = _Stage.idle;
        _overrode = false;
      });
      await _startStream();
    }
  }

  Future<void> _redo() async {
    _item.retakes++;
    try {
      await _pending?.delete();
    } catch (_) {}
    _player?.dispose();
    setState(() {
      _player = null;
      _pending = null;
      _stage = _Stage.idle;
    });
    await _startStream();
  }

  // ----------------------------------------------------------------- view
  @override
  Widget build(BuildContext context) {
    if (_error.isNotEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Error')),
        body: Padding(padding: const EdgeInsets.all(24), child: Text(_error)),
      );
    }
    if (_cam == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_stage == _Stage.done) return _doneView();

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (widget.demo)
              Container(
                width: double.infinity,
                color: Brand.amber,
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: const Text(
                  'DEMO — nothing is saved or uploaded',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Brand.indigo,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5),
                ),
              ),
            _header(),
            Expanded(child: _body()),
            _controls(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    if (_stage == _Stage.calibrate) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: Column(
          children: [
            Text('${widget.meta.speakerId} · articulation check',
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 10),
            const Text('मुझे पानी चाहिए',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 30, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              'Ask them to mouth this silently a few times.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${widget.meta.speakerId} · take ${_item.take}',
                  style: Theme.of(context).textTheme.labelLarge),
              Text('${_cursor + 1} / ${_queue.length}',
                  style: Theme.of(context).textTheme.labelLarge),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: (_cursor + 1) / _queue.length),
          const SizedBox(height: 12),
          Text(_phrase.devanagari,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 34, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(_phrase.roman, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  Widget _body() {
    if (_stage == _Stage.review && _player != null) {
      return Center(
        child: AspectRatio(
          aspectRatio: _player!.value.aspectRatio,
          child: VideoPlayer(_player!),
        ),
      );
    }
    final good = _last.ok;
    return Stack(
      alignment: Alignment.center,
      children: [
        CameraPreview(_cam!),
        // Framing guide — green only when ML Kit is happy with the framing.
        IgnorePointer(
          child: Container(
            margin: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              border: Border.all(
                color: good ? Colors.greenAccent.shade400 : Colors.orange,
                width: 3,
              ),
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        if (!good && _stage != _Stage.recording)
          Positioned(
            bottom: 14,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(_last.problem ?? '',
                  style: const TextStyle(color: Colors.white)),
            ),
          ),
        if (_cams.length > 1 &&
            (_stage == _Stage.idle || _stage == _Stage.calibrate))
          Positioned(
            top: 12,
            right: 12,
            child: Material(
              color: Colors.black54,
              shape: const CircleBorder(),
              child: IconButton(
                tooltip: 'Switch camera',
                color: Colors.white,
                icon: _switching
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.cameraswitch),
                onPressed: _switching ? null : _switchCamera,
              ),
            ),
          ),
        if (_cams.length > 1 &&
            (_stage == _Stage.idle || _stage == _Stage.calibrate))
          Positioned(
            top: 60,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _desc?.lensDirection == CameraLensDirection.front
                    ? 'front'
                    : 'back',
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ),
        if (_stage == _Stage.countdown)
          Container(
            color: Colors.black54,
            alignment: Alignment.center,
            child: Text('$_countdown',
                style: const TextStyle(
                    fontSize: 110,
                    color: Colors.white,
                    fontWeight: FontWeight.bold)),
          ),
        if (_stage == _Stage.recording)
          Positioned(
            top: 16,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                  color: Colors.red, borderRadius: BorderRadius.circular(20)),
              child: const Text('RECORDING',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
      ],
    );
  }

  Widget _controls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      child: switch (_stage) {
        _Stage.calibrate => Column(
            children: [
              if (_calibrateMsg.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    _calibrateMsg,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _calibrated ? Colors.green.shade700 : null,
                    ),
                  ),
                ),
              FilledButton(
                onPressed: _last.faceFound ? _runCalibration : null,
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56)),
                child: Text(_calibrateMsg.isEmpty
                    ? 'Check articulation (4s)'
                    : 'Try again'),
              ),
              TextButton(
                onPressed: () {
                  setState(() => _stage = _Stage.idle);
                },
                child: const Text('Skip check'),
              ),
            ],
          ),
        _Stage.idle => Column(
            children: [
              const Text('चुपचाप बोलिए — आवाज़ मत निकालिए',
                  style: TextStyle(fontSize: 16)),
              const SizedBox(height: 10),
              FilledButton(
                onPressed: _last.ok ? () => _startCountdown() : null,
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56)),
                child: Text(_last.ok ? 'Record' : (_last.problem ?? 'Waiting…')),
              ),
              // The face checker is a helper, not a gate. If the picture looks
              // fine to the person holding the phone, their eyes win — the
              // clip is simply tagged as overridden.
              if (!_last.ok)
                TextButton.icon(
                  onPressed: () => _startCountdown(override: true),
                  icon: const Icon(Icons.videocam),
                  label: const Text('Looks fine — record anyway'),
                ),
            ],
          ),
        _Stage.review => Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _redo,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete & redo'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(56)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _keep,
                  icon: const Icon(Icons.check),
                  label: const Text('Keep'),
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(56)),
                ),
              ),
            ],
          ),
        _ => const SizedBox(height: 56),
      },
    );
  }

  Widget _doneView() {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(widget.demo ? Icons.science_outlined : Icons.check_circle,
                size: 72,
                color: widget.demo ? Brand.amber : Colors.green),
            const SizedBox(height: 16),
            if (widget.demo) ...[
              Text('Demo finished — nothing was saved',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text(
                'No speaker number was used, no records were written, and '
                'the videos have been deleted from this phone.',
                textAlign: TextAlign.center,
              ),
            ] else ...[
            Text('${_queue.length} clips saved for ${widget.meta.speakerId}'
                '${widget.meta.name.isEmpty ? "" : " · ${widget.meta.name}"}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'Uploading in the background. Thank the volunteer and file '
              'their form.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    Text('On the paper form',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 6),
                    Text(
                      '${widget.meta.speakerId}   '
                      '${widget.meta.consentFormId}'
                      '${widget.meta.accessCode.isEmpty ? "" : "   ${widget.meta.accessCode}"}',
                      style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2),
                    ),
                    Text('speaker · form · access code',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
            ),
            ],
            const SizedBox(height: 28),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).popUntil((r) => r.isFirst),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }
}
