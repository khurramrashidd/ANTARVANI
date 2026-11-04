import 'package:flutter/material.dart';

import '../app/l10n.dart';
import '../app/theme.dart';
import '../services/auth_service.dart';
import '../services/team.dart';

/// Admin: everyone who has signed in, live from Firestore. New people arrive
/// as Patients; promote collectors to Collector, and (master only) Admin.
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  String _q = '';

  Future<void> _setRole(AppUser u, String role) async {
    try {
      await Team.setRole(u.email, role);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${u.name} is now ${tr('role_$role')}')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Not allowed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = AuthService.instance.profile;
    return StreamBuilder<List<AppUser>>(
      stream: Team.watchUsers(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
              child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load users: ${snap.error}',
                textAlign: TextAlign.center),
          ));
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final q = _q.toLowerCase();
        final all = snap.data!
            .where((u) =>
                q.isEmpty ||
                u.email.contains(q) ||
                u.name.toLowerCase().contains(q))
            .toList();
        final team = all.where((u) => u.isTeam).toList();
        final others = all.where((u) => !u.isTeam).toList();

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            TextField(
              onChanged: (v) => setState(() => _q = v.trim()),
              decoration: const InputDecoration(
                hintText: 'Search name or email',
                prefixIcon: Icon(Icons.search),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Anyone who signs in appears here as a Patient. Make your team '
              'members Collectors so they can record. Only the master admin '
              'can make or remove Admins.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            _Header('Team (${team.length})'),
            for (final u in team) _UserTile(u: u, me: me, onRole: _setRole),
            _Header('Signed up — patients (${others.length})'),
            if (others.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Nobody yet. Ask your team to open the app and '
                    'tap Continue with Google — they will appear here.'),
              ),
            for (final u in others) _UserTile(u: u, me: me, onRole: _setRole),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
      );
}

class _UserTile extends StatelessWidget {
  final AppUser u;
  final AppUser? me;
  final Future<void> Function(AppUser, String) onRole;

  const _UserTile({required this.u, required this.me, required this.onRole});

  static String _ago(DateTime? t) {
    if (t == null) return 'never';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 2) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = !u.isMaster &&
        me != null &&
        me!.isAdmin &&
        (me!.isMaster || u.role != Roles.admin);
    final roles = [
      Roles.patient,
      Roles.member,
      if (me?.isMaster ?? false) Roles.admin,
    ];
    final roleColor = u.isAdmin
        ? Brand.indigo
        : u.isTeam
            ? Brand.teal
            : Colors.grey;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: ListTile(
          leading: CircleAvatar(
            backgroundImage:
                u.photoUrl == null ? null : NetworkImage(u.photoUrl!),
            child: u.photoUrl == null
                ? Text(u.name.isEmpty ? '?' : u.name[0].toUpperCase())
                : null,
          ),
          title: Text(u.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${u.email}\nseen ${_ago(u.lastSeen)}',
              maxLines: 2, overflow: TextOverflow.ellipsis),
          isThreeLine: true,
          trailing: canEdit
              ? PopupMenuButton<String>(
                  tooltip: 'Change role',
                  onSelected: (r) => onRole(u, r),
                  itemBuilder: (_) => roles
                      .map((r) => CheckedPopupMenuItem(
                          value: r,
                          checked: r == u.role,
                          child: Text(tr('role_$r'))))
                      .toList(),
                  child: _RoleChip(text: tr(u.roleKey), color: roleColor, edit: true),
                )
              : _RoleChip(text: tr(u.roleKey), color: roleColor, edit: false),
        ),
      ),
    );
  }
}

class _RoleChip extends StatelessWidget {
  final String text;
  final Color color;
  final bool edit;
  const _RoleChip({required this.text, required this.color, required this.edit});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text,
                style: TextStyle(
                    color: color, fontWeight: FontWeight.w700, fontSize: 12)),
            if (edit) Icon(Icons.arrow_drop_down, color: color, size: 18),
          ],
        ),
      );
}
