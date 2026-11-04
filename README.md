# ANTARVANI app

A smartphone camera-based silent speech interface. One app with two sides:

**Patient side (everyone who signs in)**
- Home: quick Yes / No / Wait / Help, and a card for every feature
- Speak: camera on the lips → phrase spoken aloud *(layout ready; needs the trained model)*
- Phrase board: the 20 phrases as big buttons, spoken in Hindi — works now
- Type to speak: type anything, read aloud in Hindi / Marathi / English — works now
- Personalise: few-shot calibration *(layout ready; needs the model)*
- History: everything spoken, tap to repeat — works now
- Caregiver & SOS: saved caregiver number, one-tap call, press-and-hold SOS — works now

**Team side (in the sidebar, only for Collectors and Admins)**
- Collect data → New recording session, Progress & uploads, Team chat,
  and (admins) Import from Drive
- Admin → Users & roles

## What a volunteer can see
A volunteer who took part can install the app, sign in, and open
**My recordings**. They type both numbers from their consent form — speaker
ID *and* form number — and see their own clips and the details stored about
them, plus a button to ask for everything to be deleted.

How the check is enforced: the app never reads the speaker row first. It
writes the typed form number as `claimProof`, and the security rules accept
the write only if it matches the form number already on that row. A wrong
guess is refused by the server, so one number alone is useless and nobody can
walk through S001, S002, S003 reading names. Once the claim sticks, that
account can read its own row and its own clips, and nothing else.

A deletion request shows on the team dashboard as a red banner and a
"delete me" tag on that speaker.

## Collection dashboard
Three tabs under **Progress & uploads**:
- **Overview** — speakers / clips / phrases covered, Drive and upload health,
  face-check flags and overrides, rejected count, storage on this phone, and
  a bar per phrase P01–P20 so the thinnest phrase is obvious at a glance.
- **Speakers** — every speaker with clip count, phrases covered, form number
  and who recorded them. Tap one to see each clip and throw bad ones away.
- **Team** — clips and speakers per collector, and which phones are active.

## Finding a particular clip
Naming is fixed and self-describing, so a file still says what it is even if
it is moved or emailed:

    <corpus folder>/P03/S014_P03_t02.mp4
                     |    |    |   |
                     |    |    |   take, 2 digits
                     |    |    phrase, P01..P20 (the training label)
                     |    speaker, S001 upward from one shared counter
                     phrase folder, same id

Inside the app:
- **Overview → tap any phrase bar** — every clip of that phrase, from all
  speakers, in speaker order.
- **Speakers → search box** — by speaker id, form number or collector.
- **Any clip row** — tap to open that exact file in Drive, or use its menu to
  copy the file name or the `P03/S014_P03_t02.mp4` path.
- **Export manifest CSV** on Overview — writes `manifest_<date>.csv` beside
  P01–P20 in Drive. One row per clip with path, speaker, phrase, label, take,
  status, QC, collector and a direct link. Open it in Sheets and filter.

## Throwing clips away
- **While recording:** every clip plays back at once. **Delete & redo** wipes
  it before it ever reaches Drive.
- **Afterwards:** in Speakers → a speaker, the bin icon on any clip. The file
  moves to `_rejected` in Drive (never destroyed), the row stays with the
  reason and who did it, and the pipeline skips anything not `ok`.
- Admins can reject any clip; a collector can reject clips from speakers they
  recorded.

## Keeping everyone on one build
Master admin → Overview → **Publish an app update**: build number, APK link
(GitHub release or Drive), and what changed. Every phone on an older build is
locked out until it installs it. The master can undo a wrong release from the
update screen itself. Release steps are in `docs/COMMANDS.md`.

## Demo mode
New recording session → **Demo**. No speaker number is taken, no record is
written, nothing is uploaded, and each clip is deleted as soon as you have
watched it back. A yellow banner runs across the recording screen. Use it to
show the app to your guide, or to let a nervous volunteer try once first.

