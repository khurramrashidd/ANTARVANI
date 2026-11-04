import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'team.dart';

/// Sign-in and the signed-in person's profile.
///
/// Login asks Google only for name and email — nothing scary for a patient.
/// Drive access is asked for separately, and only from collectors, the first
/// time they open Collect data (see DriveUploader.connect).
class AuthService extends ChangeNotifier {
  static final AuthService instance = AuthService._();
  AuthService._();

  /// One GoogleSignIn for the whole app; DriveUploader adds the Drive scope
  /// to this same account later.
  final GoogleSignIn google = GoogleSignIn(scopes: const ['email']);

  StreamSubscription<User?>? _authSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _profileSub;

  bool _ready = false;
  AppUser? _profile;

  /// False until Firebase has told us whether someone is signed in.
  bool get ready => _ready;
  bool get signedIn => FirebaseAuth.instance.currentUser != null;
  AppUser? get profile => _profile;

  void start() {
    _authSub ??= FirebaseAuth.instance.authStateChanges().listen(_onAuth);
  }

  Future<void> _onAuth(User? u) async {
    await _profileSub?.cancel();
    _profileSub = null;
    if (u == null) {
      _profile = null;
      _ready = true;
      notifyListeners();
      return;
    }

    final email = (u.email ?? '').toLowerCase();
    // Until Firestore answers, act on what we know — so the app opens even
    // with no signal.
    _profile = AppUser(
      email: email,
      name: u.displayName ?? email.split('@').first,
      photoUrl: u.photoURL,
      role: email == Team.masterEmail ? Roles.admin : Roles.patient,
    );
    _ready = true;
    notifyListeners();

    // Not awaited: with no signal a Firestore write waits for the network.
    unawaited(_ensureProfile(u, email));
    _profileSub = Team.users.doc(email).snapshots().listen((d) {
      final data = d.data();
      if (data != null) {
        _profile = AppUser.fromMap(email, data);
        notifyListeners();
      }
    }, onError: (Object e) => debugPrint('profile stream: $e'));
  }

  /// Creates `users/{email}` the first time someone signs in (as a patient,
  /// or admin for the master); afterwards only refreshes name and last seen.
  Future<void> _ensureProfile(User u, String email) async {
    final ref = Team.users.doc(email);
    try {
      final snap = await ref.get();
      if (!snap.exists) {
        await ref.set({
          'email': email,
          'name': u.displayName ?? email.split('@').first,
          'photoUrl': u.photoURL,
          'role': email == Team.masterEmail ? Roles.admin : Roles.patient,
          'createdAt': FieldValue.serverTimestamp(),
          'lastSeen': FieldValue.serverTimestamp(),
        });
      } else {
        await ref.set({
          'name': u.displayName ?? email.split('@').first,
          'photoUrl': u.photoURL,
          'lastSeen': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('profile write failed (offline or rules): $e');
    }
  }

  /// Returns null on success, or a short reason on failure.
  Future<String?> signInWithGoogle() async {
    try {
      final acct = await google.signIn();
      if (acct == null) return 'cancelled';
      final auth = await acct.authentication;
      await FirebaseAuth.instance.signInWithCredential(
        GoogleAuthProvider.credential(
          idToken: auth.idToken,
          accessToken: auth.accessToken,
        ),
      );
      return null;
    } catch (e) {
      debugPrint('sign-in failed: $e');
      return '$e';
    }
  }

  Future<void> signOut() async {
    try {
      await google.signOut();
    } catch (_) {}
    await FirebaseAuth.instance.signOut();
  }
}
