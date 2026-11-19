# ANTARVANI app — changelog

Zip files are numbered: `ANTARVANI_app_v01.zip`, `v02`, `v03` … Always use the
highest number. (This is the delivery number, not the app's `version:` in
pubspec.yaml, which stays 1.0.0+3 until you decide to change it.)

## v45 — 19 Nov 2026

The app and the website disagreed about which sessions were finished, and
the website was the one telling the truth badly.

**Tier A expects 1 take per phrase, not 2.** `SpeakerMeta.toMap` wrote
`targetClips: kPhrases.length * (tier == 'A' ? 2 : 10)` — 40 for every Tier
A speaker — while `Tier.a.takes` has always been 1 and the app's own
dashboard recomputes from it and shows 20. Firestore has been carrying 40
for every speaker recorded so far. The phone looked right because it
ignored its own stored field; the website read the field and showed
"20 of 40 · 20 left · 36 unfinished" for a corpus that is complete. One
field cannot have two answers: `toMap` now uses `Tier.takes`, the same
definition the rest of the app uses.

Speaker rows already in Firestore keep the old 40. Nothing reads it now —
both the app and the website compute the target from the tier — so there is
nothing to migrate.

**The website's Rejected chip swaps the list instead of adding to it**,
which is what `_SpeakersTab` does on the phone: rejected sessions stay out
of the list the way they stay out of the totals, and the chip is how you go
and look at them. It used to show the rejected rows mixed in with all the
others, so turning it on appeared to do nothing.

**Recordings can be played from the dashboard.** Each speaker row has a
Clips button that opens that speaker's twenty phrases, in Devanagari with
the English beneath, each with a Play button. The clip streams from Drive's
own preview, so Drive applies its sharing rules — a team member with access
to the corpus folder sees the recording, anyone else gets Drive's refusal.
No copy is made and no clip is served from the website. Lost and thrown-out
clips appear in the panel too, marked as such, because those are the ones
somebody usually wants to look at.

**The header's weather is Panvel**, not Mumbai. Three values at the top of
`chrome.js` move it.

## v44 — 19 Nov 2026

Two runs have now been lost to faults that looked identical from the
training log — a loss sitting at ln(20) for an hour — and that a
thirty-second look at the data would have caught. So nothing trains any
more until the data has been looked at, measured, and shown to be
learnable.

**A new section 6 in the training notebook: see the data first.** For four
clips it shows the cached crop on top and the *same clip after
augmentation* underneath, with a motion figure under each strip. Showing
only the cached crop is exactly how an augmentation that replaced every
clip with a still frame survived a day of looking at crop pictures that
were perfectly fine.

**Pre-flight checks, before the GPU does real work.** They stop the run
with the reason rather than letting it burn an hour to arrive at chance:

* pixel range, per-clip spread, motion, class balance, speaker count —
  printed every run
* a blank cache, or clips whose frames are literally identical
* **augmentation that removes movement the cached clips had** — the exact
  fault from this morning, measured before and after
* a **memorisation test**: can the model overfit two clips per class? It
  runs twice, with augmentation and without, because which of the two
  fails says where to look. Fails both → the signal is not in the clips.
  Fails only with augmentation → the augmentation is too strong for a
  corpus this size.

No guessed thresholds. An earlier draft of this failed healthy data
because I picked a "minimum motion" number out of the air; the checks
that can fail now are the ones with no free parameter, and the real gate
is the memorisation test, which is empirical.

**Auto-stop during training.** Both rules read **training** accuracy only
— stopping on the held-out speakers would quietly turn cross-validation
into a score that has seen its own test set.

* `STALL_STOP` (15): a fold still at chance after this many epochs aborts
  the whole run. Four more folds arriving at 5.0% teach nothing the
  fifteenth epoch had not already said.
* `PATIENCE` (6): a fold stops once training accuracy has saturated, so
  `EPOCHS` is a ceiling rather than a fixed cost. It only triggers above
  97%, because stopping earlier would also cut the cosine learning-rate
  schedule short and leave a worse model.

