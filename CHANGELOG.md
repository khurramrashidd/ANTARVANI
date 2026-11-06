# ANTARVANI app — changelog

Zip files are numbered: `ANTARVANI_app_v01.zip`, `v02`, `v03` … Always use the
highest number. (This is the delivery number, not the app's `version:` in
pubspec.yaml, which stays 1.0.0+1 until you decide to change it.)

## v25 — 5 Nov 2026

**"Already linked to a different account" — fixed.** A session could be
claimed once and never again, so any session a collector opened while testing
was locked away from the volunteer it belonged to. That is what S003 was
hitting even with the right code.

The rule now says: **knowing the access code is the proof.** The code is on
the paper form and nowhere else, so whoever has it may take the link over.
A session with **no** code keeps the old behaviour — the form number is
derivable from the speaker number, so it proves nothing on its own, and the
first account to link keeps it until someone unlinks it.

**Unlink, for the cases a code cannot solve.** A speaker's page now shows
"Linked to name@gmail.com — unlink" when a session is claimed. Unlinking
frees it for the right person and touches nothing that was recorded.

Messages are specific now: a collector who can read the row is told exactly
who holds the link, and a volunteer is told that a collector can unlink it.

## v24 — 5 Nov 2026

**Volunteers can watch their own clips — without opening the corpus.**
A speaker's page has **"Let this volunteer watch their own clips"**. It grants
read access on that person's files alone, to that one Google account (any
editor of the folder can do it, not just the uploader — sharing is a lighter
permission than deleting). A **Watch** button then appears beside each clip in
their *My recordings*.

If they have not linked their account yet, the button asks for the address
they will sign in with.

> **Do not use "anyone with the link" on the corpus folder.** The folder ID is
> hardcoded in `lib/services/drive_uploader.dart`, which is in the public
> repository, so a public link makes every volunteer's face video readable by
> anyone who reads the code — the exact opposite of what the consent form
> promises. Per-person sharing exists so you never need it.

**Access codes for older sessions.** A speaker with no code gets a
**"Give this session an access code"** button; the code is shown once, big,
to write on their existing paper form or tell them. Before this, S001 and the
other pilot sessions could be opened by anyone who learned the speaker ID,
since the form number is derivable from it.

## v23 — 5 Nov 2026

**`flutter analyze` is clean again.** The six `prefer_const_constructors`
hints left after the duplicate folder was removed are fixed: the deletion
notice on a speaker, the "uploading in the background" line, the update
icon, and one `DeleteReport.blocked`. All info-level, none of them affected
behaviour.

## v22 — 5 Nov 2026

**Catches the duplicate-project trap.** If the zip is extracted *into* the
project folder instead of the folder above it, you end up with
`silent_voice_recorder\silent_voice_recorder`. Everything looks right —
setup's own checks pass, the tests pass — but `flutter analyze` reads every
Dart file under the project, including the inner copy, and that copy has no
`firebase_options.dart` (it is never in the zip). The result is two
confusing errors about a file that is plainly there. The giveaway is the
path in the error: `silent_voice_recorder\lib\main.dart` instead of
`lib\main.dart`.

Setup now finds any second copy, explains it, and offers to delete it.
START_HERE.md says where to extract.

## v21 — 4 Nov 2026

**All three credentials are always in front of the team.** The access code
was only on the speaker's own page; now the speaker ID, form number and
access code appear together wherever a session does:

- every row of the **Speakers** list,
- the speaker's page, as three boxes — **tap any one to copy it**, for
  reading back to someone who lost their form,
- the **session finished** screen, so a collector who forgot to write them
  down still has them,
- the search box matches the access code as well as the names and numbers.

Codes are stored on the speaker row, so they are there for good — nothing is
only shown once to the team. (It is shown once to the *volunteer*; that is
the point of writing it on their form.)

Sessions recorded before codes existed say "no code" and still work on the
two numbers alone.

## v20 — 4 Nov 2026

**Access codes — the two numbers now actually prove something.** Before this,
"both numbers" was theatre: F014 is just S014 with a different letter, so
anyone who learned one could work out the other.

Every session now also gets a random 4-character code (`7KH4`). It is shown
once, on the screen that tells the collector what to write on the paper form,
and it is what the volunteer needs in **My recordings** alongside the two
numbers. The alphabet leaves out everything that is misread in handwriting —
no O or 0, no I, 1 or L, no S or 5, no B or 8, no Z or 2.

- The rules check the code server-side, so a volunteer cannot get past it.
- Sessions recorded before this change have no code and still work on the
  form number alone.
- The code appears on the speaker's page in the dashboard, so a collector can
  read it back to someone who lost their form, and in the roster CSV.
- **The consent form has a new box for it** (`docs/ANTARVANI_consent_form.pdf`)
  and now tells the volunteer to keep the sheet so they can look themselves
  up. Print the new version.

