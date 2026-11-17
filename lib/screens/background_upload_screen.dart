import 'dart:async';

import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../services/background_upload.dart';
import '../services/sync_service.dart';
import 'collectors_tab.dart' show agoText;

/// Setting up uploads that carry on after the app is closed.
///
/// Two of the three things on this page cannot be switched on by the app
/// itself — Android only lets the person do it — so the page is mostly about
/// saying clearly what to tap and why it matters.
class BackgroundUploadScreen extends StatelessWidget {
  const BackgroundUploadScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Background upload')),
        body: const SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 32),
          child: BackgroundUploadCard(),
        ),
      );
}

class BackgroundUploadCard extends StatefulWidget {
  const BackgroundUploadCard({super.key});

  @override
  State<BackgroundUploadCard> createState() => _BackgroundUploadCardState();
}

class _BackgroundUploadCardState extends State<BackgroundUploadCard> {
  bool _loading = true;
  bool _on = true;
  bool _mobile = true;
  bool _notify = false;
  bool _battery = false;
  bool _running = false;
  int _sent = 0;
  String _error = '';
  DateTime? _last;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final on = await BackgroundUpload.enabled();
    final mobile = await BackgroundUpload.mobileDataAllowed();
    final notify = await BackgroundUpload.hasNotificationPermission();
    final battery = await BackgroundUpload.batteryExempt();
    final running = await BackgroundUpload.isRunning();
    final sent = await BackgroundUpload.uploadedInBackground();
    final error = await BackgroundUpload.lastError();
    final last = await BackgroundUpload.lastRun();
    if (!mounted) return;
    setState(() {
      _on = on;
      _mobile = mobile;
      _notify = notify;
      _battery = battery;
      _running = running;
      _sent = sent;
      _error = error;
      _last = last;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final small = Theme.of(context).textTheme.bodySmall;
    final ready = _on && _notify && _battery;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          color: ready
              ? const Color(0x222E7D32)
              : Brand.amber.withValues(alpha: 0.15),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(ready ? Icons.check_circle : Icons.warning_amber_rounded,
                    color: ready ? const Color(0xFF2E7D32) : Brand.urgent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    ready
                        ? 'Clips will keep uploading after you close the app.'
                        : 'Uploads stop when you close the app. Finish the '
                            'steps below.',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              SwitchListTile(
                value: _on,
                title: const Text('Upload in the background'),
                subtitle: const Text(
                    'Keeps sending clips to Drive once the app is closed. '
                    'A notification shows while it works — Android requires '
                    'it, and it is how you know it is running.'),
                onChanged: (v) async {
                  await BackgroundUpload.setEnabled(v);
                  await _load();
                },
              ),
              const Divider(height: 1),
              SwitchListTile(
                value: _mobile,
                title: const Text('Use mobile data as well as WiFi'),
                subtitle: Text(
                    'Clips are about 3 MB each, so 20 clips is roughly 60 MB. '
                    'Turn this off to wait for WiFi.',
                    style: small),
                onChanged: _on
                    ? (v) async {
                        await BackgroundUpload.setMobileDataAllowed(v);
                        await _load();
                      }
                    : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _Step(
          n: 1,
          title: 'Allow notifications',
          body: 'Android will not let anything run in the background without '
              'a notification to show for it.',
          done: _notify,
          action: 'Allow',
          onTap: () async {
            await BackgroundUpload.askNotificationPermission();
            await _load();
          },
        ),
        _Step(
          n: 2,
          title: 'Turn off battery optimisation',
          body: 'This is the one that actually matters. On Realme, Redmi, '
              'Oppo and Vivo the upload is killed within minutes of the '
              'screen going off unless ANTARVANI is exempt. Choose '
              '"Don\'t optimise" or "Allow".',
          done: _battery,
          action: 'Fix',
          onTap: () async {
            await BackgroundUpload.askBatteryExempt();
            await _load();
          },
        ),
        _Step(
          n: 3,
          title: 'Turn on Autostart',
          body: 'Only on Realme, Redmi, Oppo and Vivo. No app is allowed to '
              'switch this on, so it has to be done by hand: open the app '
              'settings, find Autostart or "Allow background activity", and '
              'switch it on.',
          done: null,
          action: 'Open settings',
          onTap: () => BackgroundUpload.openPhoneSettings(),
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Status',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                AnimatedBuilder(
                  animation: SyncService.instance,
                  builder: (context, _) => Text(
                    '${SyncService.instance.pendingCount} clip(s) on this '
                    'phone right now',
                    style: small,
                  ),
                ),
                Text('$_sent clip(s) sent in the background so far',
                    style: small),
                Text(
                    _running
                        ? 'The service is running now'
                        : 'Last background run: ${agoText(_last)}',
                    style: small),
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Last problem: $_error',
                      style: small?.copyWith(color: Brand.urgent)),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: () async {
                        await SyncService.instance.drainQueue();
                        await _load();
                      },
                      icon: const Icon(Icons.cloud_upload),
                      label: const Text('Upload now'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                        onPressed: _load, child: const Text('Refresh')),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Even with all of this, a phone that is switched off or out of '
          'signal cannot upload. The Collectors tab on the dashboard shows '
          'what is still waiting and on whose phone.',
          style: small,
        ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  final int n;
  final String title;
  final String body;

  /// null when the app cannot tell whether it is done.
  final bool? done;
  final String action;
  final VoidCallback onTap;

  const _Step({
    required this.n,
    required this.title,
    required this.body,
    required this.done,
    required this.action,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ok = done == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 13,
              backgroundColor: ok ? const Color(0xFF2E7D32) : Brand.indigo,
              child: ok
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : Text('$n',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(body, style: Theme.of(context).textTheme.bodySmall),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: onTap,
                      child: Text(ok ? 'Check again' : action),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
