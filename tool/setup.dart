// ANTARVANI — one-command setup and health check.
//
//   dart tool\setup.dart            (or just:  setup)
//
// Safe to run as many times as you like. Every step checks first: if it is
// already right it says OK and moves on; if it is wrong it fixes it; if it
// needs a click in a web console it opens the page and waits for you.
// Everything it prints is also saved to setup_report.txt — send that file
// back if anything stays red.
//
// Uses only dart:io, so it runs before `flutter pub get`.

import 'dart:convert';
import 'dart:io';

const projectId = 'antarvaani-the-voice';
const ownerEmail = 'khurramrashid6893@gmail.com';
const masterEmail = 'khurramrashid0786@gmail.com';
const appLabel = 'ANTARVANI';
const minSdk = 24;
const dbLocation = 'asia-south1';
const corpusFolderId = '1Hw76NlkEjJdCsD40TY-YhA4qBIlGVqex';

final bool isWin = Platform.isWindows;
final StringBuffer report = StringBuffer();
final List<String> todos = [];
final List<String> fixes = [];
int errors = 0;
Map<String, dynamic> state = {};
final File stateFile = File('.antarvani_setup.json');

// ------------------------------------------------------------------ output
void log(String s) {
  stdout.writeln(s);
  report.writeln(s);
}

void head(String s) {
  final n = s.length > 57 ? 3 : 60 - s.length;
  log('\n=== $s ${'=' * n}');
}
void ok(String s) => log('  [OK]    $s');
void fixed(String s) {
  log('  [FIXED] $s');
  fixes.add(s);
}

void todo(String s) {
  log('  [TODO]  $s');
  todos.add(s);
}

void bad(String s) {
  log('  [ERROR] $s');
  errors++;
}

void info(String s) => log('          $s');

// --------------------------------------------------------------- processes
const _enc = Utf8Codec(allowMalformed: true);

Future<ProcessResult> run(String exe, List<String> args,
    {String? cwd, bool shell = true}) async {
  try {
    return await Process.run(exe, args,
        runInShell: shell,
        workingDirectory: cwd,
        stdoutEncoding: _enc,
        stderrEncoding: _enc);
  } catch (e) {
    return ProcessResult(0, 127, '', '$e');
  }
}

/// Runs with the console attached, so you see progress and can answer prompts.
Future<int> live(String exe, List<String> args, {String? cwd}) async {
  log('  > $exe ${args.join(' ')}');
  try {
    final p = await Process.start(exe, args,
        runInShell: true,
        workingDirectory: cwd,
        mode: ProcessStartMode.inheritStdio);
    return await p.exitCode;
  } catch (e) {
    log('    could not start: $e');
    return 127;
  }
}

String out(ProcessResult r) => '${r.stdout}\n${r.stderr}';

Future<bool> onPath(String exe) async {
  final r = await run(isWin ? 'where' : 'which', [exe]);
  return r.exitCode == 0;
}

String ask(String q) {
  stdout.write('\n  >>> $q ');
  return (stdin.readLineSync() ?? '').trim();
}

bool yes(String q) => ask('$q [y/n]').toLowerCase().startsWith('y');

Future<void> openUrl(String url) async {
  info('Opening: $url');
  if (isWin) {
    // No cmd.exe in between, so '&' in the URL cannot split the command.
    await run('rundll32', ['url.dll,FileProtocolHandler', url], shell: false);
  } else {
    await run('xdg-open', [url]);
  }
}

String norm(String sha) => sha.replaceAll(':', '').toLowerCase().trim();

// ------------------------------------------------------------------- state
void loadState() {
  try {
    if (stateFile.existsSync()) {
      state = jsonDecode(stateFile.readAsStringSync()) as Map<String, dynamic>;
    }
  } catch (_) {
    state = {};
  }
}

void saveState() {
  try {
    stateFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(state));
  } catch (_) {}
}

// ========================================================================
Future<void> main(List<String> argv) async {
  final skipBuild = argv.contains('--no-build');
  log('ANTARVANI setup  ${DateTime.now()}');
  log('Folder: ${Directory.current.path}');
  loadState();

  if (!checkFolder()) {
    finish();
    return;
  }
  final fireOk = await checkTools();
  cleanStrays();
  writeFirebaseFiles();

  if (fireOk) {
    if (await checkFirebaseAccount()) {
      final dbPresent = await checkDatabase();
      await deployRules(dbPresent);
      final appId = await checkAndroidApp();
      if (appId != null) {
        await checkSha(appId);
        await checkGoogleSignIn(appId);
      }
      await consoleSteps();
    }
  }

  fixAndroidFiles();

  if (!skipBuild) await buildChecks();

  finish();
}

// ------------------------------------------------------------- 1. folder
bool checkFolder() {
  head('1. Project folder');
  final pub = File('pubspec.yaml');
  if (!pub.existsSync() ||
      !pub.readAsStringSync().contains('name: silent_voice_recorder')) {
    bad('Run this from inside the silent_voice_recorder folder.');
    info('cd F:\\2026\\My_projects\\College_project\\Silent_voice\\silent_voice_recorder');
    return false;
  }
  if (!Directory('android').existsSync()) {
    bad('No android folder. Run once:  flutter create --org com.silentvoice --project-name silent_voice_recorder .');
    return false;
  }
  ok('pubspec.yaml and android/ found');
  return true;
}

// -------------------------------------------------------------- 2. tools
List<String> flutterfireCmd = ['flutterfire'];

