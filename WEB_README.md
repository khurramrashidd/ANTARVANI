# ANTARVANI web — what is in here and how to put it up

Extract this over `silent_voice_recorder\web\`, so the files land in
`silent_voice_recorder\web\public\`.

```cmd
powershell -command "Expand-Archive -Path '<path to this zip>' -DestinationPath 'F:\2026\My_projects\College_project\Silent_voice\silent_voice_recorder\web' -Force"
dart run tool/setup.dart
firebase deploy --only hosting
```

`dart run tool/setup.dart` must come before the deploy. It writes
`assets/firebase-config.js` from `lib/firebase_options.dart`, which is the
file that lets sign-in start.

**This zip deliberately does not contain `assets/firebase-config.js`.** An
earlier copy did, carrying `REPLACE_ME` placeholders, and extracting it
overwrote the real keys `setup` had already written — the site then looked
correct and sign-in silently did nothing. Leaving the file out of the archive
makes that impossible: extraction can no longer touch it.

If `firebase-config.js` is missing or still says `REPLACE_ME`, the sign-in
page says so and prints the commands that fix it, rather than showing a
button that does nothing.

## The files

| File | What it is |
| --- | --- |
| `index.html` | Public project page |
| `dashboard.html` | Team dashboard, behind Google sign-in |
| `assets/app.css` | One stylesheet for both pages. Light by default, dark on the toggle |
| `assets/chrome.js` | Sidebar, section router, clock, weather, figure lightbox |
| `assets/dashboard.js` | Firestore reads and the eight dashboard sections |
| `assets/site.js` | The public page's figures and result |
| `assets/theme.js` | Light/dark toggle, remembered per browser |
| `assets/phrases.js` | The twenty phrases, mirroring the pipeline |
| `data/README.txt` | Where the Colab figure export goes |

## Results on the site

`data/` is empty until you run `pipeline/ANTARVANI_figures.ipynb`, download
`antarvani_web_data.zip` from its last section and unzip it into
`web\public\data\` so that folder holds `figures.json` beside the PNGs. Until
then both pages say the figures have not been exported yet, rather than
showing a placeholder number.

## Volunteer names

Names are read from Firestore and shown only on the dashboard, after sign-in.
There is no export button anywhere in this code, and the public page carries
speaker numbers only.
