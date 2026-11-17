/// The frozen phrase set. Do NOT reorder or renumber after collection starts —
/// the integer id is the training label and is baked into every file path.
class Phrase {
  final String id; // P01 .. P20
  final String devanagari;
  final String roman;
  final String english;

  const Phrase(this.id, this.devanagari, this.roman, this.english);
}

const List<Phrase> kHindiPhrases = [
  Phrase('P01', 'मुझे पानी चाहिए', 'mujhe paani chahiye', 'I need water'),
  Phrase('P02', 'दर्द हो रहा है', 'dard ho raha hai', "I'm in pain"),
  Phrase('P03', 'डॉक्टर को बुलाओ', 'doctor ko bulao', 'Call the doctor'),
  Phrase('P04', 'मुझे भूख लगी है', 'mujhe bhookh lagi hai', "I'm hungry"),
  Phrase('P05', 'बाथरूम जाना है', 'bathroom jaana hai', 'I need the toilet'),
  Phrase('P06', 'पंखा चालू करो', 'pankha chaalu karo', 'Turn the fan on'),
  Phrase('P07', 'लाइट बंद करो', 'light band karo', 'Turn the light off'),
  Phrase('P08', 'मुझे ठंड लग रही है', 'mujhe thand lag rahi hai', "I'm cold"),
  Phrase('P09', 'थोड़ा ऊपर उठाओ', 'thoda oopar uthao', 'Sit me up a bit'),
  Phrase('P10', 'दवा का समय हुआ', 'dawa ka samay hua', 'Time for medicine'),
  Phrase('P11', 'मुझे नींद आ रही है', 'mujhe neend aa rahi hai', "I'm sleepy"),
  Phrase('P12', 'सांस लेने में तकलीफ', 'saans lene mein takleef', 'Trouble breathing'),
  Phrase('P13', 'घर जाना है', 'ghar jaana hai', 'I want to go home'),
  Phrase('P14', 'किसी को बुलाओ', 'kisi ko bulao', 'Call someone'),
  Phrase('P15', 'ठीक है', 'theek hai', "Yes / it's fine"),
  Phrase('P16', 'नहीं चाहिए', 'nahi chahiye', "I don't want it"),
  Phrase('P17', 'धन्यवाद', 'dhanyavaad', 'Thank you'),
  Phrase('P18', 'थोड़ा रुको', 'thoda ruko', 'Wait a moment'),
  Phrase('P19', 'खिड़की खोलो', 'khidki kholo', 'Open the window'),
  Phrase('P20', 'चादर ठीक करो', 'chaadar theek karo', 'Fix the blanket'),
];

/// One language the app can collect and recognise: a code, a voice, and its
/// own numbered phrase list. Hindi is built in; the others are added by an
/// admin and arrive from Firestore.
class Language {
  final String code; // hi, mr, gu ...
  final String name;
  final String tts; // BCP-47 voice, e.g. hi-IN
  final List<Phrase> phrases;

  const Language(this.code, this.name, this.tts, this.phrases);

  Map<String, dynamic> toMap() => {
        'code': code,
        'name': name,
        'tts': tts,
        'phrases': [
          for (final p in phrases)
            {
              'id': p.id,
              'text': p.devanagari,
              'roman': p.roman,
              'english': p.english,
            }
        ],
      };

  /// Reads the shape the training notebook writes and the app stores.
  /// Phrases may be maps or [id, text, roman, english] rows. Returns null
  /// with a reason when the list cannot be used as training labels.
  static (Language?, String?) parse(Map<String, dynamic> m) {
    final code = '${m['code'] ?? m['lang'] ?? ''}'.trim().toLowerCase();
    if (!RegExp(r'^[a-z]{2,3}$').hasMatch(code)) {
      return (null, 'The language code must be 2 or 3 letters, like "mr".');
    }
    final raw = (m['phrases'] ?? m['labels']) as List? ?? const [];
    if (raw.length < 2 || raw.length > 99) {
      return (null, 'A language needs between 2 and 99 phrases.');
    }
    final out = <Phrase>[];
    for (var i = 0; i < raw.length; i++) {
      final r = raw[i];
      String id, text, roman, english;
      if (r is Map) {
        id = '${r['id'] ?? ''}';
        text = '${r['text'] ?? r['native'] ?? ''}';
        roman = '${r['roman'] ?? ''}';
        english = '${r['english'] ?? ''}';
      } else if (r is List && r.length >= 2) {
        id = '${r[0]}';
        text = '${r[1]}';
        roman = r.length > 2 ? '${r[2]}' : '';
        english = r.length > 3 ? '${r[3]}' : '';
      } else {
        return (null, 'Phrase ${i + 1} is not readable.');
      }
      final want = 'P${(i + 1).toString().padLeft(2, '0')}';
      if (id != want) {
        return (null, 'Phrases must be numbered in order: expected $want, '
            'found "$id".');
      }
      if (text.trim().isEmpty) return (null, '$want has no text.');
      out.add(Phrase(id, text.trim(), roman.trim(), english.trim()));
    }
    final name = '${m['name'] ?? code}'.trim();
    final tts = '${m['tts'] ?? '$code-IN'}'.trim();
    return (Language(code, name.isEmpty ? code : name, tts, out), null);
  }
}

/// Which language this phone is working in. One setting covers both sides:
/// collectors record its phrases into its Drive folder, and the patient's
/// Speak screen uses its model.
class PhraseBook {
  static const Language hindi = Language('hi', 'Hindi', 'hi-IN', kHindiPhrases);

  static final Map<String, Language> all = {'hi': hindi};
  static String code = 'hi';

  static Language get current => all[code] ?? hindi;
  static bool get isHindi => current.code == 'hi';
}

/// The phrases of the language in use. Everything that lists, counts or
/// records phrases reads this, so a new language needs no screen changes.
List<Phrase> get kPhrases => PhraseBook.current.phrases;

/// Recording spec — these values go into every session.json so you always know
/// which spec a clip was captured under. Change them only with a version bump.
class RecSpec {
  static const int clipMillis = 3000; // exact clip length
  static const int countdownSeconds = 3;
  static const String specVersion = 'spec-1';
  static const bool recordAudio = false; // never record audio
}

/// Tier A = breadth (many speakers, one take each). Tier B = depth (few
/// speakers, many takes) — Tier B speakers are the held-out set for the personalisation study.
enum Tier { a, b }

extension TierInfo on Tier {
  String get label =>
      this == Tier.a ? 'A — breadth (1 take)' : 'B — depth (10 takes)';
  String get code => this == Tier.a ? 'A' : 'B';
  int get takes => this == Tier.a ? 1 : 10;
}