Future<bool> checkTools() async {
  head('2. Tools');
  if (await onPath('flutter')) {
    ok('flutter');
  } else {
    bad('flutter not on PATH');
  }

  final fire = await onPath('firebase');
  if (fire) {
    final v = await run('firebase', ['--version']);
    ok('firebase CLI ${v.stdout.toString().trim()}');
  } else {
    bad('firebase CLI missing. Install:  npm install -g firebase-tools');
  }

  if (await onPath('flutterfire')) {
    ok('flutterfire');
  } else {
    info('flutterfire not on PATH, installing...');
    await run('dart', ['pub', 'global', 'activate', 'flutterfire_cli']);
    flutterfireCmd = ['dart', 'pub', 'global', 'run', 'flutterfire_cli:flutterfire'];
    fixed('flutterfire_cli activated (used via dart pub global run)');
  }
  return fire;
}

// ------------------------------------------------------- 3. stray files
void cleanStrays() {
  head('3. Old files');
  // Files from earlier zips that no longer exist; unzipping does not remove
  // them, and they would break the build.
  const stale = {
    'lib/record_screen.dart': 'old copy; the real one is lib/screens/',
    'lib/screens/team_screen.dart': 'replaced by lib/screens/users_screen.dart',
  };
  var any = false;
  stale.forEach((path, why) {
    final f = File(path);
    if (f.existsSync()) {
      f.deleteSync();
      fixed('deleted $path ($why)');
      any = true;
    }
  });
  if (!any) ok('no old files left over');

  _checkNestedCopy();
}

/// A second copy of the project inside itself.
///
/// It happens when the zip is extracted INTO the project folder instead of
/// the folder above it. Everything looks right — the real files are all
/// there and setup's own checks pass — but `flutter analyze` reads every
/// Dart file under the project, including the inner copy, and the inner copy
/// has no firebase_options.dart (that file is never in the zip). The result
/// is two baffling errors about a file that plainly exists.
void _checkNestedCopy() {
  final nested = <Directory>[];
  try {
    for (final e in Directory('.').listSync()) {
      if (e is! Directory) continue;
      final name = e.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.') ||
          const {'lib', 'test', 'tool', 'docs', 'assets', 'android', 'ios',
                 'web', 'macos', 'linux', 'windows', 'build'}.contains(name)) {
        continue;
      }
      if (File('${e.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
        nested.add(e);
      }
    }
  } catch (_) {
    return;
  }
  if (nested.isEmpty) return;

  for (final d in nested) {
    info('There is a whole second copy of the project inside this one:');
    info('    ${d.absolute.path}');
    info('That comes from extracting the zip INTO the project folder instead');
    info('of the folder above it. flutter analyze reads both copies, and the');
    info('inner one has no firebase_options.dart — which is the error you');
    info('are seeing.');
    if (yes('Delete that inner copy?')) {
      try {
        d.deleteSync(recursive: true);
        fixed('deleted the duplicate project at ${d.path}');
      } catch (e) {
        bad('Could not delete ${d.path}: $e');
      }
    } else {
      todo('Delete the folder ${d.path} inside the project, then run setup '
          'again.');
    }
  }
}