**`AUGMENT`** can now be turned off, for when the smoke test says the
augmentation is what is blocking learning.

Measured, not assumed: this model reaches ~52% memorising 60 clips of
twenty cleanly separable classes, so the pass mark is five times chance.

## v43 — 19 Nov 2026

**Found it. The model was being trained on still images.**

`_augment` cropped each clip with `tf.image.crop_and_resize`, and passed
`box_indices = tf.zeros([48])`. That argument says which frame each box is
cut from — all zeros meant all 48 boxes were cut out of **frame 0**. Every
augmented clip became 48 copies of its own first frame: a face at rest,
before the person had started mouthing anything.

So every class looked identical, and the model sat at exactly chance on its
own training data. That is what `(train 5.0%)` meant, and why more speakers
never helped — 15 speakers and 41 speakers of still images are equally
unlearnable.

One word: `tf.range(FRAMES)` instead of `tf.zeros([FRAMES])`. Box *i*
belongs to frame *i*.

Proven both ways before and after. On a task that is purely temporal — a
block that brightens versus one that darkens, identical in every single
frame taken alone — the old code could not beat chance and the fixed code
reaches 100% training accuracy in six epochs.

**`TRAIN_REV` now goes into the resume signature.** Folds saved by the
broken pipeline look finished and are worthless; without this, a re-run
would have loaded them straight back and reported 5.0% again. Raise it
whenever a change alters what the model is trained on and every account
starts clean.

## v42 — 19 Nov 2026

**Training was running with `verbose=0`.** Forty minutes of silence between
"cross-validation, 5 folds x 60 epochs" and the result. Every epoch now
prints one line:

```
    fold 2/5 epoch  34/60   loss 1.842   train acc  61.3%     92s gone, ~ 70s left
```

One line per epoch rather than Keras's per-batch progress bar, which in
Colab means hundreds of redrawn lines and a notebook nobody wants to scroll
back through. `LOG_EVERY` in the settings cell takes 5 for every fifth epoch
or 0 for silence; the first and last epoch of a fold always print.

**The training history was being thrown away.** `fit` kept only the final
epoch's accuracy, so no training curve could ever be drawn. The whole
history per fold is now saved into `results.json`, and there is a figure
for it — loss and training accuracy per epoch with the held-out result
marked on the same axes. That figure settles the question the last run
left open: curves that climb while the held-out line stays flat mean
overfitting; curves that never leave chance mean nothing was learned and
the fault is upstream of the model.

**And the run now says which it is**, in words, at the end of
cross-validation:

```
  train 96.4%   vs   held-out 12.1%   (chance 5.0%)
  -> it learned the training speakers and none of the held-out ones:
     overfitting. More speakers, more augmentation, or a smaller model.
```

## v41 — 19 Nov 2026

**The website opens in light mode, with a dark toggle.** Light is the
default: it is what a projector, a printed handout and a corridor all
favour, and the figures are white-background documents that sit flat on a
light page rather than glowing on a dark one. The moon button in the nav
switches to dark, and the choice is remembered per browser across both
pages. The theme is applied by an inline script before the first paint, so
a remembered dark never flashes light on the way in.

Every colour that differs now lives in one of two token blocks in
`site.css` and nowhere else, so a new component gets both themes by using
the token.

Two layout bugs surfaced while checking it, both already live in v40:

* The nav links were pushing the page to 960 px wide on a phone instead of
  scrolling inside their own row. A flex item will not shrink below its
  content without `min-width: 0`, and `body { overflow-x: hidden }` had
  been hiding the damage rather than fixing it.
* The toggle's screen-reader label is `position: absolute` with no
  positioned ancestor, so it anchored to the document rather than the
  button and stretched the page from inside the scrolling nav.

Both pages now measure exactly the viewport width at 390 px and 1440 px.

**The figures notebook was never finding `results.json`.** Training writes
each run to `models/hi/v1`, `v2`, `v3`… and the notebook looked in
`models/hi` itself, so every result figure would have been skipped and the
site would have said "training is the next stage" even after a finished run.
It now takes the newest run, by version number rather than by name, so v10
sorts after v9.

