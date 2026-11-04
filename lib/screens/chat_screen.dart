import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../services/sync_service.dart';
import '../services/team.dart';

/// Team chat. Firestore has offline persistence switched on in SyncService, so
/// a message typed with no signal is queued locally and sent when a connection
/// appears — the same behaviour as the clip uploads.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;

  CollectionReference<Map<String, dynamic>> get _messages =>
      FirebaseFirestore.instance.collection('messages');

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _ctrl.clear();
    try {
      await _messages.add({
        'text': text,
        'authorEmail': Team.email,
        'authorName': Team.displayName,
        'deviceId': SyncService.instance.deviceId,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send: $e')),
        );
        _ctrl.text = text; // give it back rather than losing it
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Team.signedIn) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Sign in to the project Google account to use team chat.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Column(
      children: [
        const _PresenceBar(),
        const Divider(height: 1),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: _messages
                .orderBy('createdAt', descending: true)
                .limit(200)
                .snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return _Hint(
                  'Cannot read messages.\n\n'
                  'Usually this means your account is not a Collector yet, '
                  'so the security rules are refusing. Ask the master admin '
                  'to set your role in Users & roles.\n\n${snap.error}',
                );
              }
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final docs = snap.data!.docs;
              if (docs.isEmpty) {
                return const _Hint('No messages yet. Say something.');
              }
              return ListView.builder(
                controller: _scroll,
                reverse: true, // newest at the bottom, grows upward
                padding: const EdgeInsets.symmetric(vertical: 10),
                itemCount: docs.length,
                itemBuilder: (context, i) {
                  final m = docs[i].data();
                  final mine = m['authorEmail'] == Team.email;
                  // Pending server timestamp shows as null for a moment.
                  final ts = (m['createdAt'] as Timestamp?)?.toDate();
                  return _Bubble(
                    text: (m['text'] as String?) ?? '',
                    author: (m['authorName'] as String?) ?? '?',
                    at: ts,
                    mine: mine,
                    pending: ts == null,
                  );
                },
              );
            },
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: 'Message the team',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Who has the app open, from the `devices` heartbeat the sync service writes.
class _PresenceBar extends StatelessWidget {
  const _PresenceBar();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: SyncService.instance.devices.snapshots(),
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox(height: 34);
        final now = DateTime.now();
        final active = <String>[];
        for (final d in snap.data!.docs) {
          final seen = (d.data()['lastSeen'] as Timestamp?)?.toDate();
          final who = (d.data()['operator'] as String?) ?? '';
          if (seen != null &&
              who.isNotEmpty &&
              now.difference(seen).inMinutes < 10) {
            active.add(who);
          }
        }
        return SizedBox(
          height: 34,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(Icons.circle,
                    size: 9,
                    color: active.isEmpty ? Colors.grey : Colors.green),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    active.isEmpty
                        ? 'nobody else active in the last 10 minutes'
                        : 'active now: ${active.join(", ")}',
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
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

class _Bubble extends StatelessWidget {
  final String text;
  final String author;
  final DateTime? at;
  final bool mine;
  final bool pending;

  const _Bubble({
    required this.text,
    required this.author,
    required this.at,
    required this.mine,
    required this.pending,
  });

  String get _time {
    if (at == null) return 'sending…';
    final h = at!.hour.toString().padLeft(2, '0');
    final m = at!.minute.toString().padLeft(2, '0');
    final today = DateTime.now();
    final sameDay = at!.year == today.year &&
        at!.month == today.month &&
        at!.day == today.day;
    return sameDay ? '$h:$m' : '${at!.day}/${at!.month} $h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78),
        margin: const EdgeInsets.fromLTRB(12, 3, 12, 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(mine ? 12 : 2),
            bottomRight: Radius.circular(mine ? 2 : 12),
          ),
        ),
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!mine)
              Text(author,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold, color: scheme.primary)),
            Text(text, style: const TextStyle(height: 1.3)),
            Text(_time,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontSize: 10, color: scheme.outline)),
          ],
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;
  const _Hint(this.text);
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall),
        ),
      );
}
