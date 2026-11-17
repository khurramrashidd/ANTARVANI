import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../phrases.dart';
import '../services/auth_service.dart';
import '../services/language_service.dart';
import '../services/model_service.dart';

/// Which language the team is recording, and (for admins) adding a new one.
class LanguagesCard extends StatefulWidget {
  const LanguagesCard({super.key});

  @override
  State<LanguagesCard> createState() => _LanguagesCardState();
}

class _LanguagesCardState extends State<LanguagesCard> {
  final _source = TextEditingController();
  bool _open = false;
  bool _busy = false;

  @override
  void dispose() {
    _source.dispose();
    super.dispose();
  }

  void _say(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _use(String code) async {
    final why = await LanguageService.instance.use(code);
    if (why != null) _say(why);
  }

  Future<void> _add() async {
    if (_source.text.trim().isEmpty) {
      _say('Paste the link of the phrases file, or the JSON itself.');
      return;
    }
    setState(() => _busy = true);
    final (message, ok) = await LanguageService.instance.add(_source.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _source.clear();
        _open = false;
      }
    });
    _say(message);
  }

  @override
  Widget build(BuildContext context) {
    final svc = LanguageService.instance;
    final admin = AuthService.instance.profile?.isAdmin ?? false;
    return AnimatedBuilder(
      animation: svc,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Card(
          child: Column(
            children: [
              ListTile(
                dense: true,
                leading: const Icon(Icons.translate, color: Brand.indigo),
                title: const Text('Languages',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('Recording ${svc.current.name} · '
                    '${svc.current.phrases.length} phrases'),
                trailing: Icon(_open ? Icons.expand_less : Icons.expand_more),
                onTap: () => setState(() => _open = !_open),
              ),
              if (_open)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Everything on this phone — the phrases you record, '
                        'the Drive folder they go to, this dashboard and the '
                        'Speak screen — follows the language chosen here.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final l in svc.languages)
                            ChoiceChip(
                              label: Text('${l.name} (${l.code})'),
                              selected: l.code == svc.code,
                              onSelected: (_) => _use(l.code),
                            ),
                        ],
                      ),
                      if (admin) ...[
                        const Divider(height: 28),
                        Text(
                          'Add a language: fill in '
                          'pipeline/languages/TEMPLATE.json, put it somewhere '
                          'with a link (GitHub works), and paste the link — '
                          'or paste the JSON text itself. The phrase count '
                          'cannot change after recording starts.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _source,
                          minLines: 1,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            labelText: 'Link or JSON',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: _busy ? null : _add,
                          icon: const Icon(Icons.add),
                          label: Text(_busy ? 'Adding…' : 'Add language'),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Admins: put a newly trained model on every phone.
class PublishModelCard extends StatefulWidget {
  const PublishModelCard({super.key});

  @override
  State<PublishModelCard> createState() => _PublishModelCardState();
}

class _PublishModelCardState extends State<PublishModelCard> {
  final _link = TextEditingController();
  bool _open = false;
  bool _busy = false;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  void _say(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _publish() async {
    final models = ModelService.instance;
    setState(() => _busy = true);
    final (card, why) = await models.inspect(_link.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (card == null) {
      _say(why ?? 'That link cannot be used.');
      return;
    }
    final old = models.published[card.lang];
    final known = PhraseBook.all[card.lang];
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Publish ${card.name} model v${card.version}?'),
        content: Text([
          '${card.labels.length} phrases · ${card.speakers} speakers · '
              '${card.clips} clips',
          card.top1 == null
              ? 'Not evaluated (pipeline test only).'
              : 'On speakers it never saw: '
                  '${(card.top1! * 100).toStringAsFixed(1)}% first guess, '
                  '${((card.top3 ?? 0) * 100).toStringAsFixed(1)}% in the '
                  'top three.',
          'Trained ${card.trainedAt}. '
              '${(card.sizeBytes / 1e6).toStringAsFixed(1)} MB. '
              'Downloaded and checksum verified just now.',
          if (old != null)
            'Replaces v${old.version} (${old.summary}).'
          else
            'This is the first ${card.name} model.',
          if (old != null && old.top1 != null && card.top1 != null &&
              card.top1! < old.top1!)
            'WARNING: this model scored lower than the one it replaces.',
          if (known != null && known.phrases.length != card.labels.length)
            'WARNING: the app lists ${known.phrases.length} phrases for '
                '${card.name}, this model knows ${card.labels.length}.',
          'Every phone using ${card.name} downloads it by itself the next '
              'time it is online. No new APK is needed.',
        ].join('\n\n')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Publish')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    final failed = await models.publish(card);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (failed == null) {
        _link.clear();
        _open = false;
      }
    });
    _say(failed ?? '${card.name} model v${card.version} is live.');
  }

  Future<void> _withdraw(ModelCard card) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Withdraw the ${card.name} model?'),
        content: const Text(
            'Phones that already have it keep using it until another model '
            'is published; phones that do not will show "no model yet". '
            'To go back to an older model, publish its link again instead.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Withdraw')),
        ],
      ),
    );
    if (go != true) return;
    final failed = await ModelService.instance.withdraw(card.lang);
    _say(failed ?? 'Withdrawn.');
  }

  @override
  Widget build(BuildContext context) {
    final models = ModelService.instance;
    return AnimatedBuilder(
      animation: models,
      builder: (context, _) {
        final live = models.published.values.toList()
          ..sort((a, b) => a.lang.compareTo(b.lang));
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Card(
            child: Column(
              children: [
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.model_training, color: Brand.teal),
                  title: const Text('Publish a model',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(live.isEmpty
                      ? 'No recognition model is live yet'
                      : live.map((c) => '${c.name} v${c.version}').join(' · ')),
                  trailing:
                      Icon(_open ? Icons.expand_less : Icons.expand_more),
                  onTap: () => setState(() => _open = !_open),
                ),
                if (_open)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final c in live)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text('${c.name}: ${c.summary}'),
                            subtitle: Text('trained ${c.trainedAt}'),
                            trailing: IconButton(
                              tooltip: 'Withdraw',
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: () => _withdraw(c),
                            ),
                          ),
                        Text(
                          'Run the Colab notebook. It ends by printing a '
                          'link to the model card (…json). Paste it here. '
                          'The app downloads the model first to check the '
                          'link and the checksum, then asks you to confirm.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _link,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(
                            labelText: 'Model card link (ends in .json)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          onPressed: _busy ? null : _publish,
                          icon: const Icon(Icons.cloud_upload_outlined),
                          label: Text(_busy ? 'Checking…' : 'Check and publish'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