**One zip with everything, as the last cell.** `ANTARVANI_results_hi.zip`:

* `results/` — results.json, the model card, `trained_speakers.json` saying
  which speakers the model saw, and the running `speakers_history.json`
* `figures/` — every figure, PNG for slides and PDF for the paper
* `web/` — what the website reads
* `corpus/` — corpus_summary.json, manifest.csv, environment.txt

About 8 MB. The `.tflite` is left out: it is most of the weight and nothing
a report needs. Speakers appear as numbers only, so no volunteer's name is
in the archive. If there is no training run the README says so instead of
quietly shipping an empty folder.

## v40 — 18 Nov 2026

**A website.** `web/public` — two pages, deployed to Firebase Hosting in the
same project as the app, no framework and no build step.

**The project page** (`index.html`, public) tells the whole story on one
scroll: the problem, all twenty phrases in Devanagari with transliteration
and English, the six-step pipeline, the corpus figures, the network, few-shot
personalisation, the results, the ethics rules, and the team. Dark, with the
figures sitting on it like paper on a desk. Checked at 390 px and 1440 px —
no horizontal scroll at either, and the content is visible even if the
scripts never run.

Every number on it comes from `data/figures.json`, which the figures notebook
writes. There is nowhere to type one in by hand. If training has not happened
the page says the evaluation is the next stage; if the run came out at chance
the page says that too, in a red panel above the numbers, before anyone has
to ask.

**The team dashboard** (`dashboard.html`) is the live corpus on the web:
speakers counting, usable clips, sessions complete, clips still to upload,
the speaker x phrase coverage grid, clips by collector, and the full speaker
table. It reads the same Firestore the phones write, so it cannot disagree
with the app. Google sign-in, and the same rule as the app — `users/{email}`
must say member, admin or master, with the master recognised by address so
the project cannot lock out its own owner. **Volunteer names appear only
here, after signing in; the public page shows speaker numbers and nothing
else.**

**Section 8 of the figures notebook** builds what the site reads: the figures
it uses, the corpus counts, the headline numbers, and a filmstrip of mouth
crops for the hero — the last only for the speaker named in `FACE_SPEAKER`,
since that one goes on a public page. It downloads as a zip to unzip into
`web/public/data/`.

`setup` now registers the Firebase **web** app alongside Android and writes
`web/public/assets/firebase-config.js` from `lib/firebase_options.dart`, so
the site and the app can never end up pointing at different projects, and
adds the `hosting` block to `firebase.json`. Nothing to fill in by hand.

Deploy: `setup`, then `firebase deploy --only hosting`.

## v39 — 18 Nov 2026

**A figures notebook.** `pipeline/ANTARVANI_figures.ipynb` — open it in Colab,
Run all, and it writes fifteen figures to `<WORK_DIR>/figures` as PNG for
slides and PDF for the paper, then zips them for download. No GPU needed.

Two sets, available at different times. The corpus and system figures need
only the clips in Drive, so they are ready now:

* the corpus: speakers, clips, clips per phrase, clips per speaker, session
  completeness, all on one slide
* a speaker x phrase grid showing exactly where the holes are
* the collection timeline
* the alignment step drawn on a real frame: eye corners, the rotated box
  they define, and the 88x88 the model is handed
* one whole utterance as its 48 crops
* the same phrase across several speakers
* mouth movement over the three-second window, phrase by phrase
* camera-to-phrase as a six-box strip, and the network as a funnel of boxes
  each as wide as its tensor

The result figures read `results.json` exactly as training wrote it:
confusion, accuracy per phrase, accuracy per held-out speaker, fold spread,
the few-shot personalisation curve, and a headline slide. If there is no run
yet they say so. If the run is at chance they say that too, and point at the
crop figures as the place to look.

One house style across all of them: one palette, type large enough for a
projector, white background, 200 dpi.

Faces are a privacy matter. Mouth crops are the model's real input and are
close to unidentifiable, so they are used freely; a whole face is drawn only
for the speaker named in `FACE_SPEAKER`, which is for a member of the team,
never a volunteer.

