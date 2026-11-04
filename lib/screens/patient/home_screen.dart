import 'package:flutter/material.dart';

import '../../app/l10n.dart';
import '../../app/theme.dart';
import '../../services/auth_service.dart';
import '../../services/speech_service.dart';
import '../../widgets/common.dart';
import '../home_shell.dart';

/// The patient's start page: quick replies on top, then every feature as a
/// large card.
class PatientHome extends StatelessWidget {
  final ValueChanged<Dest> onOpen;
  const PatientHome({super.key, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final me = AuthService.instance.profile;
    final first = (me?.name ?? '').split(' ').first;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        Text('${tr('hello')}${first.isEmpty ? '' : ', $first'}',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(tr('home_sub'), style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 16),
        const QuickReplies(),
        const SizedBox(height: 8),
        _SpeakHero(onTap: () => onOpen(Dest.speak)),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.95,
          children: [
            FeatureTile(
              icon: Icons.grid_view,
              title: tr('menu_board'),
              subtitle: tr('board_desc'),
              color: Brand.teal,
              onTap: () => onOpen(Dest.board),
            ),
            FeatureTile(
              icon: Icons.keyboard,
              title: tr('menu_type'),
              subtitle: tr('type_desc'),
              color: Brand.indigo,
              onTap: () => onOpen(Dest.type),
            ),
            FeatureTile(
              icon: Icons.tune,
              title: tr('menu_personalise'),
              subtitle: tr('personalise_desc'),
              color: const Color(0xFF7B5EA7),
              soon: true,
              onTap: () => onOpen(Dest.personalise),
            ),
            FeatureTile(
              icon: Icons.history,
              title: tr('menu_history'),
              subtitle: tr('history_desc'),
              color: const Color(0xFFB7791F),
              onTap: () => onOpen(Dest.history),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FeatureTile(
          icon: Icons.health_and_safety,
          title: tr('menu_caregiver'),
          subtitle: tr('caregiver_desc'),
          color: Brand.urgent,
          onTap: () => onOpen(Dest.caregiver),
        ),
        const SizedBox(height: 12),
        FeatureTile(
          icon: Icons.badge,
          title: tr('menu_my_clips'),
          subtitle: tr('mine_desc'),
          color: Brand.teal,
          onTap: () => onOpen(Dest.myClips),
        ),
      ],
    );
  }
}

class _SpeakHero extends StatelessWidget {
  final VoidCallback onTap;
  const _SpeakHero({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: const BoxDecoration(gradient: Brand.gradient),
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(tr('speak_title'),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w800)),
                        const ComingSoonChip(),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(tr('speak_desc'),
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.9))),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: const BoxDecoration(
                    color: Brand.amber, shape: BoxShape.circle),
                child: const Icon(Icons.record_voice_over,
                    color: Brand.indigo, size: 30),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Yes / No / Wait / Help — the four things most often needed, one tap each,
/// spoken in the app's current language.
class QuickReplies extends StatelessWidget {
  const QuickReplies({super.key});

  @override
  Widget build(BuildContext context) {
    final items = [
      ('quick_yes', Icons.check_circle, const Color(0xFF2E7D32)),
      ('quick_no', Icons.cancel, const Color(0xFF6D4C41)),
      ('quick_wait', Icons.pan_tool, Brand.indigo),
      ('quick_help', Icons.priority_high, Brand.urgent),
    ];
    return Row(
      children: [
        for (final (key, icon, color) in items)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Material(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => SpeechService.instance
                      .say(tr(key), lang: ttsLangForUi, source: 'quick'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Column(
                      children: [
                        Icon(icon, color: color, size: 28),
                        const SizedBox(height: 6),
                        Text(tr(key),
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontWeight: FontWeight.w700, color: color)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
