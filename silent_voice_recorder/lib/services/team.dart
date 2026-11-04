import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Roles, in increasing power:
///   patient  — anyone who signs in; uses the communication side
///   member   — a collector; also sees Collect data and Team chat
///   admin    — also approves people in Users & roles
///   master   — khurramrashid0786@gmail.com; the only one who can make or
///              remove admins, and can never be locked out
class Roles {
  static const patient = 'patient';
  static const member = 'member';
  static const admin = 'admin';
  static const all = [patient, member, admin];
}

/// One person, as stored in `users/{email}`.
class AppUser {
  final String email;
  final String name;
  final String? photoUrl;
  final String role;
  final DateTime? createdAt;
  final DateTime? lastSeen;

  const AppUser({
    required this.email,
    required this.name,
    required this.role,
    this.photoUrl,
    this.createdAt,
    this.lastSeen,
  });

  bool get isMaster => email == Team.masterEmail;
  bool get isAdmin => isMaster || role == Roles.admin;
  bool get isTeam => isAdmin || role == Roles.member;

  /// 'role_master', 'role_admin' … — a key for tr().
  String get roleKey => isMaster ? 'role_master' : 'role_$role';

  factory AppUser.fromMap(String email, Map<String, dynamic> m) => AppUser(
        email: email,
        name: (m['name'] as String?)?.trim().isNotEmpty == true
            ? (m['name'] as String).trim()
            : email.split('@').first,
        photoUrl: m['photoUrl'] as String?,
        role: Roles.all.contains(m['role']) ? m['role'] as String : Roles.patient,
        createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
        lastSeen: (m['lastSeen'] as Timestamp?)?.toDate(),
      );
}

/// Static helpers used across the app. Identity comes from Firebase Auth;
/// roles come from the `users` collection.
class Team {
  static const String masterEmail = 'khurramrashid0786@gmail.com';

  static FirebaseFirestore get _db => FirebaseFirestore.instance;
  static CollectionReference<Map<String, dynamic>> get users =>
      _db.collection('users');

  static User? get user => FirebaseAuth.instance.currentUser;
  static String? get email => user?.email?.toLowerCase();
  static bool get signedIn => user != null;
  static bool get isMaster => email == masterEmail;

  /// Display name, falling back to the part before the @ so nothing ever
  /// shows a blank author.
  static String get displayName {
    final n = user?.displayName;
    if (n != null && n.trim().isNotEmpty) return n.trim();
    final e = email;
    if (e != null && e.contains('@')) return e.split('@').first;
    return 'unknown';
  }

  /// Everyone who has ever signed in, newest first.
  static Stream<List<AppUser>> watchUsers() => users.snapshots().map((q) {
        final list =
            q.docs.map((d) => AppUser.fromMap(d.id, d.data())).toList();
        list.sort((a, b) => (b.createdAt ?? DateTime(2000))
            .compareTo(a.createdAt ?? DateTime(2000)));
        return list;
      });

  /// Rules allow admins to set patient/member; only the master may grant or
  /// remove admin.
  static Future<void> setRole(String userEmail, String role) =>
      users.doc(userEmail).set({
        'role': role,
        'roleSetBy': email,
        'roleSetAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
}
