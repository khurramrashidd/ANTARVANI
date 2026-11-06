# Start here

**Extract the zip into the folder ABOVE this one**, not into this folder.
The zip already contains a `silent_voice_recorder` folder, so extracting it
here creates `silent_voice_recorder\silent_voice_recorder` — a second copy of
the whole project. Everything then looks fine except `flutter analyze`, which
reads both copies and complains that `firebase_options.dart` is missing.
`setup` spots this and offers to delete the duplicate.

From this folder, run one command:

    setup

It checks everything, fixes what it can, opens the console pages that need a
click, and writes `setup_report.txt`. Run it again any time; it is safe.

- `CHANGELOG.md`  what changed in each zip
- `lib/`          app code
- `tool/`         the setup script
- `assets/logo/`  logo, launcher icon, wordmark for slides/reports
- `docs/`         FIREBASE_SETUP.md (manual reference), COMMANDS.md
