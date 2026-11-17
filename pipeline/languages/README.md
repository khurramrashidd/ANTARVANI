# Adding a language

1. Copy `TEMPLATE.json` to `<code>.json` (for example `mr.json`).
2. Set `code` (2-3 letters), `name`, and `tts` (the phone voice, e.g. `mr-IN`).
3. List the phrases as `[id, text in its own script, romanised, English]`.
   Number them P01, P02, ... with no gaps. **The count and order are frozen
   once recording starts** - the numbers are the training labels. Have a
   native speaker check every phrase before anyone records.
4. Put the file where it has a link (commit it to GitHub and use the *Raw*
   link), or just copy its text.
5. In the app, as an admin: Corpus > Overview > Languages > paste > Add language.
   The app saves the language for every phone and writes `phrases.json` into
   a new Drive folder `lang_<code>` inside the corpus folder.
6. Choose the language under Languages and record as usual. Clips go to
   `lang_<code>/P01/...`.
7. Train: open the notebook, set `LANG = "<code>"`, Run all, publish the link.

The template holds 3 example phrases only so that it is short. They have not
been checked by a native speaker. A real language should cover the same 20
needs as the Hindi set so results can be compared.