`pipeline/build_figures_notebook.py` regenerates the notebook from
`antarvani_pipeline.py` and `antarvani_figures.py`, so the copy inside it can
never drift from the modules in this repository.

## v38 — 18 Nov 2026

**"14 rejected" was never about the session.** That grey tag counted every
take of a speaker that isn't usable, and it put *thrown out* and *lost* under
one word — so a session that had only been reinstalled over looked as though
somebody had judged it. It reads **"14 lost"** and **"7 thrown out"** now, and
on a finished session it is gone altogether: 20/20 is green and clean, with
the full history on the session's own screen.

A **rejected session** is unmistakable instead: a red **NOT COUNTED** chip and
the card visibly faded. Nothing else wears grey.

**Unfinished sessions have their own folder in Drive.** Anything short of its
target now uploads to `_in_progress/S011/`, one folder per speaker, and moves
into `P01..P20` when the session is finished. The pipeline reads the phrase
folders and ignores everything else, so a half-recorded volunteer can no
longer reach a model by accident — and the number of files in one folder is
that volunteer's progress at a glance.

**Clips in the wrong folder** — a new card on Overview for everything
recorded before that folder existed. **Try one** moves a single clip and tells
you what Drive said; **Move what I can** does the rest. Drive only lets the
account that uploaded a clip move it, so the card names the collector who has
to run it on their own phone for the ones it can't touch. Each collector sees
the same card.

**Rejecting now actually keeps a session out of training.** It did not before:
the notebook walks the Drive folders and never read the speaker status, so a
rejected session's files were still sitting in `P01..P20`. Two things changed:

* The app writes `_skip_speakers.txt` at the top of the corpus folder and the
  notebook drops every ID in it. This takes effect the moment you reject —
  no file has to move, and nothing depends on who owns what.
* The videos move to `_rejected` as well, and come back when you put the
  session back. A finished session returns to `P01..P20`; one still short
  returns to `_in_progress`.

Deleting a speaker rewrites the skip list too — the number goes back into the
pool, and a leftover line would have quietly excluded the next volunteer to
get it.

The manifest CSV shows each clip's real folder, and the notebook prints how
many are parked in `_in_progress` and therefore not trained on.

## v37 — 18 Nov 2026

**Every Drive call now renews an expired sign-in and tries again.** This is
the "Not deleted — Could not delete in Drive: Access was denied …
invalid_token" you hit on S012. Google's token lasts about an hour; v32 taught
uploading to renew it, but delete, rename, share, scan, reject and
`phrases.json` were all still using whatever token the app picked up at
sign-in. After an hour on the dashboard, every one of them failed with a
message that read like a permissions problem and was not. All seven renew and
retry once now.

**Master admin can reject a whole session, and put it back.** Two different
things were being conflated: a session that is no good, and a number that
should go back into the pool.

* **Reject** (Speakers → open one → "Reject this session") takes it out of
  every total — speaker count, clip count, phrase breakdown, collector
  figures, and the manifest that training reads. Nothing is deleted. The row,
  the clips and the number all stay, with your reason on the record.
* **Put it back** appears in the same place once a session is rejected. When
  the volunteer re-records, one tap returns it to the corpus; if it is still
  short of its target it comes back as unfinished rather than quietly
  counting as done.
* **The bin at the top of the screen** is unchanged and still the only thing
  that frees the number: it destroys the clips first, so nothing is orphaned.

**The speaker count is honest again.** It was counting sessions whose every
clip is lost — speakers on paper, no data at all. The Overview headline now
counts active sessions only, and a card lists the ones holding nothing usable
so you can reject them all in one tap. Rejected sessions sit behind their own
chip in Speakers, with the reason and who rejected them on the session screen.

A `speakerStatus` column was added to the manifest CSV, so a rejected session
cannot walk back into training through the export.

Also fixed: "free up unused numbers" used to offer sessions whose clips were
all lost, which would have deleted the speaker row and left the clip records
behind. It now offers only numbers that hold no clip record at all.

