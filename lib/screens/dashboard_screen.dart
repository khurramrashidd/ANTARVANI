import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app/theme.dart';
import '../models.dart';
import '../phrases.dart';
import '../services/auth_service.dart';
import '../services/drive_uploader.dart';
import '../services/id_allocator.dart';
import '../services/release_service.dart';
import '../services/sync_service.dart';
import '../services/team.dart';
import '../storage.dart';
import 'record_screen.dart';
import 'speaker_edit_screen.dart';

/// One clip row, read from Firestore.
class ClipView {
  final String docId;
  final String speakerId;
  final String phraseId;
  final int take;
  final String status; // ok | rejected
  final String qcVerdict; // pass | warn | fail
  final bool qcOverride;
  final bool uploaded;
  final String source; // app | import
  final int bytes;
  final String fileName;
  final String? driveFileId;
  final String? collectorEmail;
  final String collectorName;
  final String? rejectedReason;
  final String capturedUtc;

  ClipView(Map<String, dynamic> m, this.docId)
      : speakerId = m['speakerId'] as String? ?? '',
        phraseId = m['phraseId'] as String? ?? '',
        take = (m['take'] as num?)?.toInt() ?? 1,
        status = m['status'] as String? ?? 'ok',
        qcVerdict = m['qcVerdict'] as String? ?? 'pass',
        qcOverride = m['qcOverride'] as bool? ?? false,
        uploaded = m['uploaded'] as bool? ?? false,
        source = m['source'] as String? ?? 'app',
        bytes = (m['fileBytes'] as num?)?.toInt() ?? 0,
        fileName = m['fileName'] as String? ?? '$docId.mp4',
        driveFileId = m['driveFileId'] as String?,
        collectorEmail = m['collectorEmail'] as String?,
        collectorName = m['collectorName'] as String? ?? '—',
        rejectedReason = m['rejectedReason'] as String?,
        capturedUtc = m['capturedUtc'] as String? ?? '';

  bool get live => status == 'ok';

  /// Where it sits in Drive: "P03/S014_P03_t01.mp4".
  String get drivePath => DriveUploader.pathOf(phraseId, fileName);

  /// Local calendar day, for the per-day breakdown. '' when unknown.
  String get day {
    final t = DateTime.tryParse(capturedUtc);
    if (t == null) return '';
    final l = t.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-'
        '${l.day.toString().padLeft(2, '0')}';
  }
}

/// One speaker row, read from Firestore.
class SpeakerView {
  final String id;
  final Map<String, dynamic> raw;

  SpeakerView(this.id, this.raw);

  String get name => (raw['name'] as String?)?.trim() ?? '';
  String get formNo => raw['consentFormId'] as String? ?? '';
  String get tier => raw['tier'] as String? ?? 'A';
  String get status => raw['status'] as String? ?? 'complete';
  String get collectorName =>
      raw['collectorName'] as String? ?? raw['operator'] as String? ?? '—';
  String? get collectorEmail => raw['collectorEmail'] as String?;
  bool get publishable => raw['consentToPublishDataset'] == true;

  /// The volunteer opened the app and asked for their clips to be removed.
  bool get deletionRequested => raw['deletionRequested'] == true;

  /// Takes expected per phrase for this speaker.
  int get expectedTakes => tier == 'B' ? Tier.b.takes : Tier.a.takes;
  int get targetClips => expectedTakes * kPhrases.length;

  String field(String key) {
    final v = raw[key];
    if (v == null) return '—';
    if (v is bool) return v ? 'yes' : 'no';
    final s = '$v'.trim();
    return s.isEmpty ? '—' : s;
  }

  bool matches(String q) =>
      q.isEmpty ||
      id.toLowerCase().contains(q) ||
      name.toLowerCase().contains(q) ||
      formNo.toLowerCase().contains(q) ||
      collectorName.toLowerCase().contains(q) ||
      (collectorEmail ?? '').toLowerCase().contains(q);
}

/// Everything worth knowing about the collection, computed once per rebuild.
class Stats {
  final List<ClipView> clips;
  final List<SpeakerView> speakers;
  Stats(this.clips, this.speakers);

  late final List<ClipView> live = clips.where((c) => c.live).toList();
  late final List<ClipView> rejected = clips.where((c) => !c.live).toList();

  late final Map<String, int> perPhrase = {
    for (final p in kPhrases)
      p.id: live.where((c) => c.phraseId == p.id).length,
  };

  late final Map<String, List<ClipView>> bySpeaker = () {
    final m = <String, List<ClipView>>{};
    for (final c in clips) {
      m.putIfAbsent(c.speakerId, () => []).add(c);
    }
    return m;
  }();

  List<ClipView> liveOf(String speakerId) =>
      (bySpeaker[speakerId] ?? const []).where((c) => c.live).toList();

  /// Speakers that hold no clips at all — their numbers are dead weight.
  late final List<SpeakerView> empty =
      speakers.where((s) => liveOf(s.id).isEmpty).toList();

  int get total => live.length;
  int get uploaded => live.where((c) => c.uploaded).length;
  int get waiting => live.length - uploaded;
  int get overridden => live.where((c) => c.qcOverride).length;
  int get warned => live.where((c) => c.qcVerdict != 'pass').length;
  int get imported => live.where((c) => c.source == 'import').length;

  int get thinnest => perPhrase.values.isEmpty
      ? 0
      : perPhrase.values.reduce((a, b) => a < b ? a : b);
  int get richest => perPhrase.values.isEmpty
      ? 0
      : perPhrase.values.reduce((a, b) => a > b ? a : b);
  int get phrasesCovered => perPhrase.values.where((v) => v > 0).length;

  /// Volunteers who have asked for their clips to be deleted.
  late final List<SpeakerView> deletionRequests =
      speakers.where((s) => s.deletionRequested).toList();

