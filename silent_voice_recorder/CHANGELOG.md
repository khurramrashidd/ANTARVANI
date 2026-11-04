# ANTARVANI app — changelog

Zip files are numbered: `ANTARVANI_app_v01.zip`, `v02`, `v03` … Always use the
highest number. (This is the delivery number, not the app's `version:` in
pubspec.yaml, which stays 1.0.0+1 until you decide to change it.)

## v14 — 3 Nov 2026

**Fixes `Initializer type mismatch: expected 'Directory'` in
android/build.gradle.kts.** Patching that file by hand damaged it — the
`newBuildDir` line lost the rest of its expression, so the script no longer
compiled. Repeatedly editing someone else's boilerplate was the wrong
approach.

`setup` now **writes the whole file from a known-good version** instead:
Flutter's own contents (shared repositories, relocated build directory, clean
task) with the compileSdk override already in place, positioned before
Flutter's `subprojects` blocks. Your current file is saved first as
`android/build.gradle.kts.antarvani.bak`. Re-running setup after that is a
no-op, because the file already matches.

(This only applies to the Kotlin DSL. A Groovy `android/build.gradle` is
still patched in place, since its contents vary more.)

## v13 — 3 Nov 2026

**Volunteers can see their own clips.** Patient side → **My recordings**.
They enter both numbers from their consent form (speaker ID *and* form
number, both required) and see every clip of theirs with its phrase, take and
state, plus the details stored about them and a plain statement that no audio
was recorded.

The check is enforced by the server, not the screen: the app never reads the
speaker row first. It writes the typed form number as `claimProof`, and the
rules accept the write only if it matches the form number already stored. A
wrong pair is refused, so one number alone is useless and nobody can walk
through S001, S002, S003 looking at names. After a successful claim that
account can read its own row and its own clips — nothing else.

**Right to erasure.** The volunteer can ask for their clips to be deleted
from that screen. The team sees a red banner on Overview, a "delete me" tag
in the speaker list, and a note on the speaker itself. Under the DPDP Act
this is an obligation, so the wording says so rather than treating it as a
suggestion.

## v12 — 3 Nov 2026

**No speaker number is ever stranded.** A session that records nothing now
hands its number straight back: the row is deleted and the number goes into a
free list that the next session takes from before issuing a new one. Nothing
stays "cancelled". For the numbers already stuck that way from your testing,
**Overview** shows "N speaker numbers hold no clips → Free up", which clears
them all in one go. The New session card says when it is reusing a number.

**Names.** Every speaker now has a full name — typed at the start of a
session, on import, or added later — and the Speakers tab searches by name,
S-number, form number or collector. The name is private project data: the
team can see it, it is never in the manifest, and it is never published.

**The consent form has been rewritten** (`docs/ANTARVANI_consent_form.pdf`)
because the old one promised the name was not stored, which would now be
false. It now says the name is kept in the team's private database, seen only
by the four of you, never published — and that phone number and address are
never stored. It also states 1 take normally, 10 for a few volunteers.
**Print the new version before recording.**

**Breakdown tab** — speakers and clips by age band, gender, tier, first
language, Hindi fluency, lighting, camera, phone mount, facial hair, glasses
and publication consent, plus quality counts and clips per day.

**Two exports.** The manifest CSV has no names and is safe to publish; a
separate admin-only roster CSV carries the number → name mapping.

**For a real recording day**
- **Resume an unfinished speaker** — records only the missing clips, at take
  numbers that cannot collide with existing or rejected ones.
- **Re-record one phrase** — after throwing a clip away, a Record button sits
  next to that phrase.
- **Edit a speaker** — fix the name, age band, tier or a missed tick later.
- **Pre-session checklist** — charge, forms, phone propped, light, quiet
  spot. Resets each day.
- Overview flags unfinished speakers by name.

Also: the PDFs now travel inside the zip, in `docs/`.

## v11 — 3 Nov 2026

**Import keeps the real file extension.** v09/v10 renamed every imported file
to `.mp4` whatever it actually was. A `.mov` or `.3gp` renamed to `.mp4` is a
lie that breaks players and tools later. The extension is now carried over
(.mp4, .mov, .3gp, .mkv, .avi, .webm, .m4v), and the pipeline already accepts
all of them.

## v10 — 3 Nov 2026

**Finding a particular clip.** The naming was already
`P03/S014_P03_t02.mp4` and stays that way — the pipeline reads it and the
name alone identifies the clip. What was missing was a way to get to one:
- Tap any phrase bar on Overview → every clip of that phrase across all
  speakers, in speaker order.
- Search box on the Speakers tab: speaker id, form number or collector.
- Every clip row shows its `P03/S014_P03_t02.mp4` path, opens that exact
  file in Drive on tap, and its menu copies the file name or the path.