## v36 — 17 Nov 2026

**Speak now records a video and reads the mouth out of the file**, instead of
grabbing frames from the live preview. That is how the training clips were
made, so recognition finally sees the same thing the model was trained on:
same camera path, same resolution, same encoder.

Flutter cannot decode frames from an .mp4 by itself and the ffmpeg packages
that used to do it are retired, so the frames come from Android's own
`MediaMetadataRetriever` behind a method channel. `setup` writes both Kotlin
files (`FrameExtractor.kt`, `MainActivity.kt`) into `android/app`; any
existing MainActivity is kept as `.antarvani.bak`.

Only the luminance is carried across — the colour half is filled with the
neutral value — because the detector and the model both work in grey. That is
a third less data per frame and one pass over the pixels.

**The old path is still there as a fallback.** On a phone where the native
side is missing or the video cannot be decoded, Speak drops back to live
preview frames and works as it did before. It is probed once when the camera
opens, so a phone without it never counts down twice.

The video is deleted the moment its frames are read. Nothing is kept: this is
recognition, not collection.

**Personalise follows automatically**, since both screens capture through the
same camera widget. That matters — samples recorded one way and recognised
the other would not match.

**"What the model saw".** Under the result, the actual mouth frames fed to
the model, eight of them across the clip. A wrong answer has two very
different causes — a weak model, or a crop that missed the mouth — and no
accuracy figure tells them apart. This does, in a second.

Version stays `1.0.0+3`.

## v35 — 17 Nov 2026

**The face check was never actually looking.** This is the bug behind "480 of
500 clips flagged", every clip scoring `face 0%`, and Speak refusing a face
that fills the screen.

The camera controller asks for `ImageFormatGroup.nv21`, but the CameraX
implementation — the default on Android now — ignores that and delivers
YUV_420_888 in three planes. The code passed `planes.first.bytes`, the
luminance plane alone, while telling ML Kit it was complete NV21: two thirds
of the bytes the format promises. ML Kit threw on every frame, the error was
swallowed as a dropped frame, and the score stayed at zero. Not "no face
found" — never looked.

Camera frames are now packed into real NV21 before being handed over, in
`camera_image.dart`, handling both the one-plane and three-plane cases. The
same fix covers the recording quality check and the Speak screen, since both
went through the same mistake.

The error is no longer swallowed either: a frame that cannot be checked is
reported as a failure and the reason is kept, so this cannot hide again.

**"Read it anyway".** If the detector still fails on a phone, Speak no longer
dead-ends. The frames just captured are read again with the mouth assumed to
be where it usually is, and the answer is labelled as the weaker guess it is.
No re-recording: it reuses the frames already taken.

Version stays `1.0.0+3`.

## v34 — 17 Nov 2026

Fixes the one error setup found in v33: `Team.email` is nullable, so the
rescan could not call `.isEmpty` on it directly. Nothing else changed;
version stays `1.0.0+3`.

## v33 — 17 Nov 2026

**"Upload now" could do nothing, silently.** The upload queue is a list in
the phone's own settings; the clips are files on disk and rows in Firestore.
Those three can drift apart, and when they do the dashboard says clips are
waiting while the phone's queue is empty — so the button had nothing to do
and said nothing about it.

The commonest way to cause it: `flutter install`, which **uninstalls the old
app before installing**. Uninstalling deletes the app's files and settings,
so the videos and the queue go while the Firestore rows stay.

- **Upload now repairs first.** It rescans the phone, rebuilds the queue from
  the files that are really there, uploads, and then says what happened —
  "12 left", "Nothing on this phone to upload", or the error. Same on the
  home banner and the update screen.
- **Rescan this phone** (Settings → Background upload) reports the three
  counts side by side: files here, added to the queue, and rows whose file
  has gone.
- **Mark as lost.** For rows whose file no longer exists, an admin can mark
  them lost. The row is kept with a reason and who did it; it stops being
  counted as waiting. Overview shows a "clips lost" line so the number is
  never quietly dropped.
- Lost clips are counted separately from rejected ones, which previously
  shared a bucket and would have read as "40 clips rejected".