// ------------------------------------------------- 4. firebase.json etc.
const rules = r'''rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    function signedIn()  { return request.auth != null; }
    function email()     { return request.auth.token.email; }

    // The one account that can never be locked out.
    function isMaster()  { return signedIn() &&
                           email() == 'khurramrashid0786@gmail.com'; }

    function userDoc()   { return /databases/$(database)/documents/users/$(email()); }
    function role()      { return get(userDoc()).data.role; }
    function hasProfile(){ return signedIn() && exists(userDoc()); }

    function isAdmin()   { return isMaster() || (hasProfile() && role() == 'admin'); }
    function isMember()  { return isAdmin() || (hasProfile() && role() == 'member'); }

    // Everyone who signs in. New people may only create themselves as a
    // patient; they may refresh their own name/photo but never their role.
    // Admins set patient/member; only the master grants or removes admin.
    match /users/{userEmail} {
      allow read: if signedIn() && (email() == userEmail || isAdmin());
      allow create: if signedIn() && email() == userEmail &&
        (request.resource.data.role == 'patient' ||
         (isMaster() && request.resource.data.role == 'admin'));
      allow update: if signedIn() && (
        (email() == userEmail &&
           request.resource.data.role == resource.data.role) ||
        (isAdmin() && userEmail != 'khurramrashid0786@gmail.com' &&
           (isMaster() || (resource.data.role != 'admin' &&
                           request.resource.data.role != 'admin')))
      );
      allow delete: if isMaster() && userEmail != 'khurramrashid0786@gmail.com';
    }

    // Which APK everyone must be on. Read by anyone signed in, because the
    // update screen blocks patients too; written only by the master.
    match /config/{id} {
      allow read:  if signedIn();
      allow write: if isMaster();
    }

    // Shared speaker counter: S001, S002 ... for every collector.
    match /counters/{id} {
      allow read, write: if isMember();
    }

    // A volunteer linking their own account to the session they took part in.
    // They never read the row first — they write the form number they typed
    // as claimProof, and this rule accepts the write only if it matches the
    // one already stored. A wrong guess is refused by the server, so nobody
    // can walk through S001, S002, S003 looking at names.
    function hasCode() {
      return 'accessCode' in resource.data && resource.data.accessCode != '';
    }
    function unclaimed() {
      return !('claimedBy' in resource.data)
        || resource.data.claimedBy == null
        || resource.data.claimedBy == ''
        || resource.data.claimedBy == email();
    }
    function claimsOwnRow() {
      return signedIn()
        && request.resource.data.diff(resource.data).affectedKeys()
             .hasOnly(['claimedBy', 'claimedAt', 'claimProof', 'codeProof'])
        && request.resource.data.claimedBy == email()
        && request.resource.data.claimProof == resource.data.consentFormId
        && (
          // The access code is written on the paper form and nowhere else,
          // so holding it is the proof. Whoever has it may take the link
          // over — that is how a session a collector opened while testing
          // reaches the volunteer it actually belongs to.
          (hasCode()
            && request.resource.data.codeProof == resource.data.accessCode)
          ||
          // No code on this session: the form number is derivable from the
          // speaker number, so it proves nothing on its own. The first
          // account to link keeps it until a collector unlinks it.
          (!hasCode() && unclaimed())
        );
    }
    function isClaimant() {
      return signedIn() && 'claimedBy' in resource.data
        && resource.data.claimedBy == email();
    }
    function claimedSpeaker(sid) {
      return signedIn()
        && exists(/databases/$(database)/documents/speakers/$(sid))
        && get(/databases/$(database)/documents/speakers/$(sid))
             .data.claimedBy == email();
    }

    // Collected data. Collectors record; only admins delete.
    match /clips/{id} {
      // A volunteer may read their own clips once their account is linked.
      allow read:           if isMember() || claimedSpeaker(resource.data.speakerId);
      allow create, update: if isMember();
      // Only an admin wipes a clip record, and only as part of deleting a
      // whole recording — everyday rejects set status instead.
      allow delete:         if isAdmin();
    }
    match /speakers/{id} {
      allow read:          if isMember() || isClaimant();
      allow create:        if isMember();
      allow update:        if isMember();
      // The volunteer's own two writes: linking their account, and asking for
      // their clips to be deleted. Nothing else on the row may change.
      allow update: if claimsOwnRow();
      allow update: if isClaimant()
        && request.resource.data.diff(resource.data).affectedKeys()
             .hasOnly(['deletionRequested', 'deletionRequestedAt']);
      // A collector may delete a speaker row they created and that produced
      // nothing, so the number returns to the pool. Admins may delete any.
      allow delete: if isAdmin() ||
        (isMember() && resource.data.collectorEmail == email());
    }
    match /devices/{id} {
      allow read, write: if isMember();
    }

    // A record that a whole recording was wiped: number, form number, how
    // many clips, who and why. Never a name — the usual reason for wiping one
    // is that the person asked to be forgotten.
    match /deletions/{id} {
      allow read:   if isMember();
      // Any collector may delete a recording they made, so any of them may
      // write the record of it.
      allow create: if isMember();
      // Drive only lets the uploader destroy their own files. When they
      // finally do, they tick the leftovers off this record — and nothing
      // else on it may change.
      allow update: if isMember()
        && request.resource.data.diff(resource.data).affectedKeys()
             .hasOnly(['pendingOwners', 'pendingFileIds', 'clearedAt']);
      allow delete: if false;
    }

    // Team chat.
    match /messages/{id} {
      allow read, create: if isMember();
      allow delete:       if isAdmin();
    }

    // A patient's own data (history, personalisation) — theirs alone.
    match /patients/{ownerEmail}/{rest=**} {
      allow read, write: if signedIn() && email() == ownerEmail;
    }

    // Anything not named above is denied.
    match /{document=**} {
      allow read, write: if false;
    }
  }
}
''';

void writeFirebaseFiles() {
  head('4. Firebase config files');

  // .firebaserc — which project this folder deploys to.
  final rc = File('.firebaserc');
  Map<String, dynamic> rcMap = {};
  try {
    if (rc.existsSync()) rcMap = jsonDecode(rc.readAsStringSync());
  } catch (_) {}
  final projects = Map<String, dynamic>.from((rcMap['projects'] as Map?) ?? {});
  if (projects['default'] == projectId) {
    ok('.firebaserc -> $projectId');
  } else {
    projects['default'] = projectId;
    rcMap['projects'] = projects;
    rc.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(rcMap));
    fixed('.firebaserc now points to $projectId');
  }

  // firebase.json — keep whatever flutterfire wrote, add the firestore block.
  final fj = File('firebase.json');
  Map<String, dynamic> fjMap = {};
  try {
    if (fj.existsSync()) fjMap = jsonDecode(fj.readAsStringSync());
  } catch (_) {
    info('firebase.json was not valid JSON; rebuilding it');
  }
  final fs = fjMap['firestore'];
  if (fs is Map &&
      fs['rules'] == 'firestore.rules' &&
      fs['indexes'] == 'firestore.indexes.json') {
    ok('firebase.json has the firestore section');
  } else {
    fjMap['firestore'] = {
      'rules': 'firestore.rules',
      'indexes': 'firestore.indexes.json',
    };
    fj.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(fjMap));
    fixed('firebase.json: added firestore section (this caused "No targets match")');
  }

  final rf = File('firestore.rules');
  if (rf.existsSync() &&
      rf.readAsStringSync().replaceAll('\r\n', '\n').trim() == rules.trim()) {
    ok('firestore.rules is the ANTARVANI version');
  } else {
    rf.writeAsStringSync(rules);
    fixed('firestore.rules written (master = $masterEmail)');
  }

  final ix = File('firestore.indexes.json');
  var ixOk = false;
  try {
    ixOk = ix.existsSync() && jsonDecode(ix.readAsStringSync()) is Map;
  } catch (_) {}
  if (ixOk) {
    ok('firestore.indexes.json');
  } else {
    ix.writeAsStringSync('{\n  "indexes": [],\n  "fieldOverrides": []\n}\n');
    fixed('firestore.indexes.json created (app needs no composite indexes)');
  }
}

