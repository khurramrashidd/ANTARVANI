/// The frozen phrase set. Do NOT reorder or renumber after collection starts —
/// the integer id is the training label and is baked into every file path.
class Phrase {
  final String id; // P01 .. P20
  final String devanagari;
  final String roman;
  final String english;

  const Phrase(this.id, this.devanagari, this.roman, this.english);
}

const List<Phrase> kPhrases = [
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
