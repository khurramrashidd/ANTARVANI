import 'dart:async';

import 'package:flutter/material.dart';

import '../app/l10n.dart';
import '../app/settings.dart';
import '../app/theme.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';
import '../services/team.dart';
import '../services/weather_service.dart';
import 'chat_screen.dart';
import 'dashboard_screen.dart';
import 'import_screen.dart';
import 'patient/board_screen.dart';
import 'patient/caregiver_screen.dart';
import 'patient/history_screen.dart';
import 'patient/my_clips_screen.dart';
import 'patient/home_screen.dart';
import 'patient/personalise_screen.dart';
import 'patient/speak_screen.dart';
import 'patient/type_screen.dart';
import 'settings_screen.dart';
import 'setup_screen.dart';
import 'users_screen.dart';

enum Dest {
  home('menu_home', Icons.home_outlined, Icons.home),
  speak('menu_speak', Icons.record_voice_over_outlined,
      Icons.record_voice_over),
  board('menu_board', Icons.grid_view, Icons.grid_view),
  type('menu_type', Icons.keyboard_outlined, Icons.keyboard),
  personalise('menu_personalise', Icons.tune_outlined, Icons.tune),
  history('menu_history', Icons.history_outlined, Icons.history),
  caregiver('menu_caregiver', Icons.health_and_safety_outlined,
      Icons.health_and_safety),
  myClips('menu_my_clips', Icons.badge_outlined, Icons.badge),
  newSession('menu_new_session', Icons.videocam_outlined, Icons.videocam),
  corpus('menu_corpus', Icons.insights_outlined, Icons.insights),
  chat('menu_chat', Icons.forum_outlined, Icons.forum),
  importDrive('menu_import', Icons.download_outlined, Icons.download),
  users('menu_users', Icons.manage_accounts_outlined, Icons.manage_accounts),
  settings('menu_settings', Icons.settings_outlined, Icons.settings);

  final String key;
  final IconData icon;
  final IconData selectedIcon;
  const Dest(this.key, this.icon, this.selectedIcon);

  bool get teamOnly => this == newSession || this == corpus || this == chat;
  bool get adminOnly => this == users || this == importDrive;
  bool get inCollect => teamOnly || this == importDrive;
}

/// The main app: one page at a time, chosen from the sidebar.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  /// Survives a language change, which rebuilds the whole tree.
  static Dest lastPage = Dest.home;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  Dest _page = HomeShell.lastPage;

  void go(Dest d) {
    setState(() => _page = d);
    HomeShell.lastPage = d;
  }

  @override
  void initState() {
    super.initState();
    WeatherService.instance.refresh(askPermission: true);
  }

  Widget _body(AppUser me) {
    if (_page.teamOnly && !me.isTeam) return const _Locked();
    if (_page.adminOnly && !me.isAdmin) return const _Locked();
    switch (_page) {
      case Dest.home:
        return PatientHome(onOpen: go);
      case Dest.speak:
        return const SpeakScreen();
      case Dest.board:
        return const BoardScreen();
      case Dest.type:
        return const TypeScreen();
      case Dest.personalise:
        return const PersonaliseScreen();
      case Dest.history:
        return const HistoryScreen();
      case Dest.caregiver:
        return const CaregiverScreen();
      case Dest.myClips:
        return const MyClipsScreen();
      case Dest.newSession:
        return const SetupScreen();
      case Dest.corpus:
        return const DashboardScreen();
      case Dest.chat:
        return const ChatScreen();
      case Dest.importDrive:
        return const ImportScreen();
      case Dest.users:
        return const UsersScreen();
      case Dest.settings:
        return const SettingsScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = AuthService.instance;
    return AnimatedBuilder(
      animation: auth,
      builder: (context, _) {
        final me = auth.profile;
        if (me == null) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        return PopScope(
          canPop: _page == Dest.home,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) go(Dest.home);
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(_page == Dest.home ? tr('app_name') : tr(_page.key)),
              actions: [
                if (me.isTeam) const _UploadChip(),
                IconButton(
                  tooltip: tr('dark_mode'),
                  onPressed: () =>
                      AppSettings.instance.setDark(!AppSettings.instance.dark),
                  icon: Icon(AppSettings.instance.dark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined),
                ),
              ],
            ),
            drawer: AppDrawer(me: me, current: _page, onSelect: (d) {
              Navigator.of(context).pop();
              go(d);
            }),
            body: _body(me),
          ),
        );
      },
    );
  }
}

class _Locked extends StatelessWidget {
  const _Locked();

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 48),
              const SizedBox(height: 12),
              Text(tr('collect_locked'), textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}

class _UploadChip extends StatelessWidget {
  const _UploadChip();

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.instance;
    return AnimatedBuilder(
      animation: sync,
      builder: (context, _) => sync.pendingCount == 0
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.cloud_upload, size: 16),
                  label: Text('${sync.pendingCount}'),
                ),
              ),
            ),
    );
  }
}

// ======================================================================
//  Sidebar
// ======================================================================
class AppDrawer extends StatelessWidget {
  final AppUser me;
  final Dest current;
  final ValueChanged<Dest> onSelect;

  const AppDrawer({
    super.key,
    required this.me,
    required this.current,
    required this.onSelect,
  });