// ------------------------------------------------ 5. account and project
Future<bool> projectVisible() async {
  final r = await run('firebase', ['projects:list', '--json']);
  return out(r).contains('"$projectId"');
}

Future<bool> checkFirebaseAccount() async {
  head('5. Firebase login');
  if (await projectVisible()) {
    ok('logged-in account can see $projectId');
    return true;
  }
  info('$projectId is not visible to the current login. Switching to $ownerEmail...');
  final r = await run('firebase', ['login:use', ownerEmail]);
  if (r.exitCode != 0) {
    info('$ownerEmail is not logged in yet. A browser will open: sign in as $ownerEmail.');
    await live('firebase', ['login:add']);
    await run('firebase', ['login:use', ownerEmail]);
  }
  if (await projectVisible()) {
    fixed('Firebase CLI now uses $ownerEmail');
    return true;
  }
  bad('Still cannot see $projectId. Run:  firebase login:list   and make sure $ownerEmail is there.');
  return false;
}

// ---------------------------------------------------------- 6. database
/// true = confirmed present, false = definitely missing, null = could not tell.
Future<bool?> checkDatabase() async {
  head('6. Firestore database');
  final r = await run('firebase',
      ['firestore:databases:list', '--project', projectId, '--json']);
  final text = out(r);

  if (text.contains('(default)')) {
    final loc =
        RegExp(r'"locationId"\s*:\s*"([^"]+)"').firstMatch(text)?.group(1);
    ok('database (default) exists${loc == null ? '' : ' in $loc'}');
    if (loc != null && loc != dbLocation) {
      info('Location is $loc, not $dbLocation. That is fine; it cannot be '
          'changed, so do not recreate it.');
    }
    return true;
  }

  // Only trust "missing" when the CLI actually answered.
  if (r.exitCode == 0) {
    todo('No database yet. Run this exact line, then run setup again:\n'
        '            firebase firestore:databases:create "(default)" '
        '--location=$dbLocation --project=$projectId');
    return false;
  }

  // The listing failed — an old CLI, a permissions hiccup, the API still
  // warming up. That says nothing about whether a database exists, and the
  // deploy below is a far better test, so do not raise a false alarm.
  final why = text.trim().split('\n').firstWhere((l) => l.trim().isNotEmpty,
      orElse: () => 'no output');
  info('Could not list databases ($why).');
  info('The rules deploy below will show whether one exists.');
  return null;
}

// ------------------------------------------------------- 7. deploy rules
Future<void> deployRules(bool? dbPresent) async {
  head('7. Deploy security rules');
  if (dbPresent == false) {
    todo('Skipped: create the database first (step 6), then run setup again.');
    return;
  }
  final code = await live('firebase',
      ['deploy', '--only', 'firestore', '--project', projectId, '--non-interactive']);
  if (code == 0) {
    ok('rules and indexes deployed');
    if (dbPresent == null) {
      ok('database exists after all — the deploy just wrote to it');
    }
  } else {
    bad('deploy failed (see the lines above). If it says the database does '
        'not exist, create it with:\n'
        '            firebase firestore:databases:create "(default)" '
        '--location=$dbLocation --project=$projectId');
  }
}

// -------------------------------------------------- 8. Android app + json
String applicationId() {
  for (final p in ['android/app/build.gradle.kts', 'android/app/build.gradle']) {
    final f = File(p);
    if (!f.existsSync()) continue;
    final m = RegExp(r'''applicationId\s*=?\s*["']([^"']+)["']''')
        .firstMatch(f.readAsStringSync());
    if (m != null) return m.group(1)!;
  }
  return 'com.silentvoice.silent_voice_recorder';
}

File get gsFile => File('android/app/google-services.json');

Map<String, dynamic>? gsClient(String pkg) {
  try {
    final j = jsonDecode(gsFile.readAsStringSync()) as Map<String, dynamic>;
    if (j['project_info']?['project_id'] != projectId) return null;
    for (final c in (j['client'] as List)) {
      if (c['client_info']?['android_client_info']?['package_name'] == pkg) {
        return (c as Map).cast<String, dynamic>();
      }
    }
  } catch (_) {}
  return null;
}

Future<String?> checkAndroidApp() async {
  head('8. Android app registration');
  final pkg = applicationId();
  info('applicationId: $pkg');

  final opts = File('lib/firebase_options.dart');
  final optsOk = opts.existsSync() && opts.readAsStringSync().contains(projectId);
  var client = gsFile.existsSync() ? gsClient(pkg) : null;

  if (optsOk && client != null) {
    ok('lib/firebase_options.dart and google-services.json match $projectId');
  } else {
    info('Config missing or for another project. Running flutterfire configure...');
    final code = await live(flutterfireCmd.first, [
      ...flutterfireCmd.skip(1),
      'configure',
      '--project=$projectId',
      '--platforms=android',
      '--yes',
    ]);
    client = gsFile.existsSync() ? gsClient(pkg) : null;
    if (code == 0 && client != null) {
      fixed('flutterfire configure registered the Android app');
    } else {
      bad('flutterfire configure did not finish. Run it yourself:\n'
          '            flutterfire configure --project=$projectId --platforms=android');
      return null;
    }
  }

  // The google-services Gradle plugin must be applied or the json is ignored.
  final gradleText = [
    'android/settings.gradle.kts', 'android/settings.gradle',
    'android/app/build.gradle.kts', 'android/app/build.gradle',
    'android/build.gradle.kts', 'android/build.gradle',
  ].where((p) => File(p).existsSync()).map((p) => File(p).readAsStringSync()).join('\n');
  if (gradleText.contains('com.google.gms.google-services')) {
    ok('google-services Gradle plugin applied');
  } else {
    bad('google-services Gradle plugin missing. Run:  flutterfire configure --project=$projectId --platforms=android');
  }

  return client['client_info']['mobilesdk_app_id'] as String;
}