  /// Speakers that still owe clips, by their own tier.
  late final List<SpeakerView> incomplete = speakers
      .where((s) => liveOf(s.id).isNotEmpty && liveOf(s.id).length < s.targetClips)
      .toList();
}

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.instance;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: sync.clips.snapshots(),
      builder: (context, clipSnap) {
        if (clipSnap.hasError) {
          return _Message(
            icon: Icons.lock_outline,
            title: 'Cannot read the corpus',
            body: 'Your account is probably not a Collector yet. Ask the '
                'master admin to set your role in Users & roles.\n\n'
                '${clipSnap.error}',
          );
        }
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: sync.speakers.orderBy('speakerId').snapshots(),
          builder: (context, spSnap) {
            if (!clipSnap.hasData || !spSnap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final stats = Stats(
              clipSnap.data!.docs.map((d) => ClipView(d.data(), d.id)).toList(),
              spSnap.data!.docs.map((d) => SpeakerView(d.id, d.data())).toList(),
            );
            return DefaultTabController(
              length: 4,
              child: Column(
                children: [
                  const TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [
                      Tab(text: 'Overview'),
                      Tab(text: 'Speakers'),
                      Tab(text: 'Breakdown'),
                      Tab(text: 'Team'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _OverviewTab(stats: stats),
                        _SpeakersTab(stats: stats),
                        _BreakdownTab(stats: stats),
                        _TeamTab(stats: stats),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

// ======================================================================
//  Overview
// ======================================================================
class _OverviewTab extends StatelessWidget {
  final Stats stats;
  const _OverviewTab({required this.stats});

  @override
  Widget build(BuildContext context) {
    final me = AuthService.instance.profile;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Row(
          children: [
            _Stat(
                label: 'Speakers',
                value: '${stats.speakers.length}',
                icon: Icons.person_outline),
            const SizedBox(width: 10),
            _Stat(
                label: 'Clips',
                value: '${stats.total}',
                icon: Icons.movie_outlined),
            const SizedBox(width: 10),
            _Stat(
                label: 'Phrases',
                value: '${stats.phrasesCovered}/${kPhrases.length}',
                icon: Icons.format_list_numbered),
          ],
        ),
        if (stats.deletionRequests.isNotEmpty) ...[
          const SizedBox(height: 12),
          _Banner(
            icon: Icons.person_remove_outlined,
            color: Brand.urgent,
            text: '${stats.deletionRequests.length} '
                '${stats.deletionRequests.length == 1 ? "volunteer has" : "volunteers have"} '
                'asked for their clips to be deleted: '
                '${stats.deletionRequests.map((s) => s.id).join(", ")}. '
                'Open each one and throw away every clip — this is a legal '
                'obligation, not a request you can leave.',
          ),
        ],
        if (stats.incomplete.isNotEmpty) ...[
          const SizedBox(height: 12),
          _Banner(
            icon: Icons.pending_actions,
            color: Brand.amber,
            text: '${stats.incomplete.length} speakers are unfinished: '
                '${stats.incomplete.take(4).map((s) => s.id).join(", ")}'
                '${stats.incomplete.length > 4 ? "…" : ""}. '
                'Open one in Speakers and record the phrases it is missing.',
          ),
        ],
        if (stats.empty.isNotEmpty) _ReclaimCard(stats: stats),
        _DeleteByNumberCard(stats: stats),
        const _StrandedFilesCard(),
        if (me?.isMaster ?? false) const _PublishUpdateCard(),
        const SizedBox(height: 12),
        _ManifestButton(stats: stats),
        if (me?.isAdmin ?? false) ...[
          const SizedBox(height: 8),
          _RosterButton(stats: stats),
        ],
        const SizedBox(height: 16),
        const _SectionTitle('Upload & quality'),
        _HealthCard(stats: stats),
        const SizedBox(height: 18),
        const _SectionTitle('Clips per phrase'),
        Text(
          stats.total == 0
              ? 'Nothing recorded yet.'
              : 'Thinnest phrase has ${stats.thinnest}, richest has '
                  '${stats.richest}. Even coverage matters more than volume — '
                  'a phrase with far fewer clips is the one the model will '
                  'get wrong. Tap a row to see its clips.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        for (final p in kPhrases)
          InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PhraseClipsScreen(phrase: p, clips: stats.clips),
            )),
            child: _PhraseBar(
              phrase: p,
              count: stats.perPhrase[p.id] ?? 0,
              max: stats.richest,
              thinnest: stats.thinnest,
            ),
          ),
      ],
    );
  }
}

/// Offers to hand back every speaker number that holds no clips, so no ID is
/// left stranded by a test run or an abandoned session.
/// Wipes one whole recording and hands its number back. Permanent: the videos
/// are deleted from Drive, not moved aside.
Future<bool> deleteWholeSpeaker({
  required BuildContext context,
  required SpeakerView speaker,
  required List<ClipView> clips,
}) async {
  final reasonCtrl = TextEditingController(
      text: speaker.deletionRequested ? 'volunteer asked to be deleted' : '');
  final typed = TextEditingController();

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text('Delete ${speaker.id} completely?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${speaker.name.isEmpty ? "This speaker" : speaker.name} · '
                'form ${speaker.formNo} · ${clips.length} clips',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              const Text(
                'Their records are removed and the number goes back into the '
                'pool for the next volunteer. This cannot be undone.',
                style: TextStyle(height: 1.35),
              ),
              const SizedBox(height: 8),
              Text(
                'Drive only lets the account that uploaded a clip destroy it. '
                'Anything recorded on another phone is taken out of the '
                'corpus and renamed instead, and you will be told who has to '
                'finish deleting it.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 14),
              TextField(
                controller: reasonCtrl,
                decoration: const InputDecoration(
                  labelText: 'Reason',
                  hintText: 'e.g. volunteer asked, test session',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: typed,
                onChanged: (_) => setLocal(() {}),
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: 'Type ${speaker.id} to confirm',
                  prefixIcon: const Icon(Icons.warning_amber_rounded),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep it')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Brand.urgent),
            onPressed: typed.text.trim().toUpperCase() == speaker.id
                ? () => Navigator.pop(ctx, true)
                : null,
            child: const Text('Delete for good'),
          ),
        ],
      ),
    ),
  );
  if (go != true || !context.mounted) return false;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        children: [
          SizedBox(
              width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 16),
          Expanded(child: Text('Deleting from Drive…')),
        ],
      ),
    ),
  );

  final report = await SyncService.instance.deleteSpeakerCompletely(
    speakerId: speaker.id,
    formNo: speaker.formNo,
    clips: clips
        .map((c) => ClipRef(
              docId: c.docId,
              driveFileId: c.driveFileId,
              ownerEmail: c.collectorEmail,
            ))
        .toList(),
    reason: reasonCtrl.text.trim().isEmpty
        ? 'no reason given'
        : reasonCtrl.text.trim(),
  );

  if (!context.mounted) return report.ok;
  Navigator.of(context).pop(); // the spinner
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(report.ok ? '${speaker.id} deleted' : 'Not deleted'),
      content: Text(report.message),
      actions: [
        FilledButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
      ],
    ),
  );
  return report.ok;
}

