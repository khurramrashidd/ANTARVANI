/* Firebase keys for the web dashboard.
 *
 * DO NOT EDIT. `setup` writes this file from lib/firebase_options.dart, so
 * the website and the Android app always point at the same project. If the
 * values below still say REPLACE, run `setup` in the project folder and
 * deploy again.
 *
 * These keys are not secret — every Firebase web app ships them in plain
 * sight. What protects the data is firestore.rules, which lets only a
 * signed-in team member read the corpus.
 */
window.FIREBASE_CONFIG = {
  apiKey: 'REPLACE_ME',
  authDomain: 'antarvaani-the-voice.firebaseapp.com',
  projectId: 'antarvaani-the-voice',
  storageBucket: 'antarvaani-the-voice.firebasestorage.app',
  messagingSenderId: 'REPLACE_ME',
  appId: 'REPLACE_ME',
};