// --------------------------------------------------------------- 9. SHA-1
Future<String?> debugSha1() async {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';
  final ks = File('$home${Platform.pathSeparator}.android${Platform.pathSeparator}debug.keystore');
  final shaRe = RegExp(r'SHA1:\s*([0-9A-Fa-f:]{59})');

  if (ks.existsSync()) {
    final javaHome = Platform.environment['JAVA_HOME'];
    final candidates = <String>[
      if (javaHome != null) '$javaHome\\bin\\keytool.exe',
      if (javaHome != null) '$javaHome/bin/keytool',
      r'C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe',
      r'C:\Program Files\Android\Android Studio\jre\bin\keytool.exe',
      'keytool',
    ];
    for (final kt in candidates) {
      if (kt != 'keytool' && !File(kt).existsSync()) continue;
      final r = await run(kt, shell: kt == 'keytool', [
        '-list', '-v', '-keystore', ks.path,
        '-alias', 'androiddebugkey', '-storepass', 'android', '-keypass', 'android',
      ]);
      final m = shaRe.firstMatch(out(r));
      if (m != null) return m.group(1)!.toUpperCase();
    }
  }

  info('keytool not found; asking Gradle instead (first time can take a few minutes)...');
  final r = await run(isWin ? 'gradlew.bat' : './gradlew', ['signingReport'], cwd: 'android');
  final text = out(r);
  final at = text.indexOf('Variant: debug');
  final m = shaRe.firstMatch(at >= 0 ? text.substring(at) : text);
  return m?.group(1)?.toUpperCase();
}

Future<void> redownloadJson(String appId) async {
  final bak = File('${gsFile.path}.bak');
  if (gsFile.existsSync()) gsFile.copySync(bak.path);
  if (gsFile.existsSync()) gsFile.deleteSync();
  final r = await run('firebase', [
    'apps:sdkconfig', 'ANDROID', appId, '--project', projectId, '--out', gsFile.path,
  ]);
  if (r.exitCode == 0 && gsFile.existsSync()) {
    fixed('google-services.json downloaded fresh');
  } else {
    if (bak.existsSync()) bak.copySync(gsFile.path);
    bad('could not re-download google-services.json:\n${out(r).trim()}');
  }
}

Future<void> checkSha(String appId) async {
  head('9. SHA-1 fingerprint (Google sign-in fails silently without it)');
  final sha = await debugSha1();
  if (sha == null) {
    todo('Could not read the debug SHA-1. Run  flutter run  once on a phone, then run setup again.');
    return;
  }
  info('this laptop\'s debug SHA-1: $sha');
  info('(release APKs built on this laptop use the same key by default)');

  final list = await run('firebase',
      ['apps:android:sha:list', appId, '--project', projectId]);
  if (out(list).toLowerCase().replaceAll(':', '').contains(norm(sha))) {
    ok('SHA-1 already registered');
  } else {
    final add = await run('firebase',
        ['apps:android:sha:create', appId, sha, '--project', projectId]);
    if (add.exitCode == 0) {
      fixed('SHA-1 registered in Firebase');
    } else {
      bad('could not add SHA-1:\n${out(add).trim()}');
      return;
    }
  }

  final hashes = ((gsClient(applicationId())?['oauth_client'] as List?) ?? [])
      .map((o) => norm('${o['android_info']?['certificate_hash'] ?? ''}'));
  if (hashes.contains(norm(sha))) {
    ok('google-services.json already contains this SHA-1');
  } else {
    await redownloadJson(appId);
  }
}

// --------------------------------------------- 10. Google sign-in enabled
bool hasWebClient() {
  final c = gsClient(applicationId());
  final oauth = (c?['oauth_client'] as List?) ?? [];
  return oauth.any((o) => o['client_type'] == 3);
}

Future<void> checkGoogleSignIn(String appId) async {
  head('10. Google sign-in provider');
  if (hasWebClient()) {
    ok('Google sign-in is enabled (web client present in google-services.json)');
    return;
  }
  info('The Firebase CLI cannot switch this on. Opening the page for you.');
  info('Click Google -> Enable -> support email $masterEmail -> Save.');
  await openUrl('https://console.firebase.google.com/project/$projectId/authentication/providers?authuser=$ownerEmail');
  ask('Press Enter after you click Save...');
  await redownloadJson(appId);
  if (hasWebClient()) {
    fixed('Google sign-in enabled and config updated');
  } else {
    todo('Google sign-in still not showing in google-services.json. Wait 1 minute and run setup again.');
  }
}

