import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'phrases.dart';

/// Everything recorded about a speaker. No name, no phone, no email — identity
/// lives only on the paper consent form, linked by [consentFormId].
class SpeakerMeta {
  String speakerId = '';

  /// The volunteer's name. Kept so the team can find a person again — to
  /// honour a deletion request, or to call them back for Tier B. It is
  /// private project data: it is never part of the published dataset, and the
  /// consent form says so.
  String name = '';
  String tier = 'A';
  String ageBand = '';
  String gender = '';
  String firstLanguage = '';
  bool fluentHindi = true;
  String facialHair = '';
  bool glasses = false;
  String lighting = '';
  String locationNote = '';
  String phoneMount = '';
  bool consentGiven = false;
  bool consentToPublishDataset = false;
  /// Recorded explicitly, not inferred from the age band, so the dataset
  /// carries a positive statement that every speaker was an adult.
  bool adultConfirmed = false;
  String consentFormId = '';

  /// The 4 characters the volunteer needs to look themselves up. Written on
  /// the paper form; kept here so every screen can show it back to the team.
  String accessCode = '';

  // filled automatically
  String deviceId = '';
  String deviceModel = '';
  String androidVersion = '';
  String appVersion = '';
  String resolution = '';
  String cameraLens = 'front';
  String operator = '';
  String specVersion = RecSpec.specVersion;
  String sessionStartUtc = '';

  Map<String, dynamic> toMap() => {
        'speakerId': speakerId,
        'name': name.trim(),
        'nameLower': name.trim().toLowerCase(), // so search is case-blind
        'tier': tier,
        'ageBand': ageBand,
        'gender': gender,
        'firstLanguage': firstLanguage,
        'fluentHindi': fluentHindi,
        'facialHair': facialHair,
        'glasses': glasses,
        'lighting': lighting,
        'locationNote': locationNote,
        'phoneMount': phoneMount,
        'consentGiven': consentGiven,
        'consentToPublishDataset': consentToPublishDataset,
        'adultConfirmed': adultConfirmed,
        'consentFormId': consentFormId,
        'accessCode': accessCode,
        'deviceId': deviceId,
        'deviceModel': deviceModel,
        'androidVersion': androidVersion,
        'appVersion': appVersion,
        'resolution': resolution,
        'cameraLens': cameraLens,
        'operator': operator,
        'specVersion': specVersion,
        'clipMillis': RecSpec.clipMillis,
        'audioRecorded': RecSpec.recordAudio,
        'sessionStartUtc': sessionStartUtc,
        'targetClips': kPhrases.length * (tier == 'A' ? 2 : 10),
      };

  /// Rebuilds the form from a Firestore row, for editing a speaker or
  /// recording the phrases they are still missing.
  static SpeakerMeta fromMap(Map<String, dynamic> m) {
    final meta = SpeakerMeta()
      ..speakerId = m['speakerId'] as String? ?? ''
      ..name = m['name'] as String? ?? ''
      ..tier = m['tier'] as String? ?? 'A'
      ..ageBand = m['ageBand'] as String? ?? ''
      ..gender = m['gender'] as String? ?? ''
      ..firstLanguage = m['firstLanguage'] as String? ?? ''
      ..fluentHindi = m['fluentHindi'] as bool? ?? true
      ..facialHair = m['facialHair'] as String? ?? ''
      ..glasses = m['glasses'] as bool? ?? false
      ..lighting = m['lighting'] as String? ?? ''
      ..locationNote = m['locationNote'] as String? ?? ''
      ..phoneMount = m['phoneMount'] as String? ?? ''
      ..consentGiven = m['consentGiven'] as bool? ?? false
      ..consentToPublishDataset = m['consentToPublishDataset'] as bool? ?? false
      ..adultConfirmed = m['adultConfirmed'] as bool? ?? false
      ..consentFormId = m['consentFormId'] as String? ?? ''
      ..accessCode = m['accessCode'] as String? ?? ''
      ..deviceId = m['deviceId'] as String? ?? ''
      ..deviceModel = m['deviceModel'] as String? ?? ''
      ..androidVersion = m['androidVersion'] as String? ?? ''
      ..appVersion = m['appVersion'] as String? ?? ''
      ..resolution = m['resolution'] as String? ?? ''
      ..cameraLens = m['cameraLens'] as String? ?? 'front'
      ..operator = m['operator'] as String? ?? ''
      ..sessionStartUtc = m['sessionStartUtc'] as String? ?? '';
    return meta;
  }

  Future<void> fillAutoFields() async {
    final pkg = await PackageInfo.fromPlatform();
    appVersion = '${pkg.version}+${pkg.buildNumber}';
    sessionStartUtc = DateTime.now().toUtc().toIso8601String();
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      deviceModel = '${info.manufacturer} ${info.model}';
      androidVersion = info.version.release;
    }
  }
}

/// One recorded clip. Written to Firestore immediately (offline-safe) and to a
/// local upload queue until the file reaches Drive.
class ClipRecord {
  final String speakerId;
  final String phraseId;
  final int label; // phrase index — the training label
  final int take;
  final String localPath;
  final String deviceId;
  final int retakes;
  final String capturedUtc;

  // QC, measured on-device at capture time
  final String qcVerdict; // pass | warn | fail
  final double qcFaceScore; // fraction of sampled preview frames with a face
  final double qcMouthWidth; // mouth width as fraction of frame width
  final int fileBytes;

  /// The operator recorded this despite the on-screen framing warning.
  /// Kept in the dataset so the paper can report how many were overridden.
  final bool qcOverride;

  /// 'app' for clips this app recorded, 'import' for files that were already
  /// in Drive before the app existed.
  final String source;

  ClipRecord({
    required this.speakerId,
    required this.phraseId,
    required this.label,
    required this.take,
    required this.localPath,
    required this.deviceId,
    required this.retakes,
    required this.capturedUtc,
    required this.qcVerdict,
    required this.qcFaceScore,
    required this.qcMouthWidth,
    required this.fileBytes,
    this.qcOverride = false,
    this.source = 'app',
  });

  String get docId => '${speakerId}_${phraseId}_t${take.toString().padLeft(2, '0')}';
  String get fileName => '$docId.mp4';

  Map<String, dynamic> toMap() => {
        'speakerId': speakerId,
        'phraseId': phraseId,
        'label': label,
        'take': take,
        'deviceId': deviceId,
        'retakes': retakes,
        'capturedUtc': capturedUtc,
        'qcVerdict': qcVerdict,
        'qcFaceScore': qcFaceScore,
        'qcMouthWidth': qcMouthWidth,
        'fileBytes': fileBytes,
        'fileName': fileName,
        'qcOverride': qcOverride,
        'source': source,
        // 'ok' or 'rejected'. Rejected clips stay as a record of what was
        // thrown away and why; the pipeline skips them.
        'status': 'ok',
        'uploaded': false,
        'driveFileId': null,
      };

  Map<String, dynamic> toQueueJson() => {
        'docId': docId,
        'localPath': localPath,
        'fileName': fileName,
        'speakerId': speakerId,
      };
}