## v19 — 4 Nov 2026

**"My recordings" behaved differently for collectors and volunteers — fixed.**
Two separate problems were hiding behind one screen:

1. **S003 with F004 is genuinely invalid.** Both numbers come from the same
   counter, so their digits always agree; a mismatched pair can never name a
   real session. The app now says exactly that, straight away, instead of a
   vague "does not match" after a round trip.
2. **Collectors were not being checked at all.** The rules let any team
   member write to a speaker row, so their claim went through whatever form
   number they typed — which is why it "worked" on a collector's phone and
   failed on a volunteer's. The app now verifies the pair itself for anyone
   who can read the speaker list, so both see the same answer.

Other messages on that screen are sharper too: a number that does not exist
says so (and that it may have been recycled), and a session whose form
number differs names the right one.

## v18 — 4 Nov 2026

**`.gitignore` added**, for putting the project on GitHub. It keeps out build
output and, more importantly, anything carrying a key or a person's details:
`firebase_options.dart`, `google-services.json`, signing keys,
`setup_report.txt` and `.antarvani_setup.json` (team emails and SHA-1), APKs,
and any `roster*.csv` or `manifest*.csv` that ends up in the folder.

`firebase.json`, `.firebaserc`, `firestore.rules` and
`firestore.indexes.json` **are** committed on purpose — the rules are the
project's security policy and belong under review like any other code.

Anyone cloning the repo runs `setup`, which regenerates the ignored config
for their own machine.

## v17 — 4 Nov 2026

**Everyone stays on the same build.** The master admin publishes a release
from Overview → **Publish an app update**: build number, the GitHub or Drive
link to the APK, and a line about what changed. Any phone on an older build
is locked out of the whole app until it installs the new one, so the team can
never compare clips collected by two different versions of the recorder.

- The update screen shows what this phone has, what it needs, what changed,
  and a Download button that opens the link in the browser.
- It reads through Firestore's offline cache, so a phone that was told to
  update and then went offline stays told.
- **The way back out:** publishing the wrong build number would lock out the
  person who has to fix it, so the master admin — and only the master — gets
  an "I published this by mistake — undo" link on that screen.
- The version stays **1.0.0+1**, so the APK you have now is build 1. Raise
  the number after `+` in pubspec.yaml for each new APK; `docs/COMMANDS.md`
  has the release steps.

## v16 — 4 Nov 2026

**"Could not delete the file in Drive: 403" explained and handled.** That is
not a bug in the app — Google Drive only lets the account that **uploaded** a
file destroy it, and the uploader owns it even when the file sits in someone
else's folder. The clip in your screenshot was uploaded by Kinza, so your
phone can never destroy it, however senior the account.

Deleting a recording now tries three things in order and tells you which
happened: destroy it (works for your own uploads), move it to the owner's
bin (Drive empties that after 30 days), or — failing both — move it out of
P01–P20 into a `_deleted` folder renamed `DELETED_…` so it can never be
mistaken for corpus data. Either way the records go and the number is
reused, and the message names who still has to finish the job.

The person who uploaded them then sees a card on Overview: "N files you
uploaded still have to be deleted → **Delete mine**". One tap, done.

**Collectors can delete their own recordings.** The bin on a speaker, and the
delete-by-number box, now work for the collector who recorded that speaker as
well as for admins. Trying to delete someone else's says who to ask.

**Real / Demo switch** at the top of New recording session. In Demo nothing
is saved anywhere: no speaker number is taken from the counter, no row is
written to Firestore, nothing reaches Drive, and each clip is deleted the
moment you finish reviewing it. No form fields are required either — press
Start demo and record. A yellow "DEMO — nothing is saved or uploaded" banner
sits across the recording screen so it can never be confused with a real
session.

## v15 — 4 Nov 2026

**Start recording would never turn on — fixed.** The volunteer's name field
never made it onto the New recording session screen: my v12 patch matched
text that had already changed, so it silently did nothing while the Start
button still waited for a name that could not be typed. The field is there
now, under SPEAKER.

**The button no longer goes grey.** It is always tappable; if something is
missing it names exactly what, in a list. A red line under the button also
shows what is outstanding without tapping. A disabled button that will not
say why was the wrong design.

**Master admin can delete a whole recording.** Overview → *Delete a
recording by number* (admins only), or the bin in a speaker's top bar. Type
S014 **or** F014 — the same session either way — confirm by typing the ID,
and every video of theirs is **deleted from Drive for good**, their records
are removed, and the number goes straight back into the pool. A tombstone in
`deletions` keeps the number, form number, clip count, who and why — never
the name, since the usual reason is that someone asked to be forgotten.

**My recordings holds several numbers.** You can add your own alongside
someone else's: chips at the top switch between them, "Add another number"
links one more, and each can be unlinked from the phone.

**The read-aloud script** on the session screen now matches the new consent
form — it no longer says the name is not stored.

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