// ------------------------------------------- 11. one-time console clicks
Future<void> consoleSteps() async {
  head('11. One-time console steps');
  if (state['driveApi'] == true) {
    ok('Drive API enabled (you confirmed earlier)');
  } else {
    info('Clip upload needs the Google Drive API. Opening it: press ENABLE.');
    await openUrl('https://console.developers.google.com/apis/api/drive.googleapis.com/overview?project=$projectId&authuser=$ownerEmail');
    if (yes('Did you press Enable (or does it already say "API enabled")?')) {
      state['driveApi'] = true;
      fixed('Drive API enabled');
    } else {
      todo('Enable the Drive API, then run setup again.');
    }
  }

  // ---- the team's Google accounts (asked once, remembered)
  var team = ((state['team'] as List?) ?? []).cast<String>();
  if (team.isEmpty) {
    info('Type the Gmail addresses of Kinza, Prapti and Shreya, separated by spaces.');
    info('(These are the accounts they will sign in with on their phones.)');
    team = ask('Emails (Enter to skip for now):')
        .split(RegExp(r'[\s,;]+'))
        .where((e) => e.contains('@'))
        .toList();
    if (team.isNotEmpty) state['team'] = team;
  }
  final everyone = [masterEmail, ...team];
  if (team.isEmpty) {
    todo('Team emails not entered yet. Run setup again when you have them.');
  } else {
    ok('team: ${everyone.join(', ')}');
  }

  // ---- Drive: the corpus folder lives in 0786's Drive
  if (state['driveShared'] == true) {
    ok('corpus folder shared with the team (you confirmed earlier)');
  } else if (team.isNotEmpty) {
    info('Clips upload into the corpus folder in $masterEmail\'s Drive.');
    info('In the page that opens, signed in as $masterEmail: Share -> add these as EDITOR:');
    for (final e in team) {
      info('    $e');
    }
    await openUrl('https://drive.google.com/drive/folders/$corpusFolderId?authuser=$masterEmail');
    if (yes('Shared with all of them as Editor?')) {
      state['driveShared'] = true;
      fixed('corpus folder shared with the team');
    } else {
      todo('Share the corpus folder (Editor) with: ${team.join(', ')}');
    }
  }

  // ---- OAuth audience: full Drive access is a restricted scope
  if (state['oauthUsers'] == true) {
    ok('OAuth test users set (you confirmed earlier)');
  } else if (team.isNotEmpty) {
    info('The app asks for Drive access, so Google treats it as an unverified app.');
    info('In the page that opens (signed in as $ownerEmail):');
    info('  if "Publishing status" says Testing -> Test users -> + Add users -> add:');
    for (final e in everyone) {
      info('    $e');
    }
    info('  if it says In production -> nothing to do; on the phone tap');
    info('  "Advanced -> Go to ANTARVANI" on the warning screen the first time.');
    await openUrl('https://console.cloud.google.com/auth/audience?project=$projectId&authuser=$ownerEmail');
    if (yes('Done?')) {
      state['oauthUsers'] = true;
      fixed('OAuth audience set');
    } else {
      todo('Add the 4 emails as OAuth test users (only if status is Testing).');
    }
  }

  // ---- optional: console access for 0786
  if (state['iam0786'] == true) {
    ok('$masterEmail can open the Firebase console (you confirmed earlier)');
  } else if (state['iamAsked'] != true) {
    info('Optional: let $masterEmail open the Firebase console too.');
    info('Add member -> $masterEmail -> Owner -> Add member. Not needed for Drive.');
    await openUrl('https://console.firebase.google.com/project/$projectId/settings/iam?authuser=$ownerEmail');
    state['iamAsked'] = true;
    if (yes('Done?')) {
      state['iam0786'] = true;
      fixed('$masterEmail added as Owner');
    } else {
      info('Skipped. Setup will not ask again.');
    }
  }
  saveState();

  ok('Master admin: $masterEmail (admin by rule, cannot be locked out).');
  info('Team members: they sign in once, then in the app as $masterEmail:');
  info('sidebar -> Admin -> Users & roles -> set them to Collector.');
  for (final e in team) {
    info('    $e');
  }
}

