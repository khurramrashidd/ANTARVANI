import '../phrases.dart';
import 'settings.dart';

/// Every word the patient side shows, in English, Hindi and Marathi.
/// `tr('key')` returns the current language, falling back to English.
/// The team-only data-collection screens stay in English.
String tr(String key) {
  final row = _s[key];
  if (row == null) return key;
  return row[AppSettings.instance.lang] ?? row['en'] ?? key;
}

/// Same, with {n}-style placeholders filled in.
String trf(String key, Map<String, Object> args) {
  var s = tr(key);
  args.forEach((k, v) => s = s.replaceAll('{$k}', '$v'));
  return s;
}

/// All keys, for the completeness test.
Iterable<String> get allKeys => _s.keys;
Map<String, String>? rowFor(String key) => _s[key];

/// The phrase's meaning in the current language. Hindi needs none: the
/// phrase itself is Hindi.
String phraseMeaning(Phrase p) {
  switch (AppSettings.instance.lang) {
    case 'mr':
      return _marathi[p.id] ?? p.english;
    case 'hi':
      return p.roman;
    default:
      return p.english;
  }
}

/// BCP-47 voice for speaking in the current language.
String get ttsLangForUi => const {
      'en': 'en-IN',
      'hi': 'hi-IN',
      'mr': 'mr-IN',
    }[AppSettings.instance.lang]!;

List<String> get weekdays => _weekdays[AppSettings.instance.lang]!;
List<String> get months => _months[AppSettings.instance.lang]!;

const _weekdays = {
  'en': ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'],
  'hi': ['सोमवार', 'मंगलवार', 'बुधवार', 'गुरुवार', 'शुक्रवार', 'शनिवार', 'रविवार'],
  'mr': ['सोमवार', 'मंगळवार', 'बुधवार', 'गुरुवार', 'शुक्रवार', 'शनिवार', 'रविवार'],
};

const _months = {
  'en': ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'],
  'hi': ['जनवरी', 'फ़रवरी', 'मार्च', 'अप्रैल', 'मई', 'जून', 'जुलाई', 'अगस्त', 'सितंबर', 'अक्टूबर', 'नवंबर', 'दिसंबर'],
  'mr': ['जानेवारी', 'फेब्रुवारी', 'मार्च', 'एप्रिल', 'मे', 'जून', 'जुलै', 'ऑगस्ट', 'सप्टेंबर', 'ऑक्टोबर', 'नोव्हेंबर', 'डिसेंबर'],
};

const _marathi = {
  'P01': 'मला पाणी हवे आहे',
  'P02': 'मला दुखत आहे',
  'P03': 'डॉक्टरांना बोलवा',
  'P04': 'मला भूक लागली आहे',
  'P05': 'मला बाथरूमला जायचे आहे',
  'P06': 'पंखा चालू करा',
  'P07': 'दिवा बंद करा',
  'P08': 'मला थंडी वाजत आहे',
  'P09': 'मला थोडे वर उचला',
  'P10': 'औषधाची वेळ झाली',
  'P11': 'मला झोप येत आहे',
  'P12': 'श्वास घ्यायला त्रास होत आहे',
  'P13': 'मला घरी जायचे आहे',
  'P14': 'कोणालातरी बोलवा',
  'P15': 'ठीक आहे',
  'P16': 'नको आहे',
  'P17': 'धन्यवाद',
  'P18': 'थोडे थांबा',
  'P19': 'खिडकी उघडा',
  'P20': 'चादर नीट करा',
};

