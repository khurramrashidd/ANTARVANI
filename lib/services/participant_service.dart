import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'team.dart';

/// Lets a volunteer who was recorded see their own clips.
///
/// They prove who they are by typing both numbers from their consent form —
/// the speaker ID and the form number. The app does not read the speaker row
/// first (it is not allowed to); it writes the typed form number as
/// `claimProof`, and the security rules accept the write only if it matches
/// the form number stored on that row. So a wrong guess is refused by the
/// server, and nobody can walk through S001, S002, S003 fishing for names.
///
/// Once the claim sticks, the rules let that account read its own speaker row
/// and its own clips, and nothing else.
class ParticipantService {
  static final ParticipantService instance = ParticipantService._();
  ParticipantService._();

  static const _kClaimed = 'claimed_speaker_ids';
  static const _kLegacy = 'claimed_speaker_id'; // single id, older builds

  static FirebaseFirestore get _db => FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> get _speakers =>
      _db.collection('speakers');
  static CollectionReference<Map<String, dynamic>> get _clips =>
      _db.collection('clips');

  /// Every session this account has linked. Someone can be recorded more than
  /// once — as a volunteer early on and again for the ten-take set — and a
  /// collector may want to look up their own alongside someone else's.
  Future<List<String>> claimed() async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_kClaimed);
    if (list != null) return list;
    // Carry over the single id older builds stored.
    final one = p.getString(_kLegacy);
    if (one == null) return const [];
    await p.setStringList(_kClaimed, [one]);
    await p.remove(_kLegacy);
    return [one];
  }

  Future<void> forget(String speakerId) async {
    final p = await SharedPreferences.getInstance();
    final list = (await claimed()).where((e) => e != speakerId).toList();
    await p.setStringList(_kClaimed, list);
  }

  /// Tidies what people actually type: "s14" -> "S014", "f 14" -> "F014".
  static String normalise(String input, String prefix) {
    final digits = RegExp(r'\d+').firstMatch(input.trim());
    if (digits == null) return input.trim().toUpperCase();
    final n = int.parse(digits.group(0)!);
    return '$prefix${n.toString().padLeft(3, '0')}';
  }

  /// Returns null on success, or a message to show.
  Future<String?> claim({
    required String speakerId,
    required String formNo,
  }) async {
    if (!Team.signedIn) return 'Sign in first.';
    final sid = normalise(speakerId, 'S');
    final fno = normalise(formNo, 'F');
    if (!RegExp(r'^S\d{3,}$').hasMatch(sid) ||
        !RegExp(r'^F\d{3,}$').hasMatch(fno)) {
      return 'Those do not look like the numbers on the form.';
    }

    try {
      await _speakers.doc(sid).set({
        'claimedBy': Team.email,
        'claimedAt': FieldValue.serverTimestamp(),
        'claimProof': fno,
      }, SetOptions(merge: true));
      final p = await SharedPreferences.getInstance();
      final list = await claimed();
      if (!list.contains(sid)) {
        await p.setStringList(_kClaimed, [...list, sid]);
      }
      return null;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        // Either the pair does not match, or someone else already linked it.
        return 'Those two numbers do not match any recording session. '
            'Check both numbers on your form — they look like S014 and F014 '
            'and the digits are the same.';
      }
      debugPrint('claim failed: ${e.code}');
      return 'Could not check right now (${e.code}). Try again in a moment.';
    } catch (e) {
      return 'Could not check right now. Check your internet and try again.';
    }
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> watchSpeaker(String id) =>
      _speakers.doc(id).snapshots();

  Stream<QuerySnapshot<Map<String, dynamic>>> watchClips(String id) =>
      _clips.where('speakerId', isEqualTo: id).snapshots();

  /// The volunteer asks for their clips to be removed. The team sees this on
  /// the dashboard; the rules let the claimant set only these two fields.
  Future<String?> requestDeletion(String speakerId) async {
    try {
      await _speakers.doc(speakerId).set({
        'deletionRequested': true,
        'deletionRequestedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return null;
    } catch (e) {
      return 'Could not send the request: $e';
    }
  }
}