/// Admin tool: find a recording by either number and wipe it.
class _DeleteByNumberCard extends StatefulWidget {
  final Stats stats;
  const _DeleteByNumberCard({required this.stats});

  @override
  State<_DeleteByNumberCard> createState() => _DeleteByNumberCardState();
}

class _DeleteByNumberCardState extends State<_DeleteByNumberCard> {
  final _ctrl = TextEditingController();
  bool _open = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Accepts S014, F014, s14, 14 — both numbers point at the same session.
  SpeakerView? _find(String input) {
    final digits = RegExp(r'\d+').firstMatch(input.trim());
    if (digits == null) return null;
    final n = int.parse(digits.group(0)!);
    final id = 'S${n.toString().padLeft(3, '0')}';
    for (final s in widget.stats.speakers) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> _go() async {
    final found = _find(_ctrl.text);
    if (found == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('No recording found for "${_ctrl.text.trim()}".')));
      return;
    }
    final me = AuthService.instance.profile;
    final mine = found.collectorEmail == Team.email;
    if (!(me?.isAdmin ?? false) && !mine) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${found.id} was recorded by ${found.collectorName}. '
            'Only they or an admin can delete it.'),
      ));
      return;
    }
    final ok = await deleteWholeSpeaker(
      context: context,
      speaker: found,
      clips: widget.stats.bySpeaker[found.id] ?? const [],
    );
    if (ok && mounted) setState(() => _ctrl.clear());
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Column(
          children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.delete_forever, color: Brand.urgent),
              title: const Text('Delete a recording by number',
                  style: TextStyle(fontWeight: FontWeight.w700)),
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
                      'Speaker ID or form number — S014 and F014 are the same '
                      'session. Their videos are removed from the corpus and '
                      'the number is reused. Admins can delete any recording; '
                      'a collector can delete the ones they recorded.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _ctrl,
                            textCapitalization: TextCapitalization.characters,
                            onSubmitted: (_) => _go(),
                            decoration: const InputDecoration(
                              hintText: 'S014 or F014',
                              prefixIcon: Icon(Icons.search),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        FilledButton(
                          style: FilledButton.styleFrom(
                              backgroundColor: Brand.urgent),
                          onPressed: _go,
                          child: const Text('Find'),
                        ),
                      ],
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

class _ReclaimCard extends StatefulWidget {
  final Stats stats;
  const _ReclaimCard({required this.stats});

  @override
  State<_ReclaimCard> createState() => _ReclaimCardState();
}

class _ReclaimCardState extends State<_ReclaimCard> {
  bool _busy = false;

  Future<void> _reclaim() async {
    final empty = widget.stats.empty;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Free up ${empty.length} unused numbers?'),
        content: Text(
          '${empty.map((s) => s.id).join(", ")}\n\n'
          'These hold no clips. Their rows are deleted and the numbers go '
          'back into the pool, so the next volunteers get them instead of new '
          'ones. Nothing recorded is touched.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Leave them')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Free them up')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await IdAllocator.release(empty.map((s) => s.id));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${empty.length} numbers back in the pool')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not free them: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final empty = widget.stats.empty;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        color: Theme.of(context).colorScheme.tertiaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(Icons.restore_from_trash),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${empty.length} speaker numbers hold no clips '
                  '(${empty.take(5).map((s) => s.id).join(", ")}'
                  '${empty.length > 5 ? "…" : ""})',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : TextButton(
                      onPressed: _reclaim, child: const Text('Free up')),
            ],
          ),
        ),
      ),
    );
  }
}

/// Master admin only: point everyone at a new APK. Every phone on an older
/// build is locked out until it installs this one, so the team never compares
/// results collected by two different versions of the recorder.
class _PublishUpdateCard extends StatefulWidget {
  const _PublishUpdateCard();

  @override
  State<_PublishUpdateCard> createState() => _PublishUpdateCardState();
}