const Map<String, Map<String, String>> _s = {
  // ---------------------------------------------------------------- common
  'app_name': {'en': 'ANTARVANI', 'hi': 'अंतर्वाणी', 'mr': 'अंतर्वाणी'},
  'tagline': {
    'en': 'The inner voice, restored',
    'hi': 'भीतर की आवाज़, फिर से',
    'mr': 'आतला आवाज, पुन्हा',
  },
  'coming_soon': {'en': 'Coming soon', 'hi': 'जल्द आ रहा है', 'mr': 'लवकरच येत आहे'},
  'cancel': {'en': 'Cancel', 'hi': 'रद्द करें', 'mr': 'रद्द करा'},
  'save': {'en': 'Save', 'hi': 'सहेजें', 'mr': 'जतन करा'},
  'saved': {'en': 'Saved', 'hi': 'सहेजा गया', 'mr': 'जतन केले'},

  // ----------------------------------------------------------------- login
  'login_title': {'en': 'Welcome', 'hi': 'स्वागत है', 'mr': 'स्वागत आहे'},
  'login_body': {
    'en': 'Sign in with Google to continue. New here? The same button creates your account.',
    'hi': 'आगे बढ़ने के लिए Google से साइन इन करें। नए हैं? यही बटन आपका खाता बना देगा।',
    'mr': 'पुढे जाण्यासाठी Google ने साइन इन करा. नवीन आहात? हेच बटण तुमचे खाते तयार करेल.',
  },
  'continue_google': {
    'en': 'Continue with Google',
    'hi': 'Google के साथ जारी रखें',
    'mr': 'Google सह पुढे चला',
  },
  'signing_in': {'en': 'Signing in…', 'hi': 'साइन इन हो रहा है…', 'mr': 'साइन इन होत आहे…'},
  'login_failed': {
    'en': 'Sign-in did not complete. Check your internet and try again.',
    'hi': 'साइन इन पूरा नहीं हुआ। इंटरनेट जाँचें और फिर कोशिश करें।',
    'mr': 'साइन इन पूर्ण झाले नाही. इंटरनेट तपासा आणि पुन्हा प्रयत्न करा.',
  },
  'login_privacy': {
    'en': 'No audio is ever recorded. Your videos stay private.',
    'hi': 'कभी भी आवाज़ रिकॉर्ड नहीं होती। आपके वीडियो निजी रहते हैं।',
    'mr': 'कधीही आवाज रेकॉर्ड होत नाही. तुमचे व्हिडिओ खाजगी राहतात.',
  },

  // ---------------------------------------------------------------- drawer
  'menu_home': {'en': 'Home', 'hi': 'होम', 'mr': 'मुख्यपृष्ठ'},
  'menu_speak': {'en': 'Speak', 'hi': 'बोलें', 'mr': 'बोला'},
  'menu_board': {'en': 'Phrase board', 'hi': 'वाक्य बोर्ड', 'mr': 'वाक्य फलक'},
  'menu_type': {'en': 'Type to speak', 'hi': 'लिखकर बोलें', 'mr': 'लिहून बोला'},
  'menu_personalise': {'en': 'Personalise', 'hi': 'मेरे अनुसार बनाएं', 'mr': 'माझ्यासाठी तयार करा'},
  'menu_history': {'en': 'History', 'hi': 'इतिहास', 'mr': 'इतिहास'},
  'menu_caregiver': {'en': 'Caregiver & SOS', 'hi': 'देखभालकर्ता और SOS', 'mr': 'काळजीवाहक आणि SOS'},
  'sec_patient': {'en': 'Communicate', 'hi': 'बातचीत', 'mr': 'संवाद'},
  'sec_collect': {'en': 'Collect data', 'hi': 'डेटा संग्रह', 'mr': 'डेटा संकलन'},
  'menu_new_session': {'en': 'New recording session', 'hi': 'नया रिकॉर्डिंग सत्र', 'mr': 'नवीन रेकॉर्डिंग सत्र'},
  'menu_corpus': {'en': 'Progress & uploads', 'hi': 'प्रगति और अपलोड', 'mr': 'प्रगती आणि अपलोड'},
  'menu_chat': {'en': 'Team chat', 'hi': 'टीम चैट', 'mr': 'टीम चॅट'},
  'menu_import': {
    'en': 'Import from Drive',
    'hi': 'ड्राइव से आयात करें',
    'mr': 'ड्राइव्हवरून आयात करा',
  },
  'sec_admin': {'en': 'Admin', 'hi': 'एडमिन', 'mr': 'प्रशासक'},
  'menu_users': {'en': 'Users & roles', 'hi': 'उपयोगकर्ता और भूमिकाएँ', 'mr': 'वापरकर्ते आणि भूमिका'},
  'menu_my_clips': {
    'en': 'My recordings',
    'hi': 'मेरी रिकॉर्डिंग',
    'mr': 'माझ्या रेकॉर्डिंग',
  },
  'menu_settings': {'en': 'Settings', 'hi': 'सेटिंग्स', 'mr': 'सेटिंग्ज'},
  'menu_signout': {'en': 'Sign out', 'hi': 'साइन आउट', 'mr': 'साइन आउट'},
  'dark_mode': {'en': 'Dark mode', 'hi': 'डार्क मोड', 'mr': 'डार्क मोड'},
  'language': {'en': 'Language', 'hi': 'भाषा', 'mr': 'भाषा'},

  'role_patient': {'en': 'Patient', 'hi': 'मरीज़', 'mr': 'रुग्ण'},
  'role_member': {'en': 'Collector', 'hi': 'संग्रहकर्ता', 'mr': 'संकलक'},
  'role_admin': {'en': 'Admin', 'hi': 'एडमिन', 'mr': 'प्रशासक'},
  'role_master': {'en': 'Master admin', 'hi': 'मास्टर एडमिन', 'mr': 'मास्टर प्रशासक'},

  'weather_loading': {'en': 'Getting weather…', 'hi': 'मौसम देखा जा रहा है…', 'mr': 'हवामान पाहत आहे…'},
  'location_off': {'en': 'Allow location for weather', 'hi': 'मौसम के लिए लोकेशन दें', 'mr': 'हवामानासाठी स्थान द्या'},
  'w_clear': {'en': 'Clear', 'hi': 'साफ़', 'mr': 'निरभ्र'},
  'w_cloudy': {'en': 'Cloudy', 'hi': 'बादल', 'mr': 'ढगाळ'},
  'w_fog': {'en': 'Fog', 'hi': 'कोहरा', 'mr': 'धुके'},
  'w_drizzle': {'en': 'Drizzle', 'hi': 'बूंदाबांदी', 'mr': 'रिमझिम'},
  'w_rain': {'en': 'Rain', 'hi': 'बारिश', 'mr': 'पाऊस'},
  'w_snow': {'en': 'Snow', 'hi': 'बर्फ़', 'mr': 'हिमवर्षाव'},
  'w_storm': {'en': 'Thunderstorm', 'hi': 'आंधी-तूफ़ान', 'mr': 'वादळ'},

  // ------------------------------------------------------------------ home
  'hello': {'en': 'Hello', 'hi': 'नमस्ते', 'mr': 'नमस्कार'},
  'home_sub': {
    'en': 'What would you like to say?',
    'hi': 'आप क्या कहना चाहेंगे?',
    'mr': 'तुम्हाला काय सांगायचे आहे?',
  },
  'quick_yes': {'en': 'Yes', 'hi': 'हाँ', 'mr': 'हो'},
  'quick_no': {'en': 'No', 'hi': 'नहीं', 'mr': 'नाही'},
  'quick_wait': {'en': 'Wait', 'hi': 'रुको', 'mr': 'थांबा'},
  'quick_help': {'en': 'I need help', 'hi': 'मदद चाहिए', 'mr': 'मदत हवी आहे'},
  'speak_desc': {
    'en': 'Mouth a phrase silently, the app says it aloud',
    'hi': 'बिना आवाज़ वाक्य बोलें, ऐप उसे ज़ोर से कहेगा',
    'mr': 'आवाजाशिवाय वाक्य बोला, अ‍ॅप ते मोठ्याने सांगेल',
  },
  'board_desc': {'en': 'Tap a phrase to speak it', 'hi': 'वाक्य दबाएँ, ऐप बोलेगा', 'mr': 'वाक्य दाबा, अ‍ॅप बोलेल'},
  'type_desc': {
    'en': 'Type anything, the app reads it out',
    'hi': 'कुछ भी लिखें, ऐप पढ़कर सुनाएगा',
    'mr': 'काहीही लिहा, अ‍ॅप वाचून दाखवेल',
  },
  'personalise_desc': {
    'en': 'Teach the app your way of speaking',
    'hi': 'ऐप को अपने बोलने का तरीका सिखाएँ',
    'mr': 'अ‍ॅपला तुमची बोलण्याची पद्धत शिकवा',
  },
  'history_desc': {'en': 'Everything said recently', 'hi': 'हाल में कही गई बातें', 'mr': 'अलीकडे सांगितलेले सर्व'},
  'caregiver_desc': {
    'en': 'Call your caregiver in one tap',
    'hi': 'एक टैप में देखभालकर्ता को कॉल करें',
    'mr': 'एका टॅपमध्ये काळजीवाहकाला कॉल करा',
  },

  // ----------------------------------------------------------------- speak
  'speak_title': {'en': 'Speak silently', 'hi': 'बिना आवाज़ बोलें', 'mr': 'आवाजाशिवाय बोला'},
  'speak_hint': {
    'en': 'Hold the phone at eye level. Keep your lips inside the frame.',
    'hi': 'फ़ोन आँखों के स्तर पर रखें। होंठ फ्रेम के अंदर रखें।',
    'mr': 'फोन डोळ्यांच्या पातळीवर धरा. ओठ चौकटीत ठेवा.',
  },
  'speak_start': {'en': 'Start', 'hi': 'शुरू करें', 'mr': 'सुरू करा'},
  'speak_soon': {
    'en': 'Lip reading arrives with the trained model. Use the phrase board meanwhile.',
    'hi': 'होंठ पढ़ना प्रशिक्षित मॉडल के साथ आएगा। तब तक वाक्य बोर्ड का उपयोग करें।',
    'mr': 'ओठ वाचन प्रशिक्षित मॉडेलसोबत येईल. तोपर्यंत वाक्य फलक वापरा.',
  },
  'speak_result': {'en': 'Detected phrase', 'hi': 'पहचाना गया वाक्य', 'mr': 'ओळखलेले वाक्य'},
  'speak_waiting': {'en': 'Waiting for you…', 'hi': 'आपका इंतज़ार है…', 'mr': 'तुमची वाट पाहत आहे…'},

  // ----------------------------------------------------------------- board
  'board_search': {'en': 'Search phrases', 'hi': 'वाक्य खोजें', 'mr': 'वाक्य शोधा'},
  'board_tip': {
    'en': 'Tap to speak. Red phrases are urgent.',
    'hi': 'बोलने के लिए दबाएँ। लाल वाक्य ज़रूरी हैं।',
    'mr': 'बोलण्यासाठी दाबा. लाल वाक्ये तातडीची आहेत.',
  },

  // ------------------------------------------------------------------ type
  'type_hint': {'en': 'Type your message…', 'hi': 'अपना संदेश लिखें…', 'mr': 'तुमचा संदेश लिहा…'},
  'type_speak': {'en': 'Speak', 'hi': 'बोलें', 'mr': 'बोला'},
  'type_clear': {'en': 'Clear', 'hi': 'मिटाएँ', 'mr': 'पुसा'},
  'type_quick': {'en': 'Quick words', 'hi': 'जल्दी के शब्द', 'mr': 'झटपट शब्द'},
  'voice_lang': {'en': 'Voice', 'hi': 'आवाज़', 'mr': 'आवाज'},

  // ----------------------------------------------------------- personalise
  'pers_body': {
    'en': 'Record each phrase a few times. The app learns how your lips move and becomes more accurate for you.',
    'hi': 'हर वाक्य कुछ बार रिकॉर्ड करें। ऐप आपके होंठों की हरकत सीखकर आपके लिए ज़्यादा सटीक हो जाएगा।',
    'mr': 'प्रत्येक वाक्य काही वेळा रेकॉर्ड करा. अ‍ॅप तुमच्या ओठांची हालचाल शिकून तुमच्यासाठी अधिक अचूक होईल.',
  },
  'pers_progress': {
    'en': '{n} of {t} phrases learned',
    'hi': '{t} में से {n} वाक्य सीखे गए',
    'mr': '{t} पैकी {n} वाक्ये शिकली',
  },
  'pers_step1': {'en': 'Good light on your face', 'hi': 'चेहरे पर अच्छी रोशनी', 'mr': 'चेहऱ्यावर चांगला प्रकाश'},
  'pers_step2': {'en': 'Phone at eye level', 'hi': 'फ़ोन आँखों के स्तर पर', 'mr': 'फोन डोळ्यांच्या पातळीवर'},
  'pers_step3': {
    'en': 'Mouth each phrase clearly, without sound',
    'hi': 'हर वाक्य साफ़-साफ़, बिना आवाज़ बोलें',
    'mr': 'प्रत्येक वाक्य स्पष्ट, आवाजाशिवाय बोला',
  },
  'pers_start': {'en': 'Start personalising', 'hi': 'शुरू करें', 'mr': 'सुरू करा'},

  // --------------------------------------------------------------- history
  'hist_empty': {
    'en': 'Nothing yet. What you speak appears here.',
    'hi': 'अभी कुछ नहीं। आप जो बोलेंगे वह यहाँ दिखेगा।',
    'mr': 'अजून काही नाही. तुम्ही जे बोलाल ते इथे दिसेल.',
  },
  'hist_clear': {'en': 'Clear history', 'hi': 'इतिहास मिटाएँ', 'mr': 'इतिहास पुसा'},
  'hist_today': {'en': 'Today', 'hi': 'आज', 'mr': 'आज'},
  'hist_earlier': {'en': 'Earlier', 'hi': 'पहले', 'mr': 'आधी'},

  // ------------------------------------------------------------- caregiver
  'care_name': {'en': 'Caregiver name', 'hi': 'देखभालकर्ता का नाम', 'mr': 'काळजीवाहकाचे नाव'},
  'care_phone': {'en': 'Phone number', 'hi': 'फ़ोन नंबर', 'mr': 'फोन नंबर'},
  'care_call': {'en': 'Call', 'hi': 'कॉल करें', 'mr': 'कॉल करा'},
  'care_none': {
    'en': 'Add a caregiver number first.',
    'hi': 'पहले देखभालकर्ता का नंबर जोड़ें।',
    'mr': 'आधी काळजीवाहकाचा नंबर जोडा.',
  },
  'sos': {'en': 'SOS', 'hi': 'SOS', 'mr': 'SOS'},
  'sos_hint': {
    'en': 'Press and hold. The phone calls out for help and dials your caregiver.',
    'hi': 'दबाकर रखें। फ़ोन ज़ोर से मदद माँगेगा और देखभालकर्ता को कॉल करेगा।',
    'mr': 'दाबून धरा. फोन मोठ्याने मदत मागेल आणि काळजीवाहकाला कॉल करेल.',
  },
  'sos_active': {'en': 'Calling for help…', 'hi': 'मदद बुलाई जा रही है…', 'mr': 'मदत बोलावत आहे…'},
  'sos_stop': {'en': 'Stop', 'hi': 'रोकें', 'mr': 'थांबवा'},
  'sos_spoken': {
    'en': 'Please help me. I need help now.',
    'hi': 'कृपया मेरी मदद करें। मुझे अभी मदद चाहिए।',
    'mr': 'कृपया मला मदत करा. मला आत्ता मदत हवी आहे.',
  },

  // -------------------------------------------------------------- settings
  'appearance': {'en': 'Appearance', 'hi': 'दिखावट', 'mr': 'स्वरूप'},
  'account': {'en': 'Account', 'hi': 'खाता', 'mr': 'खाते'},
  'about': {'en': 'About', 'hi': 'जानकारी', 'mr': 'माहिती'},
  'about_body': {
    'en': 'ANTARVANI is a smartphone camera-based silent speech interface that helps people who cannot speak aloud communicate again.',
    'hi': 'अंतर्वाणी स्मार्टफ़ोन कैमरा आधारित मूक वाणी इंटरफ़ेस है, जो बोल न पाने वाले लोगों को फिर से बात करने में मदद करता है।',
    'mr': 'अंतर्वाणी हा स्मार्टफोन कॅमेरा आधारित मूक वाणी इंटरफेस आहे, जो बोलू न शकणाऱ्या लोकांना पुन्हा संवाद साधण्यास मदत करतो.',
  },
  // ------------------------------------------------------ my recordings
  'mine_desc': {
    'en': 'See the clips you recorded for the study',
    'hi': 'अध्ययन के लिए आपने जो क्लिप दी हैं, वे देखें',
    'mr': 'अभ्यासासाठी तुम्ही दिलेल्या क्लिप पहा',
  },
  'mine_intro': {
    'en': 'If you took part in the recording study, enter both numbers from '
        'your consent form to see your own clips.',
    'hi': 'अगर आपने रिकॉर्डिंग अध्ययन में भाग लिया है, तो अपने सहमति पत्र पर लिखे '
        'दोनों नंबर डालें और अपनी क्लिप देखें।',
    'mr': 'तुम्ही रेकॉर्डिंग अभ्यासात भाग घेतला असेल, तर तुमच्या संमती पत्रावरील '
        'दोन्ही क्रमांक टाका आणि तुमच्या क्लिप पहा.',
  },
  'mine_speaker_id': {'en': 'Speaker ID', 'hi': 'स्पीकर आईडी', 'mr': 'स्पीकर आयडी'},
  'mine_form_no': {'en': 'Form number', 'hi': 'फ़ॉर्म नंबर', 'mr': 'फॉर्म क्रमांक'},
  'mine_code': {
    'en': 'Access code',
    'hi': 'एक्सेस कोड',
    'mr': 'अ‍ॅक्सेस कोड',
  },
  'mine_code_hint': {
    'en': 'The 4 letters and numbers written on your form.',
    'hi': 'आपके फ़ॉर्म पर लिखे 4 अक्षर/अंक।',
    'mr': 'तुमच्या फॉर्मवर लिहिलेली 4 अक्षरे/अंक.',
  },
  'mine_hint': {
    'en': 'All three are on the paper form you signed, written by the person '
        'who recorded you — S014, F014 and a short code like 7KH4.',
    'hi': 'तीनों चीज़ें उसी काग़ज़ पर हैं जिस पर आपने हस्ताक्षर किए थे — S014, '
        'F014 और 7KH4 जैसा छोटा कोड।',
    'mr': 'तिन्ही गोष्टी तुम्ही सही केलेल्या कागदावर आहेत — S014, F014 आणि '
        '7KH4 सारखा छोटा कोड.',
  },
  'mine_show': {
    'en': 'Show my recordings',
    'hi': 'मेरी रिकॉर्डिंग दिखाएँ',
    'mr': 'माझ्या रेकॉर्डिंग दाखवा',
  },
  'mine_checking': {'en': 'Checking…', 'hi': 'जाँच हो रही है…', 'mr': 'तपासत आहे…'},
  'mine_signin_first': {
    'en': 'Sign in first, so these recordings stay linked to your account.',
    'hi': 'पहले साइन इन करें, ताकि ये रिकॉर्डिंग आपके खाते से जुड़ी रहें।',
    'mr': 'आधी साइन इन करा, म्हणजे या रेकॉर्डिंग तुमच्या खात्याशी जोडल्या राहतील.',
  },
  'mine_details': {'en': 'What we stored', 'hi': 'हमने क्या रखा है', 'mr': 'आम्ही काय ठेवले आहे'},
  'mine_clips': {'en': 'Your clips', 'hi': 'आपकी क्लिप', 'mr': 'तुमच्या क्लिप'},
  'mine_none': {
    'en': 'No clips are stored for this number yet.',
    'hi': 'इस नंबर के लिए अभी कोई क्लिप नहीं है।',
    'mr': 'या क्रमांकासाठी अजून कोणतीही क्लिप नाही.',
  },
  'mine_kept': {'en': 'Kept', 'hi': 'रखी गई', 'mr': 'ठेवलेली'},
  'mine_removed': {'en': 'Removed', 'hi': 'हटाई गई', 'mr': 'काढलेली'},
  'mine_uploading': {'en': 'Still uploading', 'hi': 'अपलोड हो रही है', 'mr': 'अपलोड होत आहे'},
  'mine_take': {'en': 'take', 'hi': 'बार', 'mr': 'वेळा'},
  'mine_recorded_on': {'en': 'Recorded on', 'hi': 'रिकॉर्ड की तारीख़', 'mr': 'रेकॉर्डिंगची तारीख'},
  'mine_name': {'en': 'Name', 'hi': 'नाम', 'mr': 'नाव'},
  'mine_age': {'en': 'Age band', 'hi': 'आयु-वर्ग', 'mr': 'वयोगट'},
  'mine_gender': {'en': 'Gender', 'hi': 'लिंग', 'mr': 'लिंग'},
  'mine_language': {'en': 'First language', 'hi': 'मातृभाषा', 'mr': 'मातृभाषा'},
  'mine_lighting': {'en': 'Lighting', 'hi': 'रोशनी', 'mr': 'प्रकाश'},
  'mine_publish': {
    'en': 'Agreed to publication',
    'hi': 'प्रकाशन की अनुमति',
    'mr': 'प्रकाशनाची परवानगी',
  },
  'mine_no_audio': {
    'en': 'No audio was recorded, and your phone number and address were '
        'never stored.',
    'hi': 'कोई आवाज़ रिकॉर्ड नहीं हुई, और आपका फ़ोन नंबर या पता कभी सेव नहीं किया गया।',
    'mr': 'कोणताही आवाज रेकॉर्ड झाला नाही, आणि तुमचा फोन नंबर किंवा पत्ता कधीही '
        'साठवला गेला नाही.',
  },
  'mine_watch': {'en': 'Watch', 'hi': 'देखें', 'mr': 'पहा'},
  'mine_watch_denied': {
    'en': 'Could not open it. If Drive says you need access, ask the person '
        'who recorded you to share your clips.',
    'hi': 'नहीं खुल सका। अगर ड्राइव कहे कि अनुमति चाहिए, तो जिसने आपकी रिकॉर्डिंग '
        'की थी उनसे क्लिप शेयर करने को कहें।',
    'mr': 'उघडता आले नाही. ड्राइव्ह परवानगी मागत असेल, तर ज्यांनी तुमचे '
        'रेकॉर्डिंग केले त्यांना क्लिप शेअर करण्यास सांगा.',
  },
  'mine_delete': {
    'en': 'Ask for my clips to be deleted',
    'hi': 'मेरी क्लिप हटाने के लिए कहें',
    'mr': 'माझ्या क्लिप काढण्यास सांगा',
  },
  'mine_delete_body': {
    'en': 'The team will be told, and will remove every clip of yours from '
        'the study. This cannot be undone.',
    'hi': 'टीम को सूचना मिल जाएगी और आपकी सभी क्लिप अध्ययन से हटा दी जाएँगी। '
        'यह वापस नहीं लिया जा सकता।',
    'mr': 'टीमला कळवले जाईल आणि तुमच्या सर्व क्लिप अभ्यासातून काढल्या जातील. '
        'हे पूर्ववत करता येणार नाही.',
  },
  'mine_delete_sent': {
    'en': 'Asked. The team will remove your clips.',
    'hi': 'अनुरोध भेज दिया गया। टीम आपकी क्लिप हटा देगी।',
    'mr': 'विनंती पाठवली. टीम तुमच्या क्लिप काढेल.',
  },
  'mine_delete_pending': {
    'en': 'You have asked for these to be deleted.',
    'hi': 'आपने इन्हें हटाने के लिए कहा है।',
    'mr': 'तुम्ही या काढण्यास सांगितले आहे.',
  },
  'mine_add': {
    'en': 'Add another number',
    'hi': 'दूसरा नंबर जोड़ें',
    'mr': 'दुसरा क्रमांक जोडा',
  },
  'mine_remove': {
    'en': 'Remove from this phone',
    'hi': 'इस फ़ोन से हटाएँ',
    'mr': 'या फोनमधून काढा',
  },
  'mine_switch': {
    'en': 'Your sessions',
    'hi': 'आपके सत्र',
    'mr': 'तुमची सत्रे',
  },
  'mine_other': {
    'en': 'Use a different number',
    'hi': 'दूसरा नंबर इस्तेमाल करें',
    'mr': 'दुसरा क्रमांक वापरा',
  },

  // ------------------------------------------------------ forced update
  'update_title': {
    'en': 'Update required',
    'hi': 'अपडेट ज़रूरी है',
    'mr': 'अपडेट आवश्यक आहे',
  },
  'update_body': {
    'en': 'A newer version of ANTARVANI is out. Everyone on the project has '
        'to be on the same version, so this one stays locked until you '
        'install it.',
    'hi': 'अंतर्वाणी का नया संस्करण आ गया है। प्रोजेक्ट के सभी लोगों को एक ही '
        'संस्करण पर होना ज़रूरी है, इसलिए इंस्टॉल करने तक यह ऐप बंद रहेगा।',
    'mr': 'अंतर्वाणीची नवीन आवृत्ती आली आहे. प्रकल्पातील सर्वांनी एकाच '
        'आवृत्तीवर असणे आवश्यक आहे, त्यामुळे इन्स्टॉल करेपर्यंत हे अ‍ॅप बंद राहील.',
  },
  'update_download': {
    'en': 'Download the update',
    'hi': 'अपडेट डाउनलोड करें',
    'mr': 'अपडेट डाउनलोड करा',
  },
  'update_after': {
    'en': 'When the download finishes, tap the file to install, then open '
        'ANTARVANI again.',
    'hi': 'डाउनलोड पूरा होने पर फ़ाइल पर टैप करके इंस्टॉल करें, फिर अंतर्वाणी '
        'दोबारा खोलें।',
    'mr': 'डाउनलोड पूर्ण झाल्यावर फाइलवर टॅप करून इन्स्टॉल करा, मग अंतर्वाणी '
        'पुन्हा उघडा.',
  },
  'update_installed': {
    'en': 'On this phone',
    'hi': 'इस फ़ोन पर',
    'mr': 'या फोनवर',
  },
  'update_needed': {'en': 'Needed', 'hi': 'ज़रूरी', 'mr': 'आवश्यक'},
  'update_whats_new': {'en': "What's new", 'hi': 'क्या नया है', 'mr': 'काय नवीन आहे'},
  'update_no_link': {
    'en': 'No download link was published. Ask the project admin for the '
        'new APK.',
    'hi': 'कोई डाउनलोड लिंक नहीं दिया गया। नई APK के लिए प्रोजेक्ट एडमिन से कहें।',
    'mr': 'कोणतीही डाउनलोड लिंक दिलेली नाही. नवीन APK साठी प्रकल्प प्रशासकाला '
        'विचारा.',
  },
  'update_recheck': {'en': 'Check again', 'hi': 'दोबारा जाँचें', 'mr': 'पुन्हा तपासा'},
  'update_undo': {
    'en': 'I published this by mistake — undo',
    'hi': 'यह ग़लती से प्रकाशित हुआ — वापस लें',
    'mr': 'हे चुकून प्रकाशित झाले — मागे घ्या',
  },

  'collect_locked': {
    'en': 'Ask the master admin to add you to the team.',
    'hi': 'टीम में जुड़ने के लिए मास्टर एडमिन से कहें।',
    'mr': 'टीममध्ये सामील होण्यासाठी मास्टर प्रशासकाला सांगा.',
  },
};
