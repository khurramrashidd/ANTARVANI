# The ANTARVANI website

Two pages, deployed to Firebase Hosting in the same project as the app
(`antarvaani-the-voice`), so the dashboard can read the same corpus the
phones write.

| | | |
|---|---|---|
| `public/index.html` | the project page | public, no sign-in |
| `public/dashboard.html` | the live corpus | team only, Google sign-in |

No framework and no build step. Plain HTML, one stylesheet and two scripts,
which is why deploying is one command and why it will still work in three
years.

## Deploy

```
setup
firebase deploy --only hosting
```

`setup` does two things for the website: it registers the Firebase **web**
app (`flutterfire configure --platforms=android,web`) and writes
`public/assets/firebase-config.js` from `lib/firebase_options.dart`, so the
site and the app can never drift onto different projects. It also adds the
`hosting` block to `firebase.json`. Nothing here needs editing by hand.

The URLs are `https://antarvaani-the-voice.web.app` and
`.../dashboard` (or `/dashboard.html`).

## Filling in the figures

The project page reads `public/data/figures.json` and the PNGs beside it.
Both are written by `pipeline/ANTARVANI_figures.ipynb`:

1. open that notebook in Colab, set `FACE_SPEAKER`, **Run all**
2. download `antarvani_web_data.zip` from the last cell
3. unzip it into `web/public/data/`
4. `firebase deploy --only hosting`

Every number on the page comes from that file. There is nowhere to type a
figure in by hand, which is the point: if the training run has not happened,
the page says the evaluation is still to come, and if the run came out at
chance the page says that too, above the numbers, before anyone has to ask.

## Who can see what

Volunteers appear on the public page as speaker numbers and nothing else.
Names live in Firestore and are shown only after a Google sign-in that
`users/{email}` recognises as `member`, `admin` or `master` — the same rule
the app uses, enforced by the same `firestore.rules`. The master admin is
recognised by address so the project cannot lock out its own owner.

The Firebase keys in `firebase-config.js` are not secret; every Firebase web
app serves them in plain text. The rules are what protect the data.

## Light and dark

The site opens **light** — that is what a projector, a printed handout and a
corridor all favour, and the figures are white-background documents that sit
flat on a light page instead of glowing on a dark one. The moon button in the
nav switches to dark, and the choice is remembered per browser under
`antarvani-theme`, across both pages.

Every colour that differs between the two is a token in the `:root` and
`:root[data-theme="dark"]` blocks at the top of `site.css` and appears
nowhere else, so a new component picks up both themes by using the token
rather than by being told about dark mode. The theme is applied by a short
inline script in each page's `<head>`, before the first paint, so a
remembered dark never flashes light on the way in.

## Changing it

* **Phrases** — `public/assets/phrases.js`, but change
  `pipeline/antarvani_pipeline.py` first. That is the copy models are
  trained against; this one only draws cards.
* **Figures shown, and their captions** — `WEB_FIGURES` in
  `pipeline/antarvani_figures.py`. A figure that was not produced is left
  out of the manifest rather than left broken on the page.
* **Colours and type** — the tokens at the top of `public/assets/site.css`.
  Change both the light and the dark block, or the other theme drifts.

## Checked

Chrome, Firefox and Safari, at 390 px and at 1440 px. No horizontal scroll
at either width, the type scales with the viewport, and the page renders
with its content visible even if the scripts never run.