## Deleting a whole recording
Overview → **Delete a recording by number**, or the bin icon on a speaker.
S014 and F014 both find the same session. Admins can delete any recording; a
collector can delete the ones they recorded.

Google Drive only lets the account that **uploaded** a file destroy it — the
uploader owns it even inside someone else's folder. So deletion tries, in
order: destroy the file, move it to its owner's bin, or move it out of
P01–P20 into `_deleted` renamed `DELETED_…`. The records are removed and the
number returns to the pool either way, and the message says which happened.
Whoever uploaded the leftovers sees a **Delete mine** card on Overview.

A row in `deletions` records the number, form number, clip count, who, why,
and anything still waiting — never a name.

## When a session goes wrong
- **Unfinished speaker** — Speakers tab → the speaker → **Record the N
  missing clips**. It records only the gaps, at take numbers that cannot
  collide with anything already there.
- **One bad phrase** — throw the clip away, then **Record** next to that
  phrase.
- **Wrong details** — the pencil in the speaker's top bar edits the name,
  age band, tier and consent ticks afterwards.
- **Start of day** — a short checklist on the New session screen: charge,
  forms, phone propped, light, a quiet spot. It resets each day.

## Breakdown tab
Speakers and clips grouped by age band, gender, tier, first language, Hindi
fluency, lighting, camera, how the phone was held, facial hair, glasses and
publication consent, plus quality counts and clips per day. This is the
dataset table reviewers ask for.

## Two exports, on purpose
- **manifest CSV** — one row per clip, **no names**. Safe to publish.
- **roster CSV** (admins) — speaker number → name and all metadata. This is
  the only link between a number and a person. Never publish it.

## Clips recorded before the app
**Collect data → Import from Drive** (admins). Scans P01–P20, takes the
oldest unregistered file in each phrase folder, issues one speaker ID and
form number for the whole set, renames the files to `Sxxx_Pyy_t01.mp4`, and
writes the rows. They then look exactly like recorded clips.

## Camera
Front camera by default so the speaker can see themselves; the switch button
on the preview flips to the back camera, which is sharper when someone else
holds the phone. The face check is a hint, not a gate — if the picture looks
right, **Looks fine — record anyway** records it and tags the clip as an
override, counted on the dashboard.

## Sign-in and roles
- First screen: Continue with Google. The same button registers new people.
- Everyone starts as **Patient**. The master admin (khurramrashid0786@gmail.com)
  opens **Users & roles** and makes team members **Collector** (or **Admin**).
- Admins can set Patient/Collector. Only the master can make or remove Admins.
- Login asks Google only for name + email. Drive access is asked for once,
  only from collectors, when they tap **Connect** in Collect data.

## Speaker IDs and names
One shared counter in Firestore (`counters/speakers`). Pressing **Start
recording** (or importing a set) issues the next number — S001, S002, … — to whichever collector
pressed it, with form number F001, F002, … Works for 2, 4 or 5 collectors.
Needs internet for those few seconds; recording itself works offline.
A number that produced no clips is handed straight back: the row is deleted
and the number goes into a free list that the next session pops from first.
So nothing is ever left sitting as "cancelled", and the set stays dense.
Admins can also sweep up every empty number at once from **Overview → Free
up**.

The volunteer's **full name** is stored next to the number, so the team can
find a person again or honour a deletion request. It is private project data:
visible to the team, never in the manifest, never published. The consent form
says exactly this.

## Data
- Clips → corpus folder in khurramrashid0786's Drive, `P01..P20/S014_P03_t02.mp4`
- Firestore: `users`, `counters`, `speakers`, `clips`, `devices`, `messages`,
  `patients/{email}/...` (reserved for patient data)
- Patient history and caregiver number stay on the phone.

## Look
Light mode by default, dark mode toggle in the top bar and sidebar.
English by default; Hindi and Marathi in the sidebar / Settings.
Sidebar header: photo, role, live date and time, city and weather
(Open-Meteo, no key; location is city-level only).

## Run
From this folder: `setup` — then `flutter run`. See CHANGELOG.md.
