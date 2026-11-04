import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/l10n.dart';
import '../../app/theme.dart';
import '../../services/speech_service.dart';

/// Caregiver contact and SOS. Long-press SOS: the phone calls out loud for
/// help (repeating) and opens the dialler with the caregiver's number.
class CaregiverScreen extends StatefulWidget {
  const CaregiverScreen({super.key});

  @override
  State<CaregiverScreen> createState() => _CaregiverScreenState();
}

class _CaregiverScreenState extends State<CaregiverScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  bool _sos = false;
  Timer? _repeat;

  @override
  void initState() {
    super.initState();
    Caregiver.load().then((v) {
      if (!mounted) return;
      _name.text = v.$1;
      _phone.text = v.$2;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _repeat?.cancel();
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await Caregiver.save(_name.text, _phone.text);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('saved'))));
    }
  }

  Future<void> _call() async {
    final n = _phone.text.replaceAll(RegExp(r'[^0-9+]'), '');
    if (n.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('care_none'))));
      return;
    }
    await launchUrl(Uri(scheme: 'tel', path: n));
  }

  void _startSos() {
    setState(() => _sos = true);
    void shout({bool log = false}) => SpeechService.instance
        .say(tr('sos_spoken'), lang: ttsLangForUi, source: 'sos', log: log);
    shout(log: true);
    _repeat = Timer.periodic(const Duration(seconds: 5), (_) => shout());
    _call();
  }

  void _stopSos() {
    _repeat?.cancel();
    _repeat = null;
    SpeechService.instance.stop();
    setState(() => _sos = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        const SizedBox(height: 8),
        Center(
          child: GestureDetector(
            onLongPress: _sos ? null : _startSos,
            onTap: _sos ? _stopSos : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 190,
              height: 190,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Brand.urgent,
                boxShadow: [
                  BoxShadow(
                    color: Brand.urgent.withValues(alpha: _sos ? 0.6 : 0.3),
                    blurRadius: _sos ? 40 : 18,
                    spreadRadius: _sos ? 10 : 2,
                  ),
                ],
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.campaign, color: Colors.white, size: 44),
                    Text(_sos ? tr('sos_stop') : tr('sos'),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w900)),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(_sos ? tr('sos_active') : tr('sos_hint'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 28),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TextField(
                  controller: _name,
                  decoration: InputDecoration(
                    labelText: tr('care_name'),
                    prefixIcon: const Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: tr('care_phone'),
                    prefixIcon: const Icon(Icons.phone_outlined),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(52)),
                        onPressed: _save,
                        child: Text(tr('save')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _call,
                        icon: const Icon(Icons.call),
                        label: Text(tr('care_call')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