Version stays `1.0.0+3`.

## Notebook update 2 — 17 Nov 2026 (no app change)

Surviving a stop, and saying plainly which runtime to be on.

- **A "what to do now" banner.** Says whether this runtime has a GPU, which
  step each runtime is for, how many clips are already cropped and how many
  folds already trained, and what switching the runtime would cost — nothing,
  because the work folder holds it all. Ends with the single next action.
- **Writes can no longer be left half-finished.** Colab stops a runtime
  without warning, and a `.npz` being written at that moment is left
  truncated: the file exists, so the old code counted it as done, then numpy
  failed on it an hour later in the middle of training. Crops, folds and
  JSON are now written to a temporary name and renamed into place, so a file
  only ever appears complete.
  (A trap worth recording: numpy appends `.npz` to any `savez` path that does
  not already end in it, so the temporary name has to keep that suffix or the
  rename looks for a file that was never written.)
- **Damaged crops are repaired, not fatal.** Every cached crop is read before
  training; any that cannot be decompressed are deleted and cropped again.
  The clip set stays the same, so the saved folds still match.
- **A damaged saved model retrains** instead of ending the run.
- **The lock is released on any failure** — no GPU, a disconnect, Ctrl-C —
  so a crashed account does not block the next one for forty minutes.
- **A write test before training.** If Drive is not mounted, or this account
  only has view access to the shared folder, it says so in one sentence
  instead of failing an hour later.

## Notebook update — 17 Nov 2026 (no app change)

The training notebook now runs across several Google accounts, so a session
that loses its free GPU can be carried on from the next account.

- **Folders are found by name**, not by path, so the same notebook works from
  any account whose Drive has a shortcut to `ANTARVANI` and
  `ANTARVANI_train`. A **work id** is printed; if it differs between
  accounts they are not sharing a folder, and that account would train from
  scratch.
- **Checkpoints inside a fold** through Keras `BackupAndRestore`, which
  restores the weights, the Adam moments and the epoch counter together. That
  matters: restoring only the weights — the obvious thing to write — would
  resume with a reset optimiser and a learning-rate schedule in the wrong
  place, and quietly train a worse model.
- **A lock file** stops two accounts training the same thing at once.
- **The GPU is checked** before training and before every fold. Colab hands
  back a CPU runtime when the allowance runs out, and training would carry on
  perhaps fifteen times slower; now it stops and says to switch accounts.
- **A warning when settings differ.** Saved work is only reused when the
  clips and the settings match, so a different `FOLDS` on another account
  silently starts over. It now says so.
- Cell 3 reports, before any work: both folder paths, the work id, how many
  folds are already finished, who holds the lock, and which speakers are
  complete.

## v32 — 17 Nov 2026

Fixes the one error `flutter analyze` found in v31. `clearAuthCache()` belongs
to `GoogleSignInAccount`, not to `GoogleSignIn`, so the call is now made on
the signed-in account. It also had to move below the sign-in check, since
there is no account to clear the token from until that has run. Nothing else
changed; version stays `1.0.0+3`.

## v31 — 17 Nov 2026

**Fixed the bug that was actually losing your uploads.**

A Google access token lasts about an hour. The app signed in to Drive once at
startup and kept that connection for the whole session, and nothing ever
renewed it. After an hour every upload failed with

    Access was denied ... error="invalid_token"

and the clips stayed on the phone. That is the error on the Overview card,
and it is very likely why 150 clips are not in Drive — not collectors
forgetting.

Drive calls now notice an expired token, renew the sign-in without showing
anything, and run the call again. The file stream is opened inside the retry,
so the second attempt reads the video from the beginning. If the renewal
genuinely fails, the message says to open the app and reconnect Drive instead
of printing the raw Google error.

This also makes the background service work: it may run hours after the app
was last opened, which is exactly when the old token would be dead.

**The update screen can now upload.** A phone locked out by a forced update
could not reach its own upload button, so finished clips were trapped until
the person installed the new APK. The update screen now shows how many clips
are still on the phone, with an Upload now button, and says plainly:
installing over the old app keeps them — **uninstalling deletes every clip
that has not reached Drive**.

