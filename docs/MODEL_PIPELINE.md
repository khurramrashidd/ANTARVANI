# From videos in Drive to a model on every phone

    record in the app  ->  Drive corpus  ->  Colab notebook (Run all)
            ^                                        |
            |                                 .tflite + .json
            |                                        |
       phones download  <-  admin pastes link  <-  GitHub release

Nothing in this loop needs a new APK. Add videos, run the notebook, paste one
link, and every phone has the new model the next time it is online.

## Every time you retrain

1. Open `pipeline/ANTARVANI_train.ipynb` in Colab, signed in as the account
   that can see the corpus folder in Drive.
2. Runtime > Change runtime type > T4 GPU (first time only).
3. Runtime > Run all. Allow Drive when asked.
4. Wait. New videos are preprocessed; old ones are read from the cache in
   `ANTARVANI_work/cache`. With about 500 clips expect 30-40 minutes on a T4.
5. The last lines print either a link (if automatic upload is set up) or
   where the two files are.
6. In the app, as an admin: Corpus > Overview > **Publish a model** > paste
   the link ending in `.json` > Check and publish. The app downloads the model
   itself first, checks the checksum, shows you the accuracy and what it
   replaces, and only then asks you to confirm.

## Uploading by hand (no token needed)

1. In Drive open `ANTARVANI_work/models/hi/v<N>/` and download
   `antarvani_hi_v<N>.tflite` and `antarvani_hi_v<N>.json`.
2. On GitHub: your repository > Releases > Draft a new release.
   Tag: `model-hi-v<N>`. Attach both files. Publish.
3. Right-click `antarvani_hi_v<N>.json` in the release > Copy link address.
4. Paste it in the app as above.

The repository (or a separate small one just for models) must be **public**:
phones download without signing in to GitHub. The model contains no video, no
names and no faces - only network weights.

## Uploading automatically

1. GitHub > Settings > Developer settings > Fine-grained tokens > Generate.
   Repository access: only the models repository. Permission: Contents, read
   and write.
2. In Colab click the key icon on the left, add a secret named
   `GITHUB_TOKEN`, paste the token, switch on "Notebook access".
3. In the notebook's settings cell set `GITHUB_REPO = "user/repo"`.

The token never leaves Colab's secret store and is not written to the notebook.

## What the notebook reports, and what it means

| Number | Meaning |
|---|---|
| top-1 on unseen speakers | How often the first guess is right for someone the model has never seen. This is the number for a new patient. |
| top-3 | How often the right phrase is among the three choices the app offers when it is unsure. |
| chance | What guessing would score (5% for 20 phrases). |
| k-shot personalised | Accuracy after a new speaker gives k samples per phrase. Needs speakers with repeated takes (Tier B). |

All of it comes from leave-speakers-out folds: no speaker is ever in both the
training and the test side. With fewer than 3 speakers nothing is reported,
because nothing can be held out.

`paper_numbers.md` in the model's folder holds the same numbers ready to copy
into the paper; the three `fig_*.png` files are its figures.

## Going back to an older model

Publish the older model's `.json` link again. Phones install whatever is
published, whether its version number is higher or lower.

## A new language

See `pipeline/languages/README.md`. In short: add the language in the app,
record into it, set `LANG` in the notebook, run, publish. Each language has
its own folder (`lang_<code>`), its own model and its own row in the app.

## What must stay in step

The phone prepares camera frames the way the notebook prepared the training
videos: outer eye corners -> level the eyes -> square around the mouth, side
= eye distance x 1.6 -> 88 x 88 grey, 48 frames at 16 per second. These
numbers travel inside the model card, and the app reads them from there. If
you change them in `antarvani_pipeline.py`, the next published model carries
the change to the phones by itself. Do not change the *method* of cropping in
one place only.
