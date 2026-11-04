import 'package:flutter_test/flutter_test.dart';

import 'package:silent_voice_recorder/app/l10n.dart';
import 'package:silent_voice_recorder/models.dart';
import 'package:silent_voice_recorder/phrases.dart';
import 'package:silent_voice_recorder/services/drive_uploader.dart';
import 'package:silent_voice_recorder/services/id_allocator.dart';
import 'package:silent_voice_recorder/services/participant_service.dart';
import 'package:silent_voice_recorder/services/team.dart';

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
}