**The notebook trains only on complete speakers.** A half-recorded speaker is
not neutral: their missing phrases drag down those classes while their
present ones are over-weighted. `MIN_PHRASES` in the settings cell (default
20, the whole set) decides who is in. Everyone else is listed with exactly
which phrases are missing, so you know whose clips to chase. They join the
next run by themselves once their uploads land. A ten-take speaker with 200
clips counts as complete, so this still works when Tier B recording starts.

**Each model records who trained it.** Every model folder now holds
`trained_speakers.json` — the speaker IDs used, their clip counts, and who
was left out and why. `models/<lang>/speakers_history.json` keeps the same
for every version, so months from now it is still possible to say which
speakers any given model saw. The figures also go into `paper_numbers.md`.

Cell 2 of the notebook now prints READY TO TRAIN and WAITING ON UPLOADS
before anything is cropped, so a bad run can be stopped in the first minute.

**Version is now 1.0.0+3.**

## v30 — 17 Nov 2026

**Uploads carry on after the app is closed.** A real Android foreground
service now drains the upload queue, over WiFi or mobile data. It shows a
notification while it works — that is not decoration, it is what Android
requires in exchange for being allowed to run at all. When the queue empties
the service stops and the notification disappears.

The app and the service never upload at the same time: the app hands the
queue over when it leaves the screen and takes it back when it returns. Both
sides now remove a clip from the queue **by its id** rather than by position,
so neither can drop a clip the other still owes. Drive also refuses a second
copy of a file name that is already there, which is a third line of defence.

**Settings → Background upload** (team members): switches for background
upload and for using mobile data, then the three steps Android needs —
notification permission, battery-optimisation exemption, and Autostart. The
first two the app can request; **Autostart cannot be switched on by any app**
on Realme, Redmi, Oppo and Vivo, so the page says where to find it. Without
the battery exemption the service is killed within minutes of the screen
going off, which is the single most common reason background upload appears
to do nothing.

The page also shows how many clips are on the phone, how many the service has
sent, when it last ran, and the last error it hit.

The red banner on a collector's home screen now links straight to that page.

**Collectors tab: own card plus team totals.** A collector sees the team's
combined figures — collectors, speakers, clips, how many are not in Drive —
and then their own card in full. No other person's name or shortfall.
Admins and the master still see everyone by name.

**Setup adds six Android permissions** (foreground service, data-sync type,
notifications, wake lock, boot, battery exemption). Run `setup` before
building.

**Not verified on a phone.** None of this could be compiled or run here. Two
things are most likely to need one fix: the exact shape of the background
service plugin's configuration call, and whether Drive sign-in works from the
background isolate on your phone. If the build fails, send me the error. If
the build is fine but background upload does nothing, open Settings →
Background upload and send me the "Last problem" line.

## v29 — 17 Nov 2026

**A Collectors tab on the corpus dashboard.** Admins and the master see every
collector; a collector sees only their own card. Per person:

- clips recorded, how many are in Drive, how many are still waiting
- how many speakers they recorded, and on how many days
- first and last recording, with date and time
- which phone holds the waiting clips and when that phone was last online
- framing quality: percentage flagged by the face check, average face score
  and mouth width
- expand "Not in Drive" to see the **speaker names and IDs** whose clips are
  stuck, how many each, when they were recorded and which phrases

**Nudge.** An admin can send a collector a reminder from their card; it goes
to the team chat with the exact counts.

**Warning on the collector's own phone.** A red card at the top of their home
screen whenever clips are still on the device, with an Upload now button. The
person holding the clips is the one who can send them.

**Stuck-clip alert on Overview.** A banner when anything has been waiting over
24 hours, naming the collector and how old the oldest clip is.

**Framing — worst speakers first.** A chart at the bottom of the Collectors
tab, lowest face score first. Below roughly 60% a clip is dropped during
training, so a red row is data you are about to lose.

