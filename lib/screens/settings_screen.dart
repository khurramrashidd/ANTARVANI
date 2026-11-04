import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app/l10n.dart';
import '../app/settings.dart';
import '../services/auth_service.dart';
import '../services/weather_service.dart';
import '../widgets/common.dart';
import 'home_shell.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppSettings.instance;
    final me = AuthService.instance.profile;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      children: [
        SectionTitle(tr('account')),
        Card(
          child: ListTile(
            leading: CircleAvatar(
              backgroundImage:
                  me?.photoUrl == null ? null : NetworkImage(me!.photoUrl!),
              child: me?.photoUrl == null ? const Icon(Icons.person) : null,
            ),
            title: Text(me?.name ?? ''),
            subtitle: Text('${me?.email ?? ''}\n${tr(me?.roleKey ?? 'role_patient')}'),
            isThreeLine: true,
          ),
        ),
        SectionTitle(tr('appearance')),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.dark_mode_outlined),
                title: Text(tr('dark_mode')),
                value: s.dark,
                onChanged: s.setDark,
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.translate),
                      const SizedBox(width: 16),
                      Text(tr('language')),
                    ]),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<String>(
                        showSelectedIcon: false,
                        segments: AppSettings.languages.entries
                            .map((e) => ButtonSegment(
                                value: e.key, label: Text(e.value)))
                            .toList(),
                        selected: {s.lang},
                        onSelectionChanged: (v) => s.setLang(v.first),
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.my_location),
                title: Text(tr('location_off')),
                onTap: () =>
                    WeatherService.instance.refresh(askPermission: true),
              ),
            ],
          ),
        ),
        SectionTitle(tr('about')),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const BrandLogo(size: 48),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr('app_name'),
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w800)),
                        FutureBuilder<PackageInfo>(
                          future: PackageInfo.fromPlatform(),
                          builder: (context, v) => Text(
                              v.hasData
                                  ? 'v${v.data!.version} (${v.data!.buildNumber})'
                                  : '',
                              style: Theme.of(context).textTheme.bodySmall),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(tr('about_body'), style: const TextStyle(height: 1.4)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () async {
            HomeShell.lastPage = Dest.home;
            await AuthService.instance.signOut();
          },
          icon: const Icon(Icons.logout),
          label: Text(tr('menu_signout')),
        ),
      ],
    );
  }
}