- **Export manifest CSV** on Overview writes `manifest_<date>.csv` into the
  corpus folder beside P01–P20: one row per clip with path, speaker, phrase,
  numeric label, take, status, QC verdict, override flag, source, collector
  and a direct Drive link. Open in Sheets, filter, done.

## v09 — 3 Nov 2026

**Clips you already had in Drive.** Admins get **Collect data → Import from
Drive**: it scans P01–P20, takes the oldest unregistered file in each phrase
folder, issues one speaker ID and form number for the batch, renames the
files to `Sxxx_Pyy_t01.mp4`, and writes the Firestore rows. Those clips then
appear on the dashboard and feed the pipeline like any other. One take per
phrase, as they are.

**One take per phrase by default.** Tier A is now 1 take (20 clips, ~5 min).
Tier B stays at 10 takes for the personalisation study.

**Throwing clips away.**
- During recording the playback buttons now read **Delete & redo** / **Keep**.
- On the dashboard, any clip can be thrown away: the Drive file moves to a
  `_rejected` folder (nothing is destroyed), the row keeps the reason and who
  did it, and the pipeline skips anything whose status is not `ok`.
- Admins can reject any clip; collectors can reject clips from speakers they
  recorded themselves.

**Front and back camera.** A switch button on the preview, with the current
lens shown and stored with the speaker.

**The face check no longer blocks you.** When framing looks fine to the
person holding the phone but the checker disagrees, **Looks fine — record
anyway** records it. The clip is tagged `qcOverride` and the dashboard counts
how many were overridden, so the paper can report it honestly.

**New collection dashboard** with three tabs: Overview (coverage per phrase,
Drive and upload health, QC flags, rejects, storage), Speakers (per speaker,
tap through to every clip), Team (clips and speakers per collector, live
phones).

## v08 — 3 Nov 2026

**Fixes `Cannot run Project.afterEvaluate(Action) when the project is
already evaluated`.** Flutter's own root script contains
`subprojects { project.evaluationDependsOn(":app") }`, which evaluates
`:app` on the spot. v07 appended its block *after* that line, so by the time
it ran, `:app` was finished and Gradle refused.

- The override now goes **before** Flutter's first `subprojects { }`, and
  each module is checked with `state.executed` — already evaluated means set
  the value now, otherwise set it in `afterEvaluate`.
- Re-running setup replaces the old block instead of stacking another one.

**Stops the false "No database yet".** The listing command failed once and
setup treated that as "missing", right after the rules had deployed to that
very database. A failed listing is now reported as unknown, and a successful
deploy confirms the database exists.

**Lints.** The 8 `prefer_const_constructors` hints in dashboard_screen.dart
and setup_screen.dart are gone, so `flutter analyze` is clean.

## v07 — 3 Nov 2026

**The same AAR error again — v06 fixed the wrong module.**
The message named `:geocoding_android`, not `:app`. Every Flutter plugin
carries its own compileSdk, written by the plugin's author, and
`geocoding_android 3.3.1` pins 33. Raising compileSdk inside
`android/app/build.gradle` cannot reach it.

- `setup` now appends a `subprojects { afterEvaluate { ... } }` block to the
  ROOT `android/build.gradle(.kts)` that raises compileSdk for **every**
  module, plugins included. Written for both the Groovy and Kotlin DSL, and
  registered before any plugin is evaluated so the value is not already
  frozen. Re-running setup keeps the number in step instead of adding the
  block twice.
- Your Android Gradle Plugin is 9.1, so the level used is 36.

## v06 — 3 Nov 2026

**Fixes the `assembleDebug` failure.** The build stopped with 15 AAR errors:
`geocoding_android is currently compiled against android-33`, while the
AndroidX libraries inside geolocator/geocoding require 34 or later.

- `setup` now also sets **compileSdk** in `android/app/build.gradle`.
  It reads your Android Gradle Plugin version first and picks the highest
  level that AGP can actually compile — 34, 35 or 36 — because a compileSdk
  above what AGP supports fails the build just as surely as 33 did.
  minSdk stays 24, targetSdk is untouched.
- Gradle will download the matching Android SDK Platform on the next run,
  the same way it fetched platform 33.

## v05 — 3 Nov 2026

**New app structure — login first, patient app, team tools in the sidebar.**
- Starts on a **Continue with Google** page (also registers new people).
- Everyone who signs in is a **Patient** and gets the patient app at once.
- Master admin sees everyone in **Users & roles** and makes them Collector or
  Admin. Only the master can make or remove Admins (enforced in the rules).