**Fixed the confusing upload line on Overview.** It used to read "94 clips
still to upload (0 queued on this phone) — all uploaded", which is three
different facts in one sentence. It now says how many are not in Drive, how
many of those are on this phone, and points at the Collectors tab for the
rest.

Nothing new is stored: every number here already existed in the clip records.
Five tests added. Run `setup` as usual; no rules or Gradle changes.

## v28 — 11 Nov 2026

Fixes the release build stopping at `:tflite_flutter:compileReleaseKotlin`
with *Inconsistent JVM-target compatibility ... (11) and ... (21)*.

The cause is inside the plugin, not our code. `tflite_flutter`'s own Gradle
file still asks javac for Java 11, and because the plugin does not bring its
own Kotlin plugin it is compiled by Flutter's built-in Kotlin, which targets
the JDK running Gradle — 21. Kotlin refuses to build a module whose two
halves disagree. Nothing in `android/app` can change another module's build
file, so the root `android/build.gradle.kts` now raises that one module's
Java level to match whatever Kotlin is using. Only `tflite_flutter` is
touched: raising a plugin whose Kotlin target is deliberately low would cause
the same clash in reverse.

As a second line of defence, setup writes
`kotlin.jvm.target.validation.mode=warning` into `android/gradle.properties`,
so a different JDK on someone else's laptop produces a warning instead of a
failed build.

Run `setup` before building — it rewrites the root Gradle file and the
properties file. No app code changed.

The "plugins that apply Kotlin Gradle Plugin (KGP)" warning about
camera, device_info_plus, flutter_tts and package_info_plus is unrelated: it
is a notice about a *future* Flutter release, and those plugins have to fix it
themselves.

## v27 — 11 Nov 2026

Fixes the one error `setup` reported on v26: a variable named twice in
`language_service.dart` (adding a language). Also imports `BytesBuilder`
directly in `model_service.dart`, which clears the deprecation warning.
Nothing else changed.

## v26 — 11 Nov 2026

**The app now recognises speech.** Speak is no longer a mock-up: it counts
down, watches the lips for three seconds through the front camera, runs the
model on the phone and says the phrase aloud. If it is not sure it offers its
three best guesses instead of guessing wrong out loud. No video is saved and
no audio is opened.

**The model is not inside the APK.** An admin pastes one link in
Corpus > Overview > **Publish a model**. The app downloads the model itself
to check the link and the checksum, shows the accuracy and what it replaces,
and on confirm every phone fetches it the next time it is online. Retraining
never needs a new build. Publishing an older link rolls back.

**One-click training.** `pipeline/ANTARVANI_train.ipynb`: Run all. It finds
the corpus, preprocesses only the videos it has not seen, measures accuracy
on speakers the model never saw, runs the personalisation study, trains the
final model, and (with a token) uploads it and prints the link.
See `docs/MODEL_PIPELINE.md`.

**Personalise works.** The patient mouths a phrase a few times; the samples
stay on the phone as small greyscale mouth crops. Recognition is pulled
towards the patient's own samples. A model update does not lose them — they
are re-read with the new model the next time Speak opens.

**Languages.** Corpus > Overview > **Languages**. Hindi is built in. An
admin adds another by pasting a phrase file (`pipeline/languages/`). The
chosen language decides the phrases recorded, the Drive folder
(`lang_<code>/P01…`), the dashboard and the model used. Existing Hindi data
is untouched and stays where it is.

**Setup changes** (run `setup` once): two new rules (`models`, `languages`:
anyone signed in reads, admins write), minSdk 24 -> 26 because TensorFlow
Lite needs Android 8, and a `proguard-rules.pro` so the release build keeps
the TensorFlow classes. Two new packages: `tflite_flutter`, `crypto`.

The app is locked to portrait: the lip crop assumes an upright phone.

**Not yet verified on a phone.** None of this could be compiled or run where
it was written. The training code was run end to end on synthetic clips and
the phone's crop arithmetic was checked pixel-for-pixel against the training
crop, but the first real build and the first real recognition are yours.
`pubspec.yaml` is still `1.0.0+1`.

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