class _PublishUpdateCardState extends State<_PublishUpdateCard> {
  final _build = TextEditingController();
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _notes = TextEditingController();
  bool _open = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final r = ReleaseService.instance;
    _build.text = '${r.localBuild}';
    _name.text = r.localVersion;
  }

  @override
  void dispose() {
    _build.dispose();
    _name.dispose();
    _url.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    final r = ReleaseService.instance;
    final build = int.tryParse(_build.text.trim()) ?? 0;
    final url = _url.text.trim();
    if (build <= 0 || !url.startsWith('http')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Need a build number and a link starting with http.')));
      return;
    }

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Require build $build?'),
        content: Text(
          build > r.localBuild
              ? 'Every phone below build $build is locked until it installs '
                  'this — including this one, which is on build '
                  '${r.localBuild}. Make sure the link works first.'
              : 'Every phone below build $build is locked until it installs '
                  'this. This phone is on build ${r.localBuild}, so it keeps '
                  'working.',
        ),
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
    if (go != true) return;

    setState(() => _busy = true);
    try {
      await r.publish(
        build: build,
        versionName: _name.text,
        url: url,
        notes: _notes.text,
      );
      if (mounted) {
        setState(() => _open = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Build $build published. Everyone below it must '
                'update now.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not publish: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = ReleaseService.instance;
    return AnimatedBuilder(
      animation: r,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Card(
          child: Column(
            children: [
              ListTile(
                dense: true,
                leading: const Icon(Icons.system_update, color: Brand.indigo),
                title: const Text('Publish an app update',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(r.requiredBuild > 0
                    ? 'Everyone must be on build ${r.requiredBuild}'
                    : 'No update is being forced'),
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
                        'Build the APK, upload it to GitHub releases or '
                        'Drive, then paste the link here. This phone is on '
                        'build ${r.localBuild} (${r.localVersion}).',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          SizedBox(
                            width: 110,
                            child: TextField(
                              controller: _build,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Build no.',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextField(
                              controller: _name,
                              decoration: const InputDecoration(
                                labelText: 'Version name',
                                hintText: '1.0.0',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _url,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'APK link',
                          hintText: 'https://…',
                          prefixIcon: Icon(Icons.link),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _notes,
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: "What's new",
                          hintText: 'Shown to everyone on the update screen',
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          if (r.requiredBuild > 0)
                            TextButton(
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      await r.clear();
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(const SnackBar(
                                                content: Text(
                                                    'Forced update cleared')));
                                      }
                                    },
                              child: const Text('Stop forcing'),
                            ),
                          const Spacer(),
                          FilledButton.icon(
                            onPressed: _busy ? null : _publish,
                            icon: _busy
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.publish),
                            label: const Text('Publish'),
                          ),
                        ],
                      ),
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

/// Files an earlier deletion could not destroy because they belong to this
/// account. Drive insists the uploader does it, so this is where they do.
class _StrandedFilesCard extends StatefulWidget {
  const _StrandedFilesCard();

  @override
  State<_StrandedFilesCard> createState() => _StrandedFilesCardState();
}

class _StrandedFilesCardState extends State<_StrandedFilesCard> {
  bool _busy = false;

  Future<void> _clear(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) async {
    setState(() => _busy = true);
    try {
      var gone = 0;
      for (final d in docs) {
        final ids = ((d.data()['pendingFileIds'] as List?) ?? const [])
            .map((e) => '$e')
            .toList();
        gone += await SyncService.instance.deleteStrandedFiles(ids);
        await d.reference.set({
          'pendingFileIds': <String>[],
          'pendingOwners': <String>[],
          'clearedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$gone files deleted from your Drive')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not finish: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = Team.email;
    if (me == null) return const SizedBox.shrink();
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('deletions')
          .where('pendingOwners', arrayContains: me)
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? const [];
        if (docs.isEmpty) return const SizedBox.shrink();
        final files = docs.fold<int>(
            0,
            (n, d) =>
                n + ((d.data()['pendingFileIds'] as List?)?.length ?? 0));
        if (files == 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Icon(Icons.delete_forever),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '$files files you uploaded still have to be deleted — '
                      'someone deleted those recordings but only you can '
                      'destroy your own uploads.',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : TextButton(
                          onPressed: () => _clear(docs),
                          child: const Text('Delete mine'),
                        ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Writes one CSV listing every clip into the top of the Drive corpus folder.
/// No names in it, so it is safe to ship with the dataset.
class _ManifestButton extends StatefulWidget {
  final Stats stats;
  const _ManifestButton({required this.stats});

  @override
  State<_ManifestButton> createState() => _ManifestButtonState();
}

class _ManifestButtonState extends State<_ManifestButton> {
  bool _busy = false;

  String _buildCsv() {
    const header = [
      'drivePath', 'fileName', 'speakerId', 'phraseId', 'label', 'take',
      'status', 'qcVerdict', 'qcOverride', 'source', 'uploaded', 'fileBytes',
      'day', 'collector', 'driveFileId', 'driveLink', 'rejectedReason',
    ];
    final rows = widget.stats.clips.toList()
      ..sort((a, b) {
        final p = a.phraseId.compareTo(b.phraseId);
        if (p != 0) return p;
        final sp = a.speakerId.compareTo(b.speakerId);
        return sp != 0 ? sp : a.take.compareTo(b.take);
      });
    final out = StringBuffer(header.join(','))..write('\n');
    for (final c in rows) {
      out.write([
        c.drivePath,
        c.fileName,
        c.speakerId,
        c.phraseId,
        kPhrases.indexWhere((p) => p.id == c.phraseId),
        c.take,
        c.status,
        c.qcVerdict,
        c.qcOverride,
        c.source,
        c.uploaded,
        c.bytes,
        c.day,
        c.collectorName,
        c.driveFileId ?? '',
        c.driveFileId == null ? '' : DriveUploader.webLink(c.driveFileId!),
        c.rejectedReason ?? '',
      ].map(csvCell).join(','));
      out.write('\n');
    }
    return out.toString();
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      onPressed: _busy || widget.stats.clips.isEmpty
          ? null
          : () => exportCsv(
                context: context,
                fileName: 'manifest_${stamp()}.csv',
                text: _buildCsv(),
                note: 'One row per clip, with the exact Drive path and a '
                    'direct link. No names in this file, so it can go out '
                    'with the dataset.',
                setBusy: (v) => setState(() => _busy = v),
              ),
      icon: _busy
          ? const SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.table_view_outlined),
      label: Text(_busy
          ? 'Writing…'
          : 'Export manifest CSV (${widget.stats.clips.length} clips, no names)'),
    );
  }
}

/// The private roster: which number is which person. Admins only, and never
/// published.
class _RosterButton extends StatefulWidget {
  final Stats stats;
  const _RosterButton({required this.stats});

  @override
  State<_RosterButton> createState() => _RosterButtonState();
}

class _RosterButtonState extends State<_RosterButton> {
  bool _busy = false;

  String _buildCsv() {
    const header = [
      'speakerId', 'formNo', 'name', 'tier', 'clips', 'target', 'status',
      'ageBand', 'gender', 'firstLanguage', 'fluentHindi', 'facialHair',
      'glasses', 'lighting', 'phoneMount', 'cameraLens', 'locationNote',
      'consentGiven', 'publishable', 'collector', 'deviceModel',
    ];
    final out = StringBuffer(header.join(','))..write('\n');
    final rows = widget.stats.speakers.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    for (final s in rows) {
      out.write([
        s.id,
        s.formNo,
        s.name,
        s.tier,
        widget.stats.liveOf(s.id).length,
        s.targetClips,
        s.status,
        s.field('ageBand'),
        s.field('gender'),
        s.field('firstLanguage'),
        s.field('fluentHindi'),
        s.field('facialHair'),
        s.field('glasses'),
        s.field('lighting'),
        s.field('phoneMount'),
        s.field('cameraLens'),
        s.field('locationNote'),
        s.field('consentGiven'),
        s.publishable,
        s.collectorName,
        s.field('deviceModel'),
      ].map(csvCell).join(','));
      out.write('\n');
    }
    return out.toString();
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        foregroundColor: Brand.urgent,
      ),
      onPressed: _busy || widget.stats.speakers.isEmpty
          ? null
          : () => exportCsv(
                context: context,
                fileName: 'roster_PRIVATE_${stamp()}.csv',
                text: _buildCsv(),
                note: 'This file contains names. Keep it out of anything you '
                    'publish or share outside the team — it is the only thing '
                    'that links a speaker number to a person.',
                setBusy: (v) => setState(() => _busy = v),
              ),
      icon: _busy
          ? const SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.lock_outline),
      label: Text(_busy
          ? 'Writing…'
          : 'Export roster CSV (${widget.stats.speakers.length} speakers, has names)'),
    );
  }
}

String csvCell(Object? v) {
  final text = '${v ?? ''}';
  if (!text.contains(',') && !text.contains('"') && !text.contains('\n')) {
    return text;
  }
  return '"${text.replaceAll('"', '""')}"';
}

String stamp() {
  String two(int n) => n.toString().padLeft(2, '0');
  final n = DateTime.now();
  return '${n.year}-${two(n.month)}-${two(n.day)}_${two(n.hour)}${two(n.minute)}';
}

/// Shared by both export buttons: upload to Drive, then offer to open it.
Future<void> exportCsv({
  required BuildContext context,
  required String fileName,
  required String text,
  required String note,
  required void Function(bool) setBusy,
}) async {
  setBusy(true);
  final sync = SyncService.instance;
  try {
    if (!sync.drive.signedIn && !await sync.connectDrive()) {
      throw Exception(sync.drive.lastError ?? 'Drive is not connected.');
    }
    final id = await sync.drive.uploadText(fileName: fileName, text: text);
    if (id == null) throw Exception(sync.drive.lastError ?? 'upload failed');
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Written to Drive'),
        content: Text('$fileName is now in the corpus folder, next to '
            'P01–P20.\n\n$note'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              launchUrl(Uri.parse(DriveUploader.webLink(id)),
                  mode: LaunchMode.externalApplication);
            },
            child: const Text('Open'),
          ),
        ],
      ),
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  } finally {
    setBusy(false);
  }
}

class _HealthCard extends StatefulWidget {
  final Stats stats;
  const _HealthCard({required this.stats});

  @override
  State<_HealthCard> createState() => _HealthCardState();
}

class _HealthCardState extends State<_HealthCard> {
  bool _purging = false;

  Future<void> _purge() async {
    setState(() => _purging = true);
    try {
      final dir = await Storage.dataDir();
      final freed = await SyncService.instance.purgeUploadedLocalFiles(dir);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Freed ${Storage.human(freed)} on this phone')));
      }
    } finally {
      if (mounted) setState(() => _purging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = SyncService.instance;
    final s = widget.stats;
    return AnimatedBuilder(
      animation: sync,
      builder: (context, _) {
        final drive = sync.drive;
        final driveOk = drive.signedIn && drive.corpusWritable == true;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Line(
                  icon: driveOk ? Icons.cloud_done : Icons.cloud_off,
                  color: driveOk ? const Color(0xFF2E7D32) : Brand.urgent,
                  title: driveOk
                      ? 'Drive connected — ${drive.accountEmail}'
                      : (drive.lastError ?? 'Drive not connected'),
                  trailing: driveOk
                      ? null
                      : TextButton(
                          onPressed: () => sync.connectDrive(),
                          child: const Text('Connect'),
                        ),
                ),
                const Divider(height: 20),
                _Line(
                  icon: s.waiting == 0 ? Icons.check_circle : Icons.cloud_upload,
                  color: s.waiting == 0 ? const Color(0xFF2E7D32) : Brand.amber,
                  title: s.waiting == 0
                      ? 'Everything is in Drive'
                      : '${s.waiting} clips still to upload '
                          '(${sync.pendingCount} queued on this phone)',
                  subtitle: sync.status,
                ),
                const Divider(height: 20),
                _Line(
                  icon: Icons.rule,
                  color: Brand.teal,
                  title: '${s.warned} clips flagged by the face check, '
                      '${s.overridden} recorded anyway',
                  subtitle: 'Flagged clips are kept — the check is a hint, '
                      'not a verdict.',
                ),
                const Divider(height: 20),
                _Line(
                  icon: Icons.delete_outline,
                  color: Colors.grey,
                  title: '${s.rejected.length} clips rejected',
                  subtitle: s.rejected.isEmpty
                      ? 'Nothing thrown away yet.'
                      : 'Moved to the _rejected folder in Drive; the pipeline '
                          'skips them.',
                ),
                if (s.imported > 0) ...[
                  const Divider(height: 20),
                  _Line(
                    icon: Icons.download_done,
                    color: Brand.indigo,
                    title: '${s.imported} clips imported from Drive',
                    subtitle: 'Recorded before the app, adopted into the set.',
                  ),
                ],
                const Divider(height: 20),
                FutureBuilder<int>(
                  future: Storage.localBytes(),
                  builder: (context, b) => _Line(
                    icon: Icons.sd_storage_outlined,
                    color: Colors.grey,
                    title: '${Storage.human(b.data ?? 0)} on this phone',
                    trailing: TextButton(
                      onPressed: _purging ? null : _purge,
                      child: Text(_purging ? 'Working…' : 'Free up'),
                    ),
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

class _PhraseBar extends StatelessWidget {
  final Phrase phrase;
  final int count;
  final int max;
  final int thinnest;

  const _PhraseBar({
    required this.phrase,
    required this.count,
    required this.max,
    required this.thinnest,
  });

  @override
  Widget build(BuildContext context) {
    final behind = count == thinnest && max > thinnest;
    final color = count == 0
        ? Brand.urgent
        : behind
            ? Brand.amber
            : Brand.teal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Text(phrase.id,
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(phrase.devanagari,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: max == 0 ? 0 : count / max,
                    minHeight: 7,
                    backgroundColor: color.withValues(alpha: 0.15),
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 34,
            child: Text('$count',
                textAlign: TextAlign.right,
                style: TextStyle(fontWeight: FontWeight.w700, color: color)),
          ),
        ],
      ),
    );
  }
}

// ======================================================================
//  Speakers
// ======================================================================
class _SpeakersTab extends StatefulWidget {
  final Stats stats;
  const _SpeakersTab({required this.stats});

  @override
  State<_SpeakersTab> createState() => _SpeakersTabState();
}

class _SpeakersTabState extends State<_SpeakersTab> {
  String _q = '';
  bool _onlyIncomplete = false;

  @override
  Widget build(BuildContext context) {
    final stats = widget.stats;
    if (stats.speakers.isEmpty) {
      return const _Message(
        icon: Icons.person_add_alt,
        title: 'No speakers yet',
        body: 'Open "New recording session" to record your first one, or '
            '"Import from Drive" to adopt clips you recorded earlier.',
      );
    }
    final q = _q.toLowerCase();
    final shown = stats.speakers.where((s) {
      if (!s.matches(q)) return false;
      if (!_onlyIncomplete) return true;
      final n = stats.liveOf(s.id).length;
      return n < s.targetClips;
    }).toList();

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      itemCount: shown.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Column(
            children: [
              TextField(
                onChanged: (v) => setState(() => _q = v.trim()),
                decoration: const InputDecoration(
                  hintText: 'Find by name, S014, F014 or collector',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  FilterChip(
                    label: Text('Unfinished only (${stats.incomplete.length})'),
                    selected: _onlyIncomplete,
                    onSelected: (v) => setState(() => _onlyIncomplete = v),
                  ),
                  const Spacer(),
                  Text('${shown.length} shown',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
              const SizedBox(height: 10),
            ],
          );
        }
        final s = shown[index - 1];
        final live = stats.liveOf(s.id);
        final rejected =
            (stats.bySpeaker[s.id] ?? const []).where((c) => !c.live).length;
        final phrases = live.map((c) => c.phraseId).toSet().length;
        final done = live.length >= s.targetClips;

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: live.isEmpty
                    ? Colors.grey
                    : done
                        ? const Color(0xFF2E7D32)
                        : Brand.amber,
                child: Text('${live.length}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12)),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      s.name.isEmpty ? s.id : '${s.name} · ${s.id}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (!done && live.isNotEmpty)
                    _Tag(
                        text: '${s.targetClips - live.length} left',
                        color: Brand.amber),
                  if (s.deletionRequested)
                    const _Tag(text: 'delete me', color: Brand.urgent),
                  if (live.isEmpty) const _Tag(text: 'empty', color: Colors.grey),
                  if (rejected > 0)
                    _Tag(text: '$rejected rejected', color: Colors.grey),
                ],
              ),
              subtitle: Text(
                'form ${s.formNo} · tier ${s.tier} · '
                '$phrases/${kPhrases.length} phrases\n'
                'by ${s.collectorName}',
              ),
              isThreeLine: true,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SpeakerDetailScreen(
                    speaker: s, clips: stats.bySpeaker[s.id] ?? const []),
              )),
            ),
          ),
        );
      },
    );
  }
}

/// One speaker, phrase by phrase: what is there, what is missing, what was
/// thrown away — and the buttons to fix each case.
class SpeakerDetailScreen extends StatelessWidget {
  final SpeakerView speaker;
  final List<ClipView> clips;

  const SpeakerDetailScreen({
    super.key,
    required this.speaker,
    required this.clips,
  });

  List<ClipView> _of(String phraseId) =>
      clips.where((c) => c.phraseId == phraseId).toList()
        ..sort((a, b) => a.take.compareTo(b.take));

  /// A new take number that cannot collide with anything already recorded for
  /// this phrase, rejected clips included.
  int _nextTake(String phraseId) {
    final all = _of(phraseId);
    return all.isEmpty
        ? 1
        : all.map((c) => c.take).reduce((a, b) => a > b ? a : b) + 1;
  }

  List<RecordSlot> _missingSlots() {
    final out = <RecordSlot>[];
    for (var i = 0; i < kPhrases.length; i++) {
      final id = kPhrases[i].id;
      final have = _of(id).where((c) => c.live).length;
      var take = _nextTake(id);
      for (var k = have; k < speaker.expectedTakes; k++) {
        out.add(RecordSlot(i, take++));
      }
    }
    return out;
  }

  Future<void> _record(
      BuildContext context, List<RecordSlot> slots, String title) async {
    final meta = SpeakerMeta.fromMap(speaker.raw);
    await meta.fillAutoFields();
    meta.speakerId = speaker.id;
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RecordScreen(
        meta: meta,
        takes: speaker.expectedTakes,
        only: slots,
        title: title,
      ),
    ));
    await SyncService.instance.setSpeakerStatus(speaker.id, 'complete');
  }

  @override
  Widget build(BuildContext context) {
    final me = AuthService.instance.profile;
    final canEdit =
        (me?.isAdmin ?? false) || speaker.collectorEmail == Team.email;
    final live = clips.where((c) => c.live).length;
    final missing = _missingSlots();

    return Scaffold(
      appBar: AppBar(
        title: Text(speaker.name.isEmpty ? speaker.id : speaker.name),
        actions: [
          if (canEdit)
            IconButton(
              tooltip: 'Edit details',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => SpeakerEditScreen(
                    speakerId: speaker.id, existing: speaker.raw),
              )),
            ),
          if (canEdit)
            IconButton(
              tooltip: 'Delete this recording completely',
              icon: const Icon(Icons.delete_forever, color: Brand.urgent),
              onPressed: () async {
                final gone = await deleteWholeSpeaker(
                    context: context, speaker: speaker, clips: clips);
                if (gone && context.mounted) Navigator.of(context).pop();
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${speaker.id} · form ${speaker.formNo}',
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    '$live of ${speaker.targetClips} clips · tier '
                    '${speaker.tier} (${speaker.expectedTakes} '
                    '${speaker.expectedTakes == 1 ? "take" : "takes"} per phrase)',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    [
                      speaker.field('ageBand'),
                      speaker.field('gender'),
                      speaker.field('firstLanguage'),
                      speaker.field('lighting'),
                      speaker.field('cameraLens'),
                    ].where((e) => e != '—').join(' · '),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (speaker.deletionRequested)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'This volunteer has asked for their clips to be '
                        'deleted. Throw away every clip below, then tell them '
                        'it is done.',
                        style: TextStyle(
                            color: Brand.urgent, fontWeight: FontWeight.w600),
                      ),
                    ),
                  Text(
                    'by ${speaker.collectorName}'
                    '${speaker.publishable ? " · publishable" : " · not for publication"}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (missing.isNotEmpty && canEdit)
            FilledButton.icon(
              onPressed: () => _record(context, missing,
                  'Added to ${speaker.id}'),
              icon: const Icon(Icons.videocam),
              label: Text('Record the ${missing.length} missing clips'),
            ),
          if (missing.isEmpty)
            const _Banner(
              icon: Icons.check_circle,
              color: Color(0xFF2E7D32),
              text: 'This speaker is complete.',
            ),
          const SizedBox(height: 16),
          for (var i = 0; i < kPhrases.length; i++)
            _PhraseBlock(
              phrase: kPhrases[i],
              clips: _of(kPhrases[i].id),
              expected: speaker.expectedTakes,
              canEdit: canEdit,
              onRecord: () => _record(
                context,
                [RecordSlot(i, _nextTake(kPhrases[i].id))],
                '${kPhrases[i].id} for ${speaker.id}',
              ),
            ),
        ],
      ),
    );
  }
}

class _PhraseBlock extends StatelessWidget {
  final Phrase phrase;
  final List<ClipView> clips;
  final int expected;
  final bool canEdit;
  final VoidCallback onRecord;

  const _PhraseBlock({
    required this.phrase,
    required this.clips,
    required this.expected,
    required this.canEdit,
    required this.onRecord,
  });

  @override
  Widget build(BuildContext context) {
    final live = clips.where((c) => c.live).toList();
    final short = live.length < expected;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('${phrase.id}  ',
                  style: const TextStyle(fontWeight: FontWeight.w800)),
              Expanded(
                child: Text(phrase.devanagari,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15)),
              ),
              if (short)
                _Tag(
                    text: live.isEmpty
                        ? 'missing'
                        : '${live.length}/$expected',
                    color: Brand.urgent),
              if (short && canEdit)
                TextButton(
                  onPressed: onRecord,
                  child: const Text('Record'),
                ),
            ],
          ),
          for (final c in clips)
            _ClipRow(clip: c, canReject: canEdit && c.live),
          if (clips.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Text('no clip yet',
                  style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

/// Every clip of one phrase, across all speakers.
class PhraseClipsScreen extends StatelessWidget {
  final Phrase phrase;
  final List<ClipView> clips;
  const PhraseClipsScreen(
      {super.key, required this.phrase, required this.clips});

  @override
  Widget build(BuildContext context) {
    final me = AuthService.instance.profile;
    final mine = clips.where((c) => c.phraseId == phrase.id).toList()
      ..sort((a, b) {
        final sp = a.speakerId.compareTo(b.speakerId);
        return sp != 0 ? sp : a.take.compareTo(b.take);
      });
    return Scaffold(
      appBar: AppBar(title: Text('${phrase.id} · ${mine.length} clips')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(phrase.devanagari,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('${phrase.roman} · ${phrase.english}',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Text('Drive folder: ${phrase.id}/',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (mine.isEmpty)
            const Text('Nothing recorded for this phrase yet.')
          else
            for (final c in mine)
              _ClipRow(clip: c, canReject: (me?.isAdmin ?? false) && c.live),
        ],
      ),
    );
  }
}

class _ClipRow extends StatefulWidget {
  final ClipView clip;
  final bool canReject;
  const _ClipRow({required this.clip, required this.canReject});

  @override
  State<_ClipRow> createState() => _ClipRowState();
}

class _ClipRowState extends State<_ClipRow> {
  bool _busy = false;

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Copied $text')));
    }
  }

  Future<void> _openInDrive() async {
    final id = widget.clip.driveFileId;
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Not in Drive yet — still waiting to upload.')));
      return;
    }
    final ok = await launchUrl(Uri.parse(DriveUploader.webLink(id)),
        mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not open Drive.')));
    }
  }

  Future<void> _reject() async {
    final c = widget.clip;
    final reasonCtrl = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Throw away ${c.phraseId} take ${c.take}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'The file moves to the _rejected folder in Drive, so the '
              'training pipeline skips it. Nothing is destroyed, and the '
              'phrase can be recorded again for this speaker.',
              style: TextStyle(height: 1.35),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Why?',
                hintText: 'e.g. face out of frame, spoke aloud',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep it')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Brand.urgent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Throw away'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _busy = true);
    final err = await SyncService.instance.rejectClip(
      c.docId,
      reason: reasonCtrl.text.trim().isEmpty
          ? 'no reason given'
          : reasonCtrl.text.trim(),
      driveFileId: c.driveFileId,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(err ?? '${c.phraseId} take ${c.take} thrown away'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.clip;
    final colour = !c.live
        ? Colors.grey
        : c.qcVerdict == 'pass'
            ? const Color(0xFF2E7D32)
            : Brand.amber;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Card(
        child: ListTile(
          dense: true,
          onTap: c.driveFileId == null ? null : _openInDrive,
          leading: Icon(c.live ? Icons.movie : Icons.delete_outline,
              color: colour),
          title: Row(
            children: [
              Text('take ${c.take}',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    decoration: c.live ? null : TextDecoration.lineThrough,
                  )),
              const SizedBox(width: 8),
              if (!c.uploaded && c.live)
                const _Tag(text: 'not uploaded', color: Brand.amber),
              if (c.qcOverride) const _Tag(text: 'override', color: Brand.teal),
              if (c.source == 'import')
                const _Tag(text: 'imported', color: Brand.indigo),
            ],
          ),
          subtitle: Text(
            c.live
                ? '${c.drivePath}\n${Storage.human(c.bytes)} · qc ${c.qcVerdict}'
                : '${c.drivePath}\nrejected — ${c.rejectedReason ?? "no reason given"}',
            style: const TextStyle(fontSize: 11.5, height: 1.35),
          ),
          isThreeLine: true,
          trailing: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : PopupMenuButton<String>(
                  tooltip: 'Clip actions',
                  onSelected: (v) {
                    switch (v) {
                      case 'open':
                        _openInDrive();
                      case 'copy':
                        _copy(c.fileName);
                      case 'path':
                        _copy(c.drivePath);
                      case 'reject':
                        _reject();
                    }
                  },
                  itemBuilder: (_) => [
                    if (c.driveFileId != null)
                      const PopupMenuItem(
                        value: 'open',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.open_in_new),
                          title: Text('Open in Drive'),
                        ),
                      ),
                    const PopupMenuItem(
                      value: 'copy',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.content_copy),
                        title: Text('Copy file name'),
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'path',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.folder_outlined),
                        title: Text('Copy folder/file path'),
                      ),
                    ),
                    if (widget.canReject)
                      const PopupMenuItem(
                        value: 'reject',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading:
                              Icon(Icons.delete_outline, color: Brand.urgent),
                          title: Text('Throw away',
                              style: TextStyle(color: Brand.urgent)),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

// ======================================================================
//  Breakdown — the dataset table for the paper
// ======================================================================
class _BreakdownTab extends StatelessWidget {
  final Stats stats;
  const _BreakdownTab({required this.stats});

  /// speakers and clips grouped by one field of the speaker row.
  Map<String, (int, int)> _group(String key) {
    final out = <String, (int, int)>{};
    for (final s in stats.speakers) {
      final bucket = s.field(key);
      final clips = stats.liveOf(s.id).length;
      final prev = out[bucket] ?? (0, 0);
      out[bucket] = (prev.$1 + 1, prev.$2 + clips);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    if (stats.speakers.isEmpty) {
      return const _Message(
        icon: Icons.pie_chart_outline,
        title: 'Nothing to break down yet',
        body: 'Record or import a speaker first.',
      );
    }

    final perDay = <String, int>{};
    for (final c in stats.live) {
      if (c.day.isEmpty) continue;
      perDay[c.day] = (perDay[c.day] ?? 0) + 1;
    }
    final days = perDay.keys.toList()..sort();

    final qc = <String, int>{
      'pass': stats.live.where((c) => c.qcVerdict == 'pass').length,
      'warn': stats.live.where((c) => c.qcVerdict == 'warn').length,
      'fail': stats.live.where((c) => c.qcVerdict == 'fail').length,
      'recorded anyway (override)': stats.overridden,
      'rejected': stats.rejected.length,
      'imported': stats.imported,
    };

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text(
          'Speakers and clips by category. This is the dataset table '
          'reviewers ask for — the roster CSV has the same columns per '
          'speaker.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        _GroupCard(title: 'Age band', rows: _group('ageBand')),
        _GroupCard(title: 'Gender', rows: _group('gender')),
        _GroupCard(title: 'Tier', rows: _group('tier')),
        _GroupCard(title: 'First language', rows: _group('firstLanguage')),
        _GroupCard(title: 'Fluent in Hindi', rows: _group('fluentHindi')),
        _GroupCard(title: 'Lighting', rows: _group('lighting')),
        _GroupCard(title: 'Camera', rows: _group('cameraLens')),
        _GroupCard(title: 'Phone held', rows: _group('phoneMount')),
        _GroupCard(title: 'Facial hair', rows: _group('facialHair')),
        _GroupCard(title: 'Glasses', rows: _group('glasses')),
        _GroupCard(
            title: 'Agreed to publication', rows: _group('consentToPublishDataset')),
        const SizedBox(height: 4),
        _CountCard(title: 'Quality', rows: qc, unit: 'clips'),
        _CountCard(
          title: 'Clips per day',
          rows: {for (final d in days) d: perDay[d]!},
          unit: 'clips',
        ),
      ],
    );
  }
}

class _GroupCard extends StatelessWidget {
  final String title;
  final Map<String, (int, int)> rows;
  const _GroupCard({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final entries = rows.entries.toList()
      ..sort((a, b) => b.value.$1.compareTo(a.value.$1));
    final top = entries.first.value.$1;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              for (final e in entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 108,
                        child: Text(e.key,
                            maxLines: 2,
                            style: const TextStyle(fontSize: 12.5)),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: top == 0 ? 0 : e.value.$1 / top,
                            minHeight: 8,
                            backgroundColor:
                                Brand.teal.withValues(alpha: 0.15),
                            valueColor:
                                const AlwaysStoppedAnimation(Brand.teal),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('${e.value.$1} sp · ${e.value.$2} cl',
                          style: const TextStyle(
                              fontSize: 11.5, fontWeight: FontWeight.w600)),
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

class _CountCard extends StatelessWidget {
  final String title;
  final Map<String, int> rows;
  final String unit;
  const _CountCard(
      {required this.title, required this.rows, required this.unit});

  @override
  Widget build(BuildContext context) {
    final entries = rows.entries.where((e) => e.value > 0).toList();
    if (entries.isEmpty) return const SizedBox.shrink();
    final top = entries.map((e) => e.value).reduce((a, b) => a > b ? a : b);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              for (final e in entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 108,
                        child: Text(e.key,
                            maxLines: 2,
                            style: const TextStyle(fontSize: 12.5)),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: e.value / top,
                            minHeight: 8,
                            backgroundColor:
                                Brand.indigo.withValues(alpha: 0.15),
                            valueColor:
                                const AlwaysStoppedAnimation(Brand.indigo),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('${e.value} $unit',
                          style: const TextStyle(
                              fontSize: 11.5, fontWeight: FontWeight.w600)),
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

// ======================================================================
//  Team
// ======================================================================
class _TeamTab extends StatelessWidget {
  final Stats stats;
  const _TeamTab({required this.stats});

  @override
  Widget build(BuildContext context) {
    final byCollector = <String, List<ClipView>>{};
    for (final c in stats.live) {
      byCollector.putIfAbsent(c.collectorName, () => []).add(c);
    }
    final rows = byCollector.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    final top = rows.isEmpty ? 1 : rows.first.value.length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        const _SectionTitle('Who collected what'),
        if (rows.isEmpty)
          const Text('No clips yet.')
        else
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 84,
                    child: Text(r.key,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: r.value.length / top,
                        minHeight: 10,
                        backgroundColor: Brand.teal.withValues(alpha: 0.15),
                        valueColor: const AlwaysStoppedAnimation(Brand.teal),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${r.value.length} cl · '
                    '${r.value.map((c) => c.speakerId).toSet().length} sp',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        const SizedBox(height: 20),
        const _SectionTitle('Phones'),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: SyncService.instance.devices.snapshots(),
          builder: (context, snap) {
            if (!snap.hasData) return const SizedBox.shrink();
            final now = DateTime.now();
            return Column(
              children: [
                for (final d in snap.data!.docs)
                  Builder(builder: (context) {
                    final m = d.data();
                    final seen = (m['lastSeen'] as Timestamp?)?.toDate();
                    final mins =
                        seen == null ? 9999 : now.difference(seen).inMinutes;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Card(
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.circle,
                              size: 11,
                              color: mins < 10
                                  ? const Color(0xFF2E7D32)
                                  : Colors.grey),
                          title: Text('${m['operator'] ?? '—'}'),
                          subtitle: Text(
                            '${m['deviceName'] ?? d.id}\n'
                            '${m['pending'] ?? 0} waiting · '
                            '${mins < 10 ? "active now" : seen == null ? "never seen" : "$mins min ago"}',
                          ),
                          isThreeLine: true,
                          trailing: m['corpusWritable'] == false
                              ? const Icon(Icons.cloud_off, color: Brand.urgent)
                              : null,
                        ),
                      ),
                    );
                  }),
              ],
            );
          },
        ),
      ],
    );
  }
}

// ======================================================================
//  Small pieces
// ======================================================================
class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
      );
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _Banner({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) => Card(
        color: color.withValues(alpha: 0.12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 12),
              Expanded(child: Text(text)),
            ],
          ),
        ),
      );
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const _Stat({required this.label, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
            child: Column(
              children: [
                Icon(icon, size: 20, color: Brand.teal),
                const SizedBox(height: 6),
                Text(value,
                    style: const TextStyle(
                        fontSize: 20, fontWeight: FontWeight.w800)),
                Text(label, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
      );
}

class _Line extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const _Line({
    required this.icon,
    required this.color,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle!,
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      );
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;
  const _Tag({required this.text, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w700, color: color)),
      );
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _Message({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 52, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 14),
              Text(title,
                  style:
                      const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(body, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}
