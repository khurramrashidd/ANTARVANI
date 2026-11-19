import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../app/theme.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';
import '../services/team.dart';
import 'background_upload_screen.dart';
import 'dashboard_screen.dart';

// ======================================================================
//  Dates, written the way a person reads them
// ======================================================================
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _two(int n) => n.toString().padLeft(2, '0');

/// "17 Nov, 08:47"
String _when(DateTime? d) => d == null
    ? '—'
    : '${d.day} ${_months[d.month - 1]}, ${_two(d.hour)}:${_two(d.minute)}';

/// "3 days ago", "20 min ago", "just now"
/// Shared with the background-upload page.
String agoText(DateTime? d) => _ago(d);

String _ago(DateTime? d) {
  if (d == null) return 'never';
  final m = DateTime.now().difference(d).inMinutes;
  if (m < 2) return 'just now';
  if (m < 60) return '$m min ago';
  if (m < 48 * 60) return '${m ~/ 60} h ago';
  return '${m ~/ 1440} days ago';
}

/// A clip is "stuck" once it has sat on a phone for a day without reaching
/// Drive. Anything newer is just a phone waiting for WiFi.
const _stuckAfter = Duration(hours: 24);

// ======================================================================
//  One collector's work
// ======================================================================
/// Everything one person recorded, gathered from the clips themselves.
///
/// The clip rows already carry who recorded them, on which phone and when,
/// so none of this needs new bookkeeping — only adding up.
class CollectorRow {
  /// The sign-in that recorded these clips. '' for clips recorded before
  /// the app stored it.
  final String email;
  final String name;
  final List<ClipView> clips;

  CollectorRow(this.email, this.name, this.clips);

  late final List<ClipView> waiting =
      clips.where((c) => !c.uploaded).toList();

  int get total => clips.length;
  int get uploaded => total - waiting.length;

  late final Set<String> speakerIds = {for (final c in clips) c.speakerId};
  late final Set<String> deviceIds = {
    for (final c in clips)
      if (c.deviceId.isNotEmpty) c.deviceId
  };

  late final List<DateTime> _times = () {
    final t = <DateTime>[];
    for (final c in clips) {
      final d = c.capturedAt;
      if (d != null) t.add(d);
    }
    t.sort();
    return t;
  }();

  DateTime? get firstClip => _times.isEmpty ? null : _times.first;
  DateTime? get lastClip => _times.isEmpty ? null : _times.last;

  /// Days this person actually recorded on.
  late final Set<String> days = {
    for (final c in clips)
      if (c.day.isNotEmpty) c.day
  };

  // ---- framing quality
  late final int flagged = clips.where((c) => c.qcVerdict != 'pass').length;
  late final int overridden = clips.where((c) => c.qcOverride).length;

  late final double avgFace = _mean([
    for (final c in clips)
      if (c.qcFaceScore >= 0) c.qcFaceScore
  ]);
  late final double avgMouth = _mean([
    for (final c in clips)
      if (c.qcMouthWidth >= 0) c.qcMouthWidth
  ]);

  static double _mean(List<double> v) =>
      v.isEmpty ? -1.0 : v.reduce((a, b) => a + b) / v.length;

  // ---- what is still missing from Drive
  /// Speaker id -> that speaker's clips this person has not uploaded.
  late final Map<String, List<ClipView>> waitingBySpeaker = () {
    final m = <String, List<ClipView>>{};
    for (final c in waiting) {
      m.putIfAbsent(c.speakerId, () => []).add(c);
    }
    return m;
  }();

  /// The longest a clip of theirs has been waiting.
  late final DateTime? oldestWaiting = () {
    final t = <DateTime>[];
    for (final c in waiting) {
      final d = c.capturedAt;
      if (d != null) t.add(d);
    }
    if (t.isEmpty) return null;
    t.sort();
    return t.first;
  }();

  bool get isStuck {
    final d = oldestWaiting;
    return d != null && DateTime.now().difference(d) > _stuckAfter;
  }
}

/// Groups every clip by who recorded it. Sorted so the people who still owe
/// uploads come first — that is what the page is for.
List<CollectorRow> collectorsOf(Stats stats) {
  final byEmail = <String, List<ClipView>>{};
  final names = <String, String>{};
  for (final c in stats.live) {
    final key = (c.collectorEmail ?? '').trim();
    byEmail.putIfAbsent(key, () => []).add(c);
    final n = c.collectorName.trim();
    if (n.isNotEmpty && n != '—') names[key] = n;
  }
  final rows = [
    for (final e in byEmail.entries)
      CollectorRow(
        e.key,
        names[e.key] ?? (e.key.isEmpty ? 'Unknown collector' : e.key),
        e.value,
      )
  ];
  rows.sort((a, b) {
    final w = b.waiting.length.compareTo(a.waiting.length);
    return w != 0 ? w : b.total.compareTo(a.total);
  });
  return rows;
}