// --------------------------------------------------- 12. Android files
void fixAndroidFiles() {
  head('12. Android manifest and Gradle');

  final mf = File('android/app/src/main/AndroidManifest.xml');
  if (!mf.existsSync()) {
    bad('AndroidManifest.xml not found');
  } else {
    var s = mf.readAsStringSync();
    final before = s;
    s = s.replaceFirstMapped(RegExp(r'android:label="[^"]*"'), (_) => 'android:label="$appLabel"');
    const perms = [
      '<uses-permission android:name="android.permission.CAMERA" />',
      '<uses-permission android:name="android.permission.INTERNET" />',
      '<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />',
      '<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />',
      '<uses-feature android:name="android.hardware.camera" android:required="true" />',
    ];
    for (final p in perms) {
      final name = RegExp(r'android:name="([^"]+)"').firstMatch(p)!.group(1)!;
      if (!s.contains('"$name"')) {
        s = s.replaceFirst('<application', '$p\n    <application');
      }
    }
    // Android 11+: the app must declare that it talks to a text-to-speech
    // engine and the dialler, or both silently do nothing.
    if (!s.contains('android.intent.action.TTS_SERVICE')) {
      s = s.replaceFirst('<application', '''<queries>
        <intent>
            <action android:name="android.intent.action.TTS_SERVICE" />
        </intent>
        <intent>
            <action android:name="android.intent.action.DIAL" />
        </intent>
    </queries>
    <application''');
    }
    if (s != before) {
      mf.writeAsStringSync(s);
      fixed('AndroidManifest: label, camera/internet/location permissions, TTS + dialler queries');
    } else {
      ok('AndroidManifest already correct');
    }
  }

  final gradle = ['android/app/build.gradle.kts', 'android/app/build.gradle']
      .map(File.new)
      .where((f) => f.existsSync())
      .toList();
  if (gradle.isEmpty) {
    bad('android/app/build.gradle(.kts) not found');
    return;
  }
  final g = gradle.first;
  var s = g.readAsStringSync();
  final before = s;

  // ---- minSdk: Firebase and ML Kit need 24.
  final reMin = RegExp(r'(minSdk(?:Version)?)(\s*=\s*|\s+)([^\s\r\n]+)');
  final mMin = reMin.firstMatch(s);
  if (mMin == null) {
    bad('minSdk line not found in ${g.path}');
  } else {
    final v = int.tryParse(mMin.group(3)!);
    if (v != null && v >= minSdk) {
      ok('minSdk = $v');
    } else {
      s = s.replaceFirst(reMin, 'minSdk${mMin.group(2)}$minSdk');
      fixed('minSdk ${mMin.group(3)} -> $minSdk (needed by Firebase and ML Kit)');
    }
  }

  // ---- compileSdk: geolocator and geocoding refuse to link against 33.
  final want = _wantedCompileSdk();
  final reCompile = RegExp(r'(compileSdk(?:Version)?)(\s*=\s*|\s+)([^\s\r\n]+)');
  final mC = reCompile.firstMatch(s);
  if (mC == null) {
    final at = s.indexOf(RegExp(r'android\s*\{'));
    if (at < 0) {
      bad('no android { } block in ${g.path}');
    } else {
      final brace = s.indexOf('{', at) + 1;
      final op = g.path.endsWith('.kts') ? ' = ' : ' ';
      s = s.replaceRange(brace, brace, '\n    compileSdk$op$want');
      fixed('compileSdk set to $want');
    }
  } else {
    final cur = int.tryParse(mC.group(3)!);
    if (cur != null && cur >= 34) {
      ok('compileSdk = $cur');
    } else {
      final op = mC.group(2)!.contains('=') ? ' = ' : ' ';
      s = s.replaceFirst(reCompile, 'compileSdk$op$want');
      fixed('compileSdk ${mC.group(3)} -> $want '
          '(geolocator/geocoding need 34 or later)');
    }
  }

  if (s != before) g.writeAsStringSync(s);

  _fixPluginCompileSdk(want);
}

/// Raises compileSdk for EVERY Gradle module, not just :app.
///
/// Flutter plugins each carry their own compileSdk, hardcoded by the plugin
/// author: geocoding_android 3.3.1 pins 33, while the AndroidX libraries it
/// pulls in demand 34+. Nothing in android/app can change that, which is why
/// the build kept failing on `:geocoding_android is currently compiled
/// against android-33`. This block, in the ROOT android/build.gradle, applies
/// to every subproject. It is registered before any plugin is evaluated, so
/// it lands before AGP freezes the value.
void _fixPluginCompileSdk(int want) {
  const marker = 'ANTARVANI plugin compileSdk override';

  final kts = File('android/build.gradle.kts');
  final groovy = File('android/build.gradle');

  // Kotlin DSL: this file is pure Flutter boilerplate that nobody edits, so
  // rather than keep patching it (and keep getting it wrong), write the whole
  // thing from a known-good version with the override already in it. The
  // original is kept as a .bak the first time.
  if (kts.existsSync()) {
    final before = kts.readAsStringSync();
    final wanted = _canonicalRootKts(marker, want);
    if (before.trim() == wanted.trim()) {
      ok('android/build.gradle.kts already correct (compileSdk $want)');
      return;
    }
    final bak = File('android/build.gradle.kts.antarvani.bak');
    if (!bak.existsSync()) bak.writeAsStringSync(before);
    kts.writeAsStringSync(wanted);
    fixed('android/build.gradle.kts rewritten — every module compiles '
        'against $want (original saved as ${bak.path})');
    return;
  }

  if (!groovy.existsSync()) {
    bad('android/build.gradle(.kts) not found — cannot raise plugin compileSdk');
    return;
  }

  final original = groovy.readAsStringSync();
  var text = _stripBlock(original, marker);
  final block = """
// $marker
// Every Flutter plugin carries its own compileSdk, hardcoded by the plugin's
// author — geocoding_android pins 33, while the AndroidX libraries it needs
// require 34 or later. Nothing in android/app can change that, so raise it
// for every module here.
ext.ANTARVANI_SDK = $want
subprojects {
    def raiseCompileSdk = {
        def androidExt = project.extensions.findByName('android')
        if (androidExt != null) {
            try {
                androidExt.compileSdk = ANTARVANI_SDK
            } catch (Throwable ignored) {
            }
        }
    }
    if (project.state.executed) {
        raiseCompileSdk()
    } else {
        project.afterEvaluate { raiseCompileSdk() }
    }
}

""";

  final at = text.indexOf(RegExp(r'^\s*subprojects\s*\{', multiLine: true));
  text = at < 0
      ? '$text\n$block'
      : text.substring(0, at) + block + text.substring(at);

  if (text == original) {
    ok('plugin compileSdk override already correct in ${groovy.path}');
    return;
  }
  groovy.writeAsStringSync(text);
  fixed('every plugin module compiles against $want (${groovy.path})');
}