  Widget _item(BuildContext context, Dest d) {
    final selected = d == current;
    return ListTile(
      leading: Icon(selected ? d.selectedIcon : d.icon),
      title: Text(tr(d.key)),
      selected: selected,
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      selectedTileColor:
          Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.6),
      onTap: () => onSelect(d),
    );
  }

  Widget _label(BuildContext context, String key) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(tr(key).toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 1.2,
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return Drawer(
      child: Column(
        children: [
          _DrawerHeader(me: me),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                _item(context, Dest.home),
                _label(context, 'sec_patient'),
                for (final d in [
                  Dest.speak,
                  Dest.board,
                  Dest.type,
                  Dest.personalise,
                  Dest.history,
                  Dest.caregiver,
                  Dest.myClips,
                ])
                  _item(context, d),
                if (me.isTeam) ...[
                  const Divider(),
                  Theme(
                    data: Theme.of(context)
                        .copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      initiallyExpanded: current.inCollect,
                      leading: const Icon(Icons.video_library_outlined),
                      title: Text(tr('sec_collect'),
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      childrenPadding: const EdgeInsets.only(left: 12),
                      children: [
                        _item(context, Dest.newSession),
                        _item(context, Dest.corpus),
                        _item(context, Dest.chat),
                        if (me.isAdmin) _item(context, Dest.importDrive),
                      ],
                    ),
                  ),
                ],
                if (me.isAdmin) ...[
                  _label(context, 'sec_admin'),
                  _item(context, Dest.users),
                ],
                const Divider(),
                _item(context, Dest.settings),
                SwitchListTile(
                  dense: true,
                  secondary: const Icon(Icons.dark_mode_outlined),
                  title: Text(tr('dark_mode')),
                  value: settings.dark,
                  onChanged: settings.setDark,
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.translate),
                  title: Text(tr('language')),
                  trailing: DropdownButton<String>(
                    value: settings.lang,
                    underline: const SizedBox.shrink(),
                    items: AppSettings.languages.entries
                        .map((e) =>
                            DropdownMenuItem(value: e.key, child: Text(e.value)))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) settings.setLang(v);
                    },
                  ),
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.logout),
                  title: Text(tr('menu_signout')),
                  onTap: () async {
                    Navigator.of(context).pop();
                    HomeShell.lastPage = Dest.home;
                    await AuthService.instance.signOut();
                  },
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DrawerHeader extends StatelessWidget {
  final AppUser me;
  const _DrawerHeader({required this.me});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(gradient: Brand.gradient),
      padding: EdgeInsets.fromLTRB(
          20, MediaQuery.of(context).padding.top + 18, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: Colors.white24,
                backgroundImage:
                    me.photoUrl == null ? null : NetworkImage(me.photoUrl!),
                child: me.photoUrl == null
                    ? Text(me.name.isEmpty ? '?' : me.name[0].toUpperCase(),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.bold))
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(me.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Brand.amber,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(tr(me.roleKey),
                          style: const TextStyle(
                              color: Brand.indigo,
                              fontSize: 11,
                              fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const _Clock(),
          const SizedBox(height: 8),
          const _WeatherLine(),
        ],
      ),
    );
  }
}

class _Clock extends StatefulWidget {
  const _Clock();

  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  late Timer _t;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 15),
        (_) => setState(() => _now = DateTime.now()));
  }

  @override
  void dispose() {
    _t.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = _now.hour % 12 == 0 ? 12 : _now.hour % 12;
    final m = _now.minute.toString().padLeft(2, '0');
    final ampm = _now.hour < 12 ? 'AM' : 'PM';
    final date =
        '${weekdays[_now.weekday - 1]}, ${_now.day} ${months[_now.month - 1]} ${_now.year}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('$h:$m',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.w300,
                height: 1)),
        const SizedBox(width: 4),
        Text(ampm,
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(date,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
        ),
      ],
    );
  }
}

class _WeatherLine extends StatelessWidget {
  const _WeatherLine();

  IconData _icon(String key) => switch (key) {
        'w_clear' => Icons.wb_sunny_outlined,
        'w_fog' => Icons.blur_on,
        'w_drizzle' || 'w_rain' => Icons.water_drop_outlined,
        'w_snow' => Icons.ac_unit,
        'w_storm' => Icons.flash_on,
        _ => Icons.cloud_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final w = WeatherService.instance;
    return AnimatedBuilder(
      animation: w,
      builder: (context, _) {
        const style = TextStyle(color: Colors.white, fontSize: 13);
        if (w.hasData) {
          return Row(
            children: [
              Icon(_icon(w.conditionKey), color: Brand.amber, size: 20),
              const SizedBox(width: 6),
              Text('${w.tempC!.round()}°C · ${tr(w.conditionKey)}',
                  style: style),
              if (w.city != null) ...[
                const SizedBox(width: 10),
                const Icon(Icons.place_outlined, color: Colors.white70, size: 16),
                const SizedBox(width: 2),
                Flexible(
                  child: Text(w.city!,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                ),
              ],
            ],
          );
        }
        if (w.locationDenied) {
          return InkWell(
            onTap: () => w.refresh(askPermission: true),
            child: Row(
              children: [
                const Icon(Icons.location_off_outlined,
                    color: Colors.white70, size: 18),
                const SizedBox(width: 6),
                Text(tr('location_off'), style: style),
              ],
            ),
          );
        }
        return Text(tr('weather_loading'), style: style);
      },
    );
  }
}
