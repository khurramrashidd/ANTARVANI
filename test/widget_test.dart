import 'package:flutter_test/flutter_test.dart';

import 'package:silent_voice_recorder/app/l10n.dart';
import 'package:silent_voice_recorder/models.dart';
import 'package:silent_voice_recorder/phrases.dart';
import 'package:silent_voice_recorder/services/drive_uploader.dart';
import 'package:silent_voice_recorder/services/id_allocator.dart';
import 'package:silent_voice_recorder/services/model_service.dart';
import 'package:silent_voice_recorder/services/participant_service.dart';
import 'package:silent_voice_recorder/services/team.dart';
import 'package:silent_voice_recorder/screens/collectors_tab.dart';
import 'package:silent_voice_recorder/screens/dashboard_screen.dart';

void main() {
  test('phrase set is frozen at 20 and correctly numbered', () {
    expect(kPhrases.length, 20);
    for (var i = 0; i < kPhrases.length; i++) {
      expect(kPhrases[i].id, 'P${(i + 1).toString().padLeft(2, '0')}');
    }
  });

  test('phrase ids are unique', () {
    expect(kPhrases.map((p) => p.id).toSet().length, kPhrases.length);
  });

  test('recording spec never records audio', () {
    expect(RecSpec.recordAudio, isFalse);
  });

  test('tier take counts', () {
    expect(Tier.a.takes, 1); // one take per phrase for breadth
    expect(Tier.b.takes, 10); // repeats for the personalisation study
  });

  group('speaker ids from the shared counter', () {
    test('format and form number mirror', () {
      expect(const SessionIds(1).speakerId, 'S001');
      expect(const SessionIds(1).formNo, 'F001');
      expect(const SessionIds(42).speakerId, 'S042');
      expect(const SessionIds(1234).speakerId, 'S1234');
    });

    test('parse round-trips and rejects other ids', () {
      for (final n in [1, 9, 10, 99, 100, 999, 1000]) {
        expect(SessionIds.parse(SessionIds(n).speakerId), n);
      }
      expect(SessionIds.parse('P01'), isNull);
      expect(SessionIds.parse('S01x'), isNull);
    });

    test('sequential numbers never repeat', () {
      final ids = [for (var n = 1; n <= 2000; n++) SessionIds(n).speakerId];
      expect(ids.toSet().length, ids.length);
    });
  });

  test('every on-screen text has English, Hindi and Marathi', () {
    for (final k in allKeys) {
      final row = rowFor(k)!;
      for (final lang in ['en', 'hi', 'mr']) {
        expect(row[lang]?.isNotEmpty, isTrue, reason: '$k missing $lang');
      }
    }
  });

  group('drive file naming', () {
    test('phrase folder comes from the file name', () {
      expect(DriveUploader.phraseOf('S014_P03_t01.mp4'), 'P03');
      expect(DriveUploader.phraseOf('S1234_P20_t10.mp4'), 'P20');
      expect(DriveUploader.phraseOf('whatsapp-video.mp4'), 'unsorted');
    });

    test('app-named files are told apart from hand-made ones', () {
      bool appNamed(String n) => DriveClip(
            fileId: 'x',
            name: n,
            phraseId: 'P01',
            bytes: 0,
          ).isAppNamed;
      expect(appNamed('S014_P03_t01.mp4'), isTrue);
      expect(appNamed('VID_20261018_120000.mp4'), isFalse);
      expect(appNamed('P01.mp4'), isFalse);
    });
  });

  group('numbers are recycled, never stranded', () {
    test('a fresh counter just counts up', () {
      expect(IdAllocator.nextNumber(free: [], last: 0), 1);
      expect(IdAllocator.nextNumber(free: [], last: 7), 8);
    });

    test('a returned number is handed out before a new one', () {
      expect(IdAllocator.nextNumber(free: [4], last: 9), 4);
      expect(IdAllocator.nextNumber(free: [9, 2, 6], last: 12), 2);
    });

    test('the pool drains in order and then counts on', () {
      final free = [5, 3];
      final issued = <int>[];
      var last = 7;
      for (var i = 0; i < 4; i++) {
        final n = IdAllocator.nextNumber(free: free, last: last);
        free.remove(n);
        if (n > last) last = n;
        issued.add(n);
      }
      expect(issued, [3, 5, 8, 9]);
      expect(issued.toSet().length, issued.length);
    });
  });

  test('speaker metadata survives a round trip through Firestore', () {
    final meta = SpeakerMeta()
      ..speakerId = 'S014'
      ..name = '  Asha Verma '
      ..tier = 'B'
      ..ageBand = '26-35'
      ..gender = 'Female'
      ..firstLanguage = 'Marathi'
      ..fluentHindi = false
      ..glasses = true
      ..lighting = 'Indoor, dim'
      ..cameraLens = 'back'
      ..consentGiven = true
      ..adultConfirmed = true
      ..consentFormId = 'F014';

    final map = meta.toMap();
    expect(map['name'], 'Asha Verma'); // trimmed
    expect(map['nameLower'], 'asha verma'); // searchable
    expect(map['cameraLens'], 'back');

    final back = SpeakerMeta.fromMap(map);
    expect(back.name, 'Asha Verma');
    expect(back.tier, 'B');
    expect(back.fluentHindi, isFalse);
    expect(back.glasses, isTrue);
    expect(back.consentFormId, 'F014');
    expect(back.cameraLens, 'back');
  });

  group('a volunteer finding their own clips', () {
    test('typed numbers are tidied into the real format', () {
      for (final input in ['14', 's14', 'S14', ' s 14 ', 'S014']) {
        expect(ParticipantService.normalise(input, 'S'), 'S014');
      }
      expect(ParticipantService.normalise('f7', 'F'), 'F007');
      expect(ParticipantService.normalise('F1234', 'F'), 'F1234');
    });

    test('the two numbers always agree for the same session', () {
      for (final n in [1, 14, 207, 1000]) {
        final ids = SessionIds(n);
        expect(ParticipantService.normalise(ids.speakerId, 'S'), ids.speakerId);
        expect(ParticipantService.normalise(ids.formNo, 'F'), ids.formNo);
        expect(ids.speakerId.substring(1), ids.formNo.substring(1));
      }
    });
  });

  test('both numbers of a session point at the same record', () {
    // The delete-by-number box and My recordings both rely on this.
    int? numberIn(String input) {
      final m = RegExp(r'\d+').firstMatch(input.trim());
      return m == null ? null : int.parse(m.group(0)!);
    }

    for (final n in [1, 14, 207]) {
      final ids = SessionIds(n);
      expect(numberIn(ids.speakerId), n);
      expect(numberIn(ids.formNo), n);
      expect(numberIn('s$n'), n);
      expect(numberIn(' $n '), n);
    }
    expect(numberIn('nonsense'), isNull);
  });

  test('a mismatched pair is always two different sessions', () {
    // S003 with F004 can never be valid: both labels come from one number.
    for (final n in [1, 3, 14, 207]) {
      final ids = SessionIds(n);
      final other = SessionIds(n + 1);
      expect(ids.speakerId.substring(1), ids.formNo.substring(1));
      expect(ids.speakerId.substring(1) == other.formNo.substring(1), isFalse);
    }
  });

  group('access codes', () {
    test('four characters, never ones that are misread by hand', () {
      const banned = ['O', '0', 'I', '1', 'L', 'S', '5', 'B', '8', 'Z', '2'];
      for (var i = 0; i < 300; i++) {
        final code = IdAllocator.newCode();
        expect(code.length, 4);
        for (final c in banned) {
          expect(code.contains(c), isFalse, reason: '$code contains $c');
        }
      }
    });

    test('codes differ between sessions', () {
      final codes = {for (var i = 0; i < 200; i++) IdAllocator.newCode()};
      // 24^4 = 331,776 combinations, so 200 draws should rarely repeat.
      expect(codes.length, greaterThan(190));
    });

    test('what people type is tidied before it is compared', () {
      expect(IdAllocator.tidyCode(' 7kh4 '), '7KH4');
      expect(IdAllocator.tidyCode('7-K-H-4'), '7KH4');
      expect(IdAllocator.tidyCode('7kh4'), '7KH4');
    });
  });

  test('roles', () {
    const master = AppUser(
        email: Team.masterEmail, name: 'K', role: Roles.patient);
    expect(master.isAdmin, isTrue);
    const member = AppUser(email: 'a@b.c', name: 'A', role: Roles.member);
    expect(member.isTeam, isTrue);
    expect(member.isAdmin, isFalse);
    const patient = AppUser(email: 'p@b.c', name: 'P', role: Roles.patient);
    expect(patient.isTeam, isFalse);
  });

  // ------------------------------------------------ languages and models
  test('Hindi is the built-in language and the default', () {
    expect(PhraseBook.code, 'hi');
    expect(PhraseBook.current.tts, 'hi-IN');
    expect(identical(kPhrases, kHindiPhrases), isTrue);
  });

  test('a language file is accepted as rows or as maps', () {
    final (a, whyA) = Language.parse({
      'code': 'MR',
      'name': 'Marathi',
      'tts': 'mr-IN',
      'phrases': [
        ['P01', 'मला पाणी हवे आहे', 'mala paani have aahe', 'I need water'],
        ['P02', 'दुखत आहे', 'dukhat aahe', "I'm in pain"],
      ],
    });
    expect(whyA, isNull);
    expect(a!.code, 'mr');
    expect(a.phrases.length, 2);
    final (b, _) = Language.parse(a.toMap());
    expect(b!.phrases[1].devanagari, 'दुखत आहे');
  });

  test('a language file with gaps in the numbering is refused', () {
    final (lang, why) = Language.parse({
      'code': 'mr',
      'phrases': [
        ['P01', 'a'],
        ['P03', 'b'],
      ],
    });
    expect(lang, isNull);
    expect(why, contains('P02'));
  });

  test('switching language switches the phrase list', () {
    final (mr, _) = Language.parse({
      'code': 'mr',
      'phrases': [
        ['P01', 'a'],
        ['P02', 'b'],
        ['P03', 'c'],
      ],
    });
    PhraseBook.all['mr'] = mr!;
    PhraseBook.code = 'mr';
    expect(kPhrases.length, 3);
    PhraseBook.code = 'hi';
    PhraseBook.all.remove('mr');
    expect(kPhrases.length, 20);
  });

  Map<String, dynamic> card() => {
        'lang': 'hi',
        'name': 'Hindi',
        'tts': 'hi-IN',
        'version': 3,
        'file': 'antarvani_hi_v3.tflite',
        'sha256': 'a' * 64,
        'sizeBytes': 3559012,
        'frames': 48,
        'size': 88,
        'fps': 16.0,
        'labels': [
          {'id': 'P01', 'text': 'मुझे पानी चाहिए', 'roman': '', 'english': ''},
          {'id': 'P02', 'text': 'दर्द हो रहा है', 'roman': '', 'english': ''},
        ],
        'speakers': 12,
        'clips': 240,
        'top1': 0.5,
        'top3': 0.8,
      };

  test('the model file is found next to its card', () {
    final (c, why) = ModelCard.parse(card(),
        cardUrl: 'https://github.com/u/r/releases/download/model-hi-v3/'
            'antarvani_hi_v3.json');
    expect(why, isNull);
    expect(c!.url,
        'https://github.com/u/r/releases/download/model-hi-v3/antarvani_hi_v3.tflite');
    expect(c.version, 3);
    expect(c.labels.length, 2);
    expect(c.windowSeconds, 3.0);
  });

  test('a model card survives being stored and read back', () {
    final (c, _) =
        ModelCard.parse(card(), cardUrl: 'https://example.com/m/card.json');
    final (again, why) = ModelCard.parse(c!.toMap());
    expect(why, isNull);
    expect(again!.url, c.url);
    expect(again.sha256, c.sha256);
  });

  test('a model card without a checksum or over http is refused', () {
    final noSum = card()..remove('sha256');
    expect(ModelCard.parse(noSum, cardUrl: 'https://x.org/a/c.json').$1, isNull);
    expect(ModelCard.parse(card(), cardUrl: 'http://x.org/a/c.json').$1, isNull);
  });

  test('language folders in Drive are named lang_<code>', () {
    expect(DriveUploader.langFolderName('mr'), 'lang_mr');
  });

  // ------------------------------------------------ collector dashboard
  ClipView clip({
    required String speaker,
    required String phrase,
    required String who,
    bool uploaded = true,
    int daysAgo = 0,
    String status = 'ok',
    String device = 'dev1',
    String qc = 'pass',
  }) {
    final t = DateTime.now().toUtc().subtract(Duration(days: daysAgo));
    return ClipView({
      'speakerId': speaker,
      'phraseId': phrase,
      'take': 1,
      'status': status,
      'qcVerdict': qc,
      'uploaded': uploaded,
      'collectorEmail': '$who@example.com',
      'collectorName': who,
      'deviceId': device,
      'capturedUtc': t.toIso8601String(),
      'qcFaceScore': 0.9,
      'qcMouthWidth': 0.2,
    }, '${speaker}_${phrase}_t01');
  }

  Stats statsOf(List<ClipView> clips, [List<SpeakerView> sp = const []]) =>
      Stats(clips, sp);

  test('clips are grouped by the person who recorded them', () {
    final s = statsOf([
      clip(speaker: 'S001', phrase: 'P01', who: 'kinza'),
      clip(speaker: 'S001', phrase: 'P02', who: 'kinza', uploaded: false),
      clip(speaker: 'S002', phrase: 'P01', who: 'prapti'),
    ]);
    final rows = collectorsOf(s);
    expect(rows.length, 2);
    // whoever still owes uploads comes first
    expect(rows.first.name, 'kinza');
    expect(rows.first.total, 2);
    expect(rows.first.uploaded, 1);
    expect(rows.first.waiting.length, 1);
    expect(rows.first.speakerIds, {'S001'});
    expect(rows.last.waiting, isEmpty);
  });

  test('waiting clips are listed under the speaker they belong to', () {
    final s = statsOf([
      clip(speaker: 'S001', phrase: 'P01', who: 'kinza', uploaded: false),
      clip(speaker: 'S001', phrase: 'P02', who: 'kinza', uploaded: false),
      clip(speaker: 'S004', phrase: 'P01', who: 'kinza', uploaded: false),
      clip(speaker: 'S004', phrase: 'P02', who: 'kinza'),
    ]);
    final r = collectorsOf(s).single;
    expect(r.waitingBySpeaker.keys.toSet(), {'S001', 'S004'});
    expect(r.waitingBySpeaker['S001']!.length, 2);
    expect(r.waitingBySpeaker['S004']!.length, 1);
  });

  test('a clip is only called stuck after a day on the phone', () {
    final fresh = collectorsOf(statsOf(
        [clip(speaker: 'S001', phrase: 'P01', who: 'k', uploaded: false)]));
    expect(fresh.single.isStuck, isFalse);

    final old = collectorsOf(statsOf([
      clip(speaker: 'S001', phrase: 'P01', who: 'k', uploaded: false, daysAgo: 3)
    ]));
    expect(old.single.isStuck, isTrue);
    expect(old.single.days.length, 1);
  });

  test('rejected clips are not counted against a collector', () {
    final s = statsOf([
      clip(speaker: 'S001', phrase: 'P01', who: 'k'),
      clip(
          speaker: 'S001',
          phrase: 'P02',
          who: 'k',
          uploaded: false,
          status: 'rejected'),
    ]);
    final r = collectorsOf(s).single;
    expect(r.total, 1);
    expect(r.waiting, isEmpty);
  });

  test('framing is averaged per collector', () {
    final s = statsOf([
      clip(speaker: 'S001', phrase: 'P01', who: 'k'),
      clip(speaker: 'S001', phrase: 'P02', who: 'k', qc: 'warn'),
    ]);
    final r = collectorsOf(s).single;
    expect(r.flagged, 1);
    expect(r.avgFace, closeTo(0.9, 0.001));
  });
}