// ======================================================================
//  The tab
// ======================================================================
/// Who recorded what, what is still on their phone, and how well it is framed.
///
/// Admins and the master see every collector by name. A collector sees their
/// own card in full plus the team's combined totals — enough to know whether
/// the corpus is behind, without putting anyone else's shortfall on display.
class CollectorsTab extends StatelessWidget {
  final Stats stats;
  const CollectorsTab({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final me = AuthService.instance.profile;
    final admin = me?.isAdmin ?? false;
    final everyone = collectorsOf(stats);
    final rows =
        admin ? everyone : everyone.where((r) => r.email == Team.email).toList();
    final names = {for (final s in stats.speakers) s.id: s};

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: SyncService.instance.devices.snapshots(),
      builder: (context, snap) {
        final devices = <String, Map<String, dynamic>>{
          for (final d in snap.data?.docs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[])
            d.id: d.data()
        };
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            // The team total is the same for everybody; only the named
            // breakdown below it depends on who is looking.
            _Totals(rows: everyone, mine: admin ? null : rows),
            const SizedBox(height: 16),
            if (rows.isEmpty)
              Text(admin
                  ? 'No clips recorded yet.'
                  : 'You have not recorded any clips yet.')
            else
              for (final r in rows)
                _CollectorCard(row: r, speakers: names, devices: devices),
            const SizedBox(height: 8),
            _QualityBySpeaker(stats: stats),
            const SizedBox(height: 16),
            Text(
              'Counts come from phones that have been online since recording. '
              'A phone that has never had signal since a session is not '
              'counted here at all — check its row under Team > Phones.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }
}

/// The whole team's figures. [mine] is set for a collector, who sees the
/// team total and their own share of it, but no other person's name.
class _Totals extends StatelessWidget {
  final List<CollectorRow> rows;
  final List<CollectorRow>? mine;
  const _Totals({required this.rows, this.mine});

  @override
  Widget build(BuildContext context) {
    final total = rows.fold<int>(0, (a, r) => a + r.total);
    final waiting = rows.fold<int>(0, (a, r) => a + r.waiting.length);
    final speakers = <String>{for (final r in rows) ...r.speakerIds};
    final own = mine;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('The whole team',
                style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Row(
              children: [
                _Fig(label: 'collectors', value: '${rows.length}'),
                _Fig(label: 'speakers', value: '${speakers.length}'),
                _Fig(label: 'clips', value: '$total'),
                _Fig(
                  label: 'not in Drive',
                  value: '$waiting',
                  warn: waiting > 0,
                ),
              ],
            ),
            if (waiting > 0) ...[
              const SizedBox(height: 10),
              Text(
                'Training reads Drive and nothing else, so those $waiting '
                'clip(s) do not count yet.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (own != null) ...[
              const Divider(height: 24),
              Text(
                own.isEmpty
                    ? 'None of these are yours yet.'
                    : 'Yours: ${own.first.total} clip(s), '
                        '${own.first.waiting.length} still to upload. '
                        'Your card is below.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Fig extends StatelessWidget {
  final String label;
  final String value;
  final bool warn;
  const _Fig({required this.label, required this.value, this.warn = false});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: warn ? Brand.urgent : null)),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      );
}

// ----------------------------------------------------------------------
class _CollectorCard extends StatelessWidget {
  final CollectorRow row;
  final Map<String, SpeakerView> speakers;
  final Map<String, Map<String, dynamic>> devices;

  const _CollectorCard({
    required this.row,
    required this.speakers,
    required this.devices,
  });

  /// The phone that holds the waiting clips, with how long since it was last
  /// heard from.
  List<Widget> _phones(BuildContext context) {
    final ids = {
      for (final c in row.waiting)
        if (c.deviceId.isNotEmpty) c.deviceId
    };
    if (ids.isEmpty) return const [];
    return [
      for (final id in ids)
        Builder(builder: (context) {
          final d = devices[id];
          final seen = (d?['lastSeen'] as Timestamp?)?.toDate();
          final cold = seen == null ||
              DateTime.now().difference(seen) > const Duration(hours: 12);
          final held =
              row.waiting.where((c) => c.deviceId == id).length;
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(cold ? Icons.phonelink_erase : Icons.smartphone,
                    size: 18, color: cold ? Brand.urgent : Brand.teal),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$held waiting on ${d?['deviceName'] ?? id} · '
                    'last online ${_ago(seen)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          );
        }),
    ];
  }

  Future<void> _nudge(BuildContext context) async {
    final n = row.waiting.length;
    final text = '${row.name}: $n clip(s) from '
        '${row.waitingBySpeaker.length} speaker(s) have not reached Drive '
        '(oldest ${_ago(row.oldestWaiting)}). Please open ANTARVANI on WiFi '
        'and leave it open until the upload chip clears.';
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send this to the team chat?'),
        content: Text(text),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Send')),
        ],
      ),
    );
    if (go != true) return;
    try {
      await FirebaseFirestore.instance.collection('messages').add({
        'text': text,
        'authorEmail': Team.email,
        'authorName': Team.displayName,
        'deviceId': SyncService.instance.deviceId,
        'createdAt': FieldValue.serverTimestamp(),
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Sent to the team chat.')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not send: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final mine = row.email == Team.email;
    final admin = AuthService.instance.profile?.isAdmin ?? false;
    final quality = row.total == 0
        ? 'no clips'
        : [
            '${(row.flagged * 100 / row.total).round()}% flagged',
            if (row.avgFace >= 0) 'face ${(row.avgFace * 100).round()}%',
            if (row.avgMouth >= 0)
              'mouth ${(row.avgMouth * 100).toStringAsFixed(1)}% of frame',
          ].join(' · ');

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(row.name + (mine ? '  (you)' : ''),
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w800)),
                      if (row.email.isNotEmpty)
                        Text(row.email, style: small),
                    ],
                  ),
                ),
                if (row.isStuck)
                  const Chip(
                    visualDensity: VisualDensity.compact,
                    backgroundColor: Color(0x22D32F2F),
                    label: Text('stuck'),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _Fig(label: 'clips', value: '${row.total}'),
                _Fig(label: 'in Drive', value: '${row.uploaded}'),
                _Fig(
                    label: 'waiting',
                    value: '${row.waiting.length}',
                    warn: row.waiting.isNotEmpty),
                _Fig(label: 'speakers', value: '${row.speakerIds.length}'),
              ],
            ),
            const Divider(height: 22),
            _Line(
              icon: Icons.event_outlined,
              text: 'First ${_when(row.firstClip)} · '
                  'last ${_when(row.lastClip)} · '
                  '${row.days.length} day(s)',
            ),
            _Line(icon: Icons.center_focus_weak, text: quality),
            ..._phones(context),
            if (row.waiting.isNotEmpty) ...[
              const SizedBox(height: 4),
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  title: Text(
                    'Not in Drive: ${row.waitingBySpeaker.length} speaker(s)',
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, color: Brand.urgent),
                  ),
                  children: [
                    for (final e in (row.waitingBySpeaker.entries.toList()
                      ..sort((a, b) =>
                          b.value.length.compareTo(a.value.length))))
                      _WaitingSpeaker(
                        speakerId: e.key,
                        speaker: speakers[e.key],
                        clips: e.value,
                      ),
                  ],
                ),
              ),
              if (admin)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => _nudge(context),
                    icon: const Icon(Icons.campaign_outlined),
                    label: Text(mine ? 'Post a reminder' : 'Nudge ${row.name}'),
                  ),
                ),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 8),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle,
                        size: 18, color: Color(0xFF2E7D32)),
                    const SizedBox(width: 8),
                    Text('Everything uploaded', style: small),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Line({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: Brand.indigo),
            const SizedBox(width: 8),
            Expanded(
                child: Text(text,
                    style: Theme.of(context).textTheme.bodySmall)),
          ],
        ),
      );
}

