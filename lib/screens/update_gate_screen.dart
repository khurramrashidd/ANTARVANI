import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/l10n.dart';
import '../app/theme.dart';
import '../services/auth_service.dart';
import '../services/release_service.dart';
import '../services/team.dart';
import '../widgets/common.dart';

/// Shown instead of the app when this phone is behind the published build.
///
/// There is deliberately no way past it — that is the point of the feature.
/// The one exception is the master admin, who can undo a release published
/// with the wrong number; without that, one typo would lock out the only
/// person able to fix it.
class UpdateGateScreen extends StatelessWidget {
  const UpdateGateScreen({super.key});

  Future<void> _download(BuildContext context) async {
    final r = ReleaseService.instance;
    if (r.url.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('update_no_link'))));
      return;
    }
    final uri = Uri.tryParse(r.url);
    if (uri == null ||
        !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(tr('update_no_link'))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = ReleaseService.instance;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(gradient: Brand.gradient),
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 28),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const BrandLogo(size: 84),
                        const SizedBox(height: 20),
                        Icon(Icons.system_update,
                            size: 44, color: Brand.amber),
                        const SizedBox(height: 12),
                        Text(
                          tr('update_title'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 26,
                              fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 22),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(tr('update_body'),
                                    style: const TextStyle(height: 1.45)),
                                const SizedBox(height: 18),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _Num(
                                        label: tr('update_installed'),
                                        value: r.localVersion.isEmpty
                                            ? '—'
                                            : '${r.localVersion} (${r.localBuild})',
                                      ),
                                    ),
                                    const Icon(Icons.arrow_forward, size: 18),
                                    Expanded(
                                      child: _Num(
                                        label: tr('update_needed'),
                                        value: r.requiredVersion.isEmpty
                                            ? 'build ${r.requiredBuild}'
                                            : '${r.requiredVersion} (${r.requiredBuild})',
                                        highlight: true,
                                      ),
                                    ),
                                  ],
                                ),
                                if (r.notes.isNotEmpty) ...[
                                  const Divider(height: 28),
                                  Text(tr('update_whats_new'),
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge),
                                  const SizedBox(height: 6),
                                  Text(r.notes,
                                      style: const TextStyle(height: 1.4)),
                                ],
                                const SizedBox(height: 22),
                                FilledButton.icon(
                                  onPressed: () => _download(context),
                                  icon: const Icon(Icons.download),
                                  label: Text(tr('update_download')),
                                ),
                                const SizedBox(height: 10),
                                Text(tr('update_after'),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall),
                                const SizedBox(height: 6),
                                Center(
                                  child: TextButton(
                                    // Firestore pushes changes by itself; this
                                    // is for the phone that just installed and
                                    // wants to move on now.
                                    onPressed: () =>
                                        ReleaseService.instance.start(),
                                    child: Text(tr('update_recheck')),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (Team.isMaster) ...[
                          const SizedBox(height: 18),
                          TextButton.icon(
                            style: TextButton.styleFrom(
                                foregroundColor: Colors.white70),
                            icon: const Icon(Icons.undo),
                            label: Text(tr('update_undo')),
                            onPressed: () => _undo(context),
                          ),
                        ],
                        const SizedBox(height: 14),
                        TextButton(
                          onPressed: () => AuthService.instance.signOut(),
                          child: Text(tr('menu_signout'),
                              style: const TextStyle(color: Colors.white70)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _undo(BuildContext context) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('update_undo')),
        content: const Text(
          'This clears the published release, so nobody is asked to update '
          'any more. Use it if you typed the wrong build number.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Undo')),
        ],
      ),
    );
    if (go != true) return;
    try {
      await ReleaseService.instance.clear();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not undo: $e')));
      }
    }
  }
}

class _Num extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;
  const _Num({required this.label, required this.value, this.highlight = false});

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(
            value,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 15,
              color: highlight ? Brand.teal : null,
            ),
          ),
        ],
      );
}
