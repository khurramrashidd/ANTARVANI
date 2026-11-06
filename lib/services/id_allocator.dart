import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'team.dart';

/// Speaker IDs and consent-form numbers from ONE shared counter in Firestore.
///
/// S001, S002, S003 … in the order sessions start, across any number of
/// collectors. A Firestore transaction bumps `counters/speakers` and creates
/// `speakers/Sxxx` in the same step, so two phones pressing Start at the same
/// second still get different numbers.
///
/// A number that produced no clips is handed straight back: the speaker row is
/// deleted and the number goes into `counters/speakers.free`, which the next
/// session pops from before taking a new one. So a cancelled or abandoned
/// session leaves no gap and no dead ID — nothing stays "cancelled".
///
/// Needs internet for those few seconds. Recording afterwards works offline.
/// The form number mirrors the speaker number: S014 <-> F014.
class IdAllocator {
  static FirebaseFirestore get _db => FirebaseFirestore.instance;
  static DocumentReference<Map<String, dynamic>> get _counter =>
      _db.collection('counters').doc('speakers');
  static CollectionReference<Map<String, dynamic>> get _speakers =>
      _db.collection('speakers');

  /// Highest number already used — only consulted the very first time, so the
  /// counter starts after any speakers recorded by older builds.
  static Future<int> _highestExisting() async {
    final q = await _speakers.get(const GetOptions(source: Source.server));
    var max = 0;
    for (final d in q.docs) {
      final n = SessionIds.parse(d.id);
      if (n != null && n > max) max = n;
    }
    return max;
  }

  static List<int> _freeList(Map<String, dynamic>? data) {
    final raw = (data?['free'] as List?) ?? const [];
    final out = raw
        .map((e) => (e as num).toInt())
        .where((n) => n > 0)
        .toSet()
        .toList()
      ..sort();
    return out;
  }

  /// Reserves the next number — a recycled one first, otherwise a new one.
  /// Throws [IdAllocationError] with a message the collector can act on.
  static Future<SessionIds> allocate({required String deviceId}) async {
    final conn = await Connectivity().checkConnectivity();
    if (conn.every((c) => c == ConnectivityResult.none)) {
      throw const IdAllocationError(
          'No internet. Getting a speaker ID needs a connection for a few '
          'seconds — connect to Wi-Fi or mobile data and press Start again.');
    }

    try {
      final current = await _counter
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 12));
      final seed = current.exists ? 0 : await _highestExisting();
      // Made once, outside the transaction: Firestore may run the body more
      // than once, and the code must be the one that was committed.
      final code = newCode();

      final n = await _db.runTransaction<int>((tx) async {
        final snap = await tx.get(_counter);
        final data = snap.data();
        final free = _freeList(data);
        final last = (data?['last'] as num?)?.toInt() ?? seed;

        // Smallest returned number first, so the set stays dense.
        final next = nextNumber(free: free, last: last);
        free.remove(next);
        final ids = SessionIds(next, code);

        tx.set(_counter, {
          'last': next > last ? next : last,
          'free': free,
          'updatedAt': FieldValue.serverTimestamp(),
          'updatedBy': Team.email,
        }, SetOptions(merge: true));

        tx.set(_speakers.doc(ids.speakerId), {
          'speakerId': ids.speakerId,
          'consentFormId': ids.formNo,
          // Written on the paper form by hand. Without it, "both numbers"
          // proved nothing: F014 is just S014 with the letter changed, so
          // anyone who saw one could work out the other.
          'accessCode': ids.code,
          'number': next,
          'status': 'in_progress',
          'collectorEmail': Team.email,
          'collectorName': Team.displayName,
          'deviceId': deviceId,
          'createdAt': FieldValue.serverTimestamp(),
        });
        return next;
      }, timeout: const Duration(seconds: 15));

      return SessionIds(n, code);
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw const IdAllocationError(
            'Not allowed to create speakers. Ask the master admin to make '
            'you a Collector in Users & roles.');
      }
      throw IdAllocationError('Could not get a speaker ID (${e.code}). '
          'Check the connection and press Start again.');
    } catch (e) {
      throw IdAllocationError('Could not get a speaker ID: $e');
    }
  }

  /// The alphabet leaves out anything that is misread in handwriting: no
  /// O or 0, no I, 1 or L, no S or 5, no B or 8, no Z or 2.
  static const _alphabet = 'ACDEFGHJKMNPQRTUVWXY3467';
  static final _rng = Random.secure();

  static String newCode() => List.generate(
      4, (_) => _alphabet[_rng.nextInt(_alphabet.length)]).join();

  /// Uppercase, no spaces — people write these by hand.
  static String tidyCode(String input) =>
      input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// Which number comes next: the smallest one handed back, otherwise one
  /// past the highest ever issued. Pure, so it can be tested.
  static int nextNumber({required List<int> free, required int last}) {
    if (free.isEmpty) return last + 1;
    return free.reduce((a, b) => a < b ? a : b);
  }

  /// Hands numbers back. The speaker rows are deleted and the numbers go into
  /// the free list for the next person. Only ever call this for speakers with
  /// no clips — releasing one that has clips would orphan them.
  static Future<void> release(Iterable<String> speakerIds) async {
    final numbers = speakerIds
        .map(SessionIds.parse)
        .whereType<int>()
        .toSet()
        .toList();
    if (numbers.isEmpty) return;

    final batch = _db.batch();
    for (final n in numbers) {
      batch.delete(_speakers.doc(SessionIds(n).speakerId));
    }
    batch.set(_counter, {
      'free': FieldValue.arrayUnion(numbers),
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': Team.email,
    }, SetOptions(merge: true));
    await batch.commit();
  }

  /// The number the next session will get: the smallest returned one, or one
  /// past the highest ever issued.
  static Stream<SessionIds?> watchNext() => _counter.snapshots().map((d) {
        if (!d.exists) return null;
        final free = _freeList(d.data());
        final last = (d.data()?['last'] as num?)?.toInt() ?? 0;
        return SessionIds(nextNumber(free: free, last: last));
      });

  /// Numbers waiting to be reused.
  static Stream<List<int>> watchFree() =>
      _counter.snapshots().map((d) => _freeList(d.data()));

  /// How many numbers have ever been issued.
  static Stream<int> watchIssued() => _counter
      .snapshots()
      .map((d) => (d.data()?['last'] as num?)?.toInt() ?? 0);
}

class IdAllocationError implements Exception {
  final String message;
  const IdAllocationError(this.message);
  @override
  String toString() => message;
}

class SessionIds {
  final int number;

  /// Four characters the volunteer needs to see their own clips later.
  /// Empty for sessions recorded before access codes existed.
  final String code;

  const SessionIds(this.number, [this.code = '']);

  /// e.g. S014 (S1000 and up once past 999)
  String get speakerId => 'S${number.toString().padLeft(3, '0')}';

  /// e.g. F014 — write this on the paper consent form.
  String get formNo => 'F${number.toString().padLeft(3, '0')}';

  /// 'S014' -> 14; anything else -> null.
  static int? parse(String id) {
    final m = RegExp(r'^S(\d+)$').firstMatch(id);
    return m == null ? null : int.parse(m.group(1)!);
  }

  @override
  String toString() => '$speakerId / $formNo';
}