/// Flutter's root android/build.gradle.kts, plus the compileSdk override.
///
/// Everything outside the marked block is exactly what `flutter create`
/// writes: the shared repositories, the relocated build directory, and the
/// clean task. The override sits before Flutter's own `subprojects` blocks
/// because one of those evaluates `:app` immediately, and afterEvaluate
/// cannot be registered on a project that is already evaluated.
String _canonicalRootKts(String marker, int want) => """
allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// $marker
// Every Flutter plugin carries its own compileSdk, hardcoded by the plugin's
// author — geocoding_android pins 33, while the AndroidX libraries it needs
// require 34 or later. Nothing in android/app can change that, so raise it
// for every module here. Remove this block and the build fails with
// "requires ... compile against version 34 or later of the Android APIs".
val ANTARVANI_SDK = $want
subprojects {
    val raiseCompileSdk = {
        val androidExt = extensions.findByName("android")
        if (androidExt != null) {
            runCatching {
                androidExt.javaClass.methods
                    .first { it.name == "setCompileSdk" && it.parameterTypes.size == 1 }
                    .invoke(androidExt, ANTARVANI_SDK)
            }
        }
    }
    if (state.executed) raiseCompileSdk() else afterEvaluate { raiseCompileSdk() }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
""";

/// Removes a previously inserted block: the marker comment, anything up to
/// the `subprojects {` that follows it, and that whole brace-matched block.
String _stripBlock(String text, String marker) {
  final i = text.indexOf('// $marker');
  if (i < 0) return text;
  var start = text.lastIndexOf('\n', i);
  start = start < 0 ? 0 : start + 1;

  final sp = text.indexOf('subprojects', i);
  if (sp < 0) return text.substring(0, start);
  final open = text.indexOf('{', sp);
  if (open < 0) return text.substring(0, start);

  var depth = 0;
  var j = open;
  for (; j < text.length; j++) {
    if (text[j] == '{') {
      depth++;
    } else if (text[j] == '}') {
      depth--;
      if (depth == 0) {
        j++;
        break;
      }
    }
  }
  while (j < text.length && (text[j] == '\n' || text[j] == '\r')) {
    j++;
  }
  return text.substring(0, start) + text.substring(j);
}

/// The Android Gradle Plugin version this project uses, as (major, minor).
(int, int)? _agpVersion() {
  const files = [
    'android/settings.gradle.kts',
    'android/settings.gradle',
    'android/build.gradle.kts',
    'android/build.gradle',
  ];
  final re = RegExp(
      r'com\.android\.(?:application|tools\.build:gradle)[^\r\n]*?(\d+)\.(\d+)\.(\d+)');
  for (final p in files) {
    final f = File(p);
    if (!f.existsSync()) continue;
    final m = re.firstMatch(f.readAsStringSync());
    if (m != null) {
      return (int.parse(m.group(1)!), int.parse(m.group(2)!));
    }
  }
  return null;
}

/// The highest compileSdk this project's AGP can actually compile against.
/// Going higher than AGP supports fails the build just as surely as 33 does.
int _wantedCompileSdk() {
  final agp = _agpVersion();
  if (agp == null) {
    info('AGP version not found; using the safe compileSdk 34.');
    return 34;
  }
  final (major, minor) = agp;
  info('Android Gradle Plugin $major.$minor');
  if (major > 8 || (major == 8 && minor >= 9)) return 36;
  if (major == 8 && minor >= 6) return 35;
  return 34;
}

// ---------------------------------------------------------- 13. build
Future<void> buildChecks() async {
  head('13. Packages, icon, analyze, test');

  if (await live('flutter', ['pub', 'get']) == 0) {
    ok('flutter pub get');
  } else {
    bad('flutter pub get failed (see above)');
    return;
  }

  if (await live('dart', ['run', 'flutter_launcher_icons']) == 0) {
    ok('launcher icon generated');
  } else {
    bad('flutter_launcher_icons failed (see above)');
  }

  log('  > flutter analyze');
  final a = await run('flutter', ['analyze', '--no-fatal-infos', '--no-fatal-warnings']);
  final lines = out(a).split('\n');
  final errs = lines.where((l) => l.trimLeft().startsWith('error')).toList();
  final warns = lines.where((l) => l.trimLeft().startsWith('warning')).toList();
  for (final l in [...errs, ...warns]) {
    info(l.trim());
  }
  if (errs.isEmpty) {
    ok('flutter analyze: 0 errors, ${warns.length} warnings');
  } else {
    bad('flutter analyze: ${errs.length} errors, ${warns.length} warnings');
  }

  if (await live('flutter', ['test']) == 0) {
    ok('flutter test passed');
  } else {
    bad('flutter test failed (see above)');
  }
}

// -------------------------------------------------------------- summary
void finish() {
  head('SUMMARY');
  if (fixes.isNotEmpty) {
    log('  Fixed this run:');
    for (final f in fixes) {
      log('    - $f');
    }
  }
  if (todos.isNotEmpty) {
    log('  Still to do:');
    for (final t in todos) {
      log('    - $t');
    }
  }
  if (errors == 0 && todos.isEmpty) {
    log('\n  ALL GREEN. Plug in a phone and run:   flutter run');
    log('  APK for the team:                     flutter build apk --release');
  } else {
    log('\n  $errors error(s), ${todos.length} to-do. Fix those, then run setup again.');
    log('  If stuck, send me setup_report.txt');
  }
  try {
    File('setup_report.txt').writeAsStringSync(report.toString());
  } catch (_) {}
}