- Sidebar: Home, Speak, Phrase board, Type to speak, Personalise, History,
  Caregiver & SOS; **Collect data** (New session, Progress, Team chat) for
  Collectors; **Admin → Users & roles** for admins; Settings, dark mode,
  language, sign out. Header: photo, role, date, time, city, weather.
- English (default), Hindi, Marathi. Light mode default, dark mode toggle.
- Working now: phrase board (Hindi voice), type to speak, quick replies,
  history, caregiver call, SOS. Layout only: Speak, Personalise.

**Speaker IDs: no more phone numbers.** One shared Firestore counter issues
S001, S002 … in order to whoever presses Start, any number of collectors.
Needs internet for a few seconds at Start. The "Which phone is this?"
question is gone.

**Other**
- Operator name = the signed-in person (no prompt).
- Drive permission is asked only from collectors, via **Connect** in
  New session — patients never see a Drive prompt.
- `members` collection replaced by `users` (with role). New rules deploy
  automatically when you run `setup`.
- Manifest: location permission, text-to-speech and dialler queries
  (added by `setup`).
- New packages: flutter_tts, url_launcher, geolocator, geocoding, http.
- Tests: shared-counter IDs, role logic, every text has en/hi/mr.

## v04 — 3 Nov 2026

- Setup opens each console page in the right Google account
  (`authuser=`): Firebase/Cloud pages as 6893, the Drive folder as 0786.
  Before, the browser used its default account (0786), which has no rights
  on the 6893 project — that is why "Grant access" was missing.
- Optional console access for 0786 now uses Firebase → Users and
  permissions instead of the Cloud IAM page.

## v03 — 2 Nov 2026

**Drive now goes to 0786, Firebase stays on 6893.**
- Clips upload into the existing corpus folder in khurramrashid0786's Drive
  (folder id 1Hw76NlkEjJdCsD40TY-YhA4qBIlGVqex), into P01..P20 sub-folders,
  named `S107_P03_t02.mp4` — exactly the layout the Colab pipeline reads.
  Before: each phone made its own "Silent Voice Corpus" in whoever was
  signed in, sorted by speaker — that would have scattered the data.
- Drive scope changed from `drive.file` to `drive` (needed to write into a
  folder made by hand). Anyone who signed in before must sign out and in.
- The app checks on sign-in that the account can add files to the corpus
  folder; if not, the Corpus tab says in red who must share it.
- Re-uploads never duplicate: an existing file with the same name is reused.
- Setup asks for the team's Gmail addresses once, then walks you through
  sharing the folder (Editor) and adding OAuth test users.
- Fixed the one analyzer warning in tool/setup.dart.

## v02 — 2 Nov 2026

**One command now does the setup:** `setup` (runs `tool/setup.dart`).
It checks each item, fixes it if it is wrong, and moves on:
tools → stray files → firebase.json/.firebaserc/rules/indexes → Firebase
login (switches to 6893 if needed) → database → deploy rules → Android app
registration → SHA-1 (reads it and registers it with the Firebase CLI) →
fresh google-services.json → Google sign-in check → Drive API / IAM pages →
AndroidManifest label + permissions → minSdk 24 → pub get → launcher icon →
analyze → test. Writes `setup_report.txt`.

**Fixed**
- `firebase deploy` said "No targets match" because `firebase init` was
  interrupted before it wrote the firestore section of firebase.json. The
  setup script adds it without touching flutterfire's section.
- Rules: the master account now counts as a member everywhere (before, the
  master could not read the chat until a members entry existed).
- Master admin entry is created automatically the first time
  khurramrashid0786@gmail.com signs in to the app (`Team.ensureMasterDoc`);
  if it already exists, nothing happens.

## v01 — 2 Nov 2026

**Fixed (from your `flutter analyze` log)**
- `lib/services/sync_service.dart` rewritten: Firebase is initialised only in
  `main.dart`; Firestore collections are non-nullable; missing imports added.
  Every write goes to local disk first, then Firestore, then the Drive queue.
- `drive_uploader.dart`: `return await _attach();` (unawaited-future lint).
- `test/widget_test.dart` no longer references the old `MyApp`.
- Old stray `lib/record_screen.dart` must be deleted (the real one is
  `lib/screens/record_screen.dart`).

**New**
- App logo + launcher icon (`assets/logo/`), adaptive icon for Android 8+.
- App title is now "ANTARVANI"; theme colour is the logo indigo.
- `docs/FIREBASE_SETUP.md` updated for the real situation: project owned by
  khurramrashid6893, Firestore API must be enabled before creating the DB.

**Unchanged**
- 3 s recording; 2–3 s clips are accepted by the pipeline.
- Speaker ID / form number auto-allocation by phone block.
- Team chat, Team & roles, master admin khurramrashid0786@gmail.com.