/// One speaker whose clips are still on somebody's phone.
class _WaitingSpeaker extends StatelessWidget {
  final String speakerId;
  final SpeakerView? speaker;
  final List<ClipView> clips;

  const _WaitingSpeaker({
    required this.speakerId,
    required this.speaker,
    required this.clips,
  });

  @override
  Widget build(BuildContext context) {
    final name = (speaker?.name ?? '').trim();
    final phrases = (clips.map((c) => c.phraseId).toSet().toList()..sort());
    final shown = phrases.take(8).join(', ');
    final times = <DateTime>[];
    for (final c in clips) {
      final d = c.capturedAt;
      if (d != null) times.add(d);
    }
    times.sort();
    final oldest = times.isEmpty ? null : times.first;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.cloud_upload_outlined, size: 18, color: Brand.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? speakerId : '$name  ($speakerId)',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  '${clips.length} clip(s) · recorded ${_when(oldest)}\n'
                  '$shown${phrases.length > 8 ? ' …' : ''}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------
/// Which speakers were filmed worst. The face check already judged every
/// clip at capture time; this is only reading back what it said.
class _QualityBySpeaker extends StatelessWidget {
  final Stats stats;
  const _QualityBySpeaker({required this.stats});

  @override
  Widget build(BuildContext context) {
    final rows = <({String id, String name, int n, int flagged, double face})>[];
    final names = {for (final s in stats.speakers) s.id: s.name};
    final bySpeaker = <String, List<ClipView>>{};
    for (final c in stats.live) {
      bySpeaker.putIfAbsent(c.speakerId, () => []).add(c);
    }
    for (final e in bySpeaker.entries) {
      final scored = [
        for (final c in e.value)
          if (c.qcFaceScore >= 0) c.qcFaceScore
      ];
      rows.add((
        id: e.key,
        name: (names[e.key] ?? '').trim(),
        n: e.value.length,
        flagged: e.value.where((c) => c.qcVerdict != 'pass').length,
        face: scored.isEmpty
            ? -1.0
            : scored.reduce((a, b) => a + b) / scored.length,
      ));
    }
    rows.sort((a, b) => a.face.compareTo(b.face));
    final worst = rows.where((r) => r.face >= 0).take(8).toList();
    if (worst.isEmpty) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Framing — worst speakers first',
                style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(
              'Face score is how much of the clip the camera could actually '
              'see a face in. Below about 60% the clip is dropped when '
              'training, so a low row here is data you will lose.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            for (final r in worst)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    SizedBox(
                      width: 110,
                      child: Text(
                        r.name.isEmpty ? r.id : r.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: r.face.clamp(0.0, 1.0).toDouble(),
                          minHeight: 10,
                          backgroundColor: Brand.teal.withValues(alpha: 0.15),
                          valueColor: AlwaysStoppedAnimation(
                              r.face < 0.6 ? Brand.urgent : Brand.teal),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 96,
                      child: Text(
                        '${(r.face * 100).round()}% · ${r.flagged}/${r.n}',
                        textAlign: TextAlign.right,
                        style: Theme.of(context).textTheme.bodySmall,
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

// ======================================================================
//  Pieces used on other screens
// ======================================================================
/// Overview banner: clips that have been sitting on a phone for over a day.
class StuckClipsAlert extends StatelessWidget {
  final Stats stats;
  const StuckClipsAlert({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final stuck = collectorsOf(stats).where((r) => r.isStuck).toList();
    if (stuck.isEmpty) return const SizedBox.shrink();
    final n = stuck.fold<int>(0, (a, r) => a + r.waiting.length);
    return Card(
      color: Brand.urgent.withValues(alpha: 0.10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Brand.urgent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '$n clip(s) have been waiting over a day',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final r in stuck)
              Text(
                '${r.name}: ${r.waiting.length} clip(s) from '
                '${r.waitingBySpeaker.length} speaker(s), oldest '
                '${_ago(r.oldestWaiting)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 4),
            const Text('See the Collectors tab for who holds what.',
                style: TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// Shown on a collector's own home screen while clips are still on the phone.
/// The person who can fix it is the one holding the phone, so the warning
/// belongs where they will actually see it.
class MyUploadWarning extends StatefulWidget {
  const MyUploadWarning({super.key});

  @override
  State<MyUploadWarning> createState() => _MyUploadWarningState();
}

class _MyUploadWarningState extends State<MyUploadWarning> {
  bool _busy = false;

  Future<void> _retry() async {
    setState(() => _busy = true);
    // Repairs the queue first: after a reinstall the dashboard can say
    // clips are waiting while the phone's own queue is empty.
    final msg = await SyncService.instance.uploadNow();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 6)));
  }

  @override
  Widget build(BuildContext context) {
    final me = AuthService.instance.profile;
    if (me == null || !me.isTeam) return const SizedBox.shrink();
    final sync = SyncService.instance;
    return AnimatedBuilder(
      animation: sync,
      builder: (context, _) {
        if (sync.pendingCount == 0) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Card(
            color: Brand.urgent.withValues(alpha: 0.10),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.cloud_upload, color: Brand.urgent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '${sync.pendingCount} clip(s) are still on this '
                          'phone',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'They are not in Drive yet, so they do not count towards '
                    'the dataset. Any connection will do — WiFi or mobile '
                    'data.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: _busy ? null : _retry,
                        icon: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.refresh),
                        label: Text(_busy ? 'Uploading…' : 'Upload now'),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(sync.status,
                            style: Theme.of(context).textTheme.bodySmall),
                      ),
                    ],
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                            builder: (_) => const BackgroundUploadScreen()),
                      ),
                      icon: const Icon(Icons.autorenew),
                      label: const Text('Keep uploading after I close the app'),
                    ),
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
