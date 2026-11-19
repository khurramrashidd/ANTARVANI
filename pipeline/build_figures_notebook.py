#!/usr/bin/env python3
"""Builds ANTARVANI_figures.ipynb from the two modules beside this file.

The notebook has to run in Colab with nothing but itself, so the pipeline
and the figure code are written into it rather than imported. Keeping that
copy in a generated cell means the notebook can never drift from the
modules the app repository actually holds: run this again after editing
either one.

    python3 pipeline/build_figures_notebook.py
"""

import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "ANTARVANI_figures.ipynb"


def md(text: str) -> dict:
    return {"cell_type": "markdown", "metadata": {},
            "source": text.strip("\n").splitlines(keepends=True)}


def code(text: str) -> dict:
    return {"cell_type": "code", "execution_count": None, "metadata": {},
            "outputs": [],
            "source": text.strip("\n").splitlines(keepends=True)}


def writefile(name: str) -> dict:
    body = (HERE / name).read_text(encoding="utf-8")
    return code(f"%%writefile /content/{name}\n{body}")


cells = [
    md("""
# ANTARVANI — figures for the synopsis and the paper

**Runtime → Run all.** No GPU needed; a CPU runtime is fine.

Every figure is drawn from the corpus in Drive and, where there is one, from
a real training run. Nothing here invents a number: if `results.json` is not
in the model folder yet, the result figures say so and the corpus figures
still come out.

Two sets, and they become available at different times:

| | needs | when |
|---|---|---|
| corpus, pipeline, architecture | clips in Drive | now |
| accuracy, confusion, personalisation | a finished training run | after the notebook next door |

Everything lands in `<WORK_DIR>/figures` as **PNG** (slides) and **PDF**
(the paper, where a vector figure stays sharp at any zoom), and the last
cell zips the lot for download.

### A word about faces

Mouth crops are the model's real input and are close to unidentifiable, so
they are used freely. A **whole face** is only drawn for the speaker named in
`FACE_SPEAKER` below — use one of the team, never a volunteer. Volunteers
consented to a corpus, not to appearing in a slide deck.
"""),

    md("## Settings"),
    code('''
LANG       = "hi"
CORPUS_DIR = ""    # "" = find the ANTARVANI folder in this Drive
WORK_DIR   = ""    # "" = find the shared ANTARVANI_train folder
MODEL_DIR  = ""    # "" = <WORK_DIR>/models/<LANG>, where training writes

# Whole-face figure: a speaker ID of someone on the team who has agreed to
# appear in the report ("S016"). Leave it "" and that one figure is skipped;
# every other figure still runs.
FACE_SPEAKER = ""

# How big the speaker grid gets. More is slower - each cell decodes a video.
GRID_PHRASES  = 5
GRID_SPEAKERS = 7

# MUST match the CROP_SCALE the model was trained with. The crop cache is
# keyed on it, so the wrong value here re-crops all 820 clips - half an hour
# - and then draws figures of a framing the model never saw.
CROP_SCALE = 0.7
'''),

    md("## 1. Set up"),
    code('''
!pip install -q mediapipe opencv-python-headless

from google.colab import drive
drive.mount("/content/drive")

import sys
sys.path.insert(0, "/content")
print("ready")
'''),

    md("## 2. The code\n\nThe same two files the app repository holds, "
       "written out so this notebook needs nothing but itself."),
    writefile("antarvani_pipeline.py"),
    writefile("antarvani_figures.py"),

    md("## 3. Find the corpus"),
    code('''
from pathlib import Path
import antarvani_pipeline as P
import antarvani_figures as F

cfg = P.Config(lang=LANG, corpus_dir=CORPUS_DIR, work_dir=WORK_DIR,
               crop_scale=CROP_SCALE)
root, spec = P.load_language(cfg)          # finds the corpus folder itself
work = P.resolve_work_dir(cfg, Path(root))
clips = P.scan(root, spec, cfg)

FIGS = work / "figures"
FIGS.mkdir(parents=True, exist_ok=True)
MODELS = Path(MODEL_DIR) if MODEL_DIR else work / "models" / LANG

print()
print(f"corpus  : {root}")
print(f"clips   : {len(clips)}")
print(f"speakers: {len({c['speaker'] for c in clips})}")
print(f"figures : {FIGS}")
'''),

    md("""
## 4. The corpus

The first figure of a results section. These are real collection numbers and
they are the part of the project that cannot be rushed — worth a slide of
their own.
"""),
    code('''
from IPython.display import Image, display

for path in [F.fig_corpus(clips, spec, FIGS, cfg),
             F.fig_coverage(clips, spec, FIGS, cfg),
             F.fig_timeline(clips, FIGS, cfg)]:
    if path and Path(path).is_file():
        display(Image(str(path)))
'''),

    md("""
## 5. What the model actually sees

The alignment step on a real frame, then one whole utterance as 48 crops,
then the same phrase across several speakers. This is the part of a
presentation people remember, and it doubles as the check that preprocessing
is working: if these crops are black, off-centre, or all identical, no model
trained on them can do anything, whatever the accuracy cell says.
"""),
    code('''
cropper = P.LipCropper()

def pick(speaker=None, phrase=None):
    for c in clips:
        if (speaker is None or c["speaker"] == speaker) and \\
           (phrase is None or c["phrase"] == phrase):
            return c
    return None

# --- whole face: only for a speaker who has agreed to appear
if FACE_SPEAKER:
    c = pick(speaker=FACE_SPEAKER)
    if c is None:
        print(f"No clips for {FACE_SPEAKER} - skipping the face figure.")
    else:
        p = F.fig_face_crop(c["path"], cropper, FIGS, cfg)
        if p and Path(p).is_file():
            display(Image(str(p)))
else:
    print("FACE_SPEAKER is empty, so the whole-face figure is skipped.")
    print("Set it to a team member's speaker ID to include it.")
'''),
    code('''
c = pick(speaker=FACE_SPEAKER) if FACE_SPEAKER else clips[0]
label = f"{c['speaker']}  {c['phrase']}"
p = F.fig_sequence(c["path"], cropper, FIGS, label, cfg)
if p and Path(p).is_file():
    display(Image(str(p)))
'''),
    code('''
p = F.fig_grid(clips, spec, cropper, FIGS, GRID_PHRASES, GRID_SPEAKERS, cfg)
if p and Path(p).is_file():
    display(Image(str(p)))
'''),
    code('''
p = F.fig_motion(clips, spec, cropper, FIGS, cfg=cfg)
if p and Path(p).is_file():
    display(Image(str(p)))
'''),

    md("## 6. The system and the network"),
    code('''
for path in [F.fig_pipeline(FIGS, cfg),
             F.fig_architecture(FIGS, len(spec["phrases"]), cfg)]:
    display(Image(str(path)))
'''),

    md("""
## 7. Results

Read from `results.json`, exactly as the training run wrote it. If the run
has not happened yet, or the model is still at chance, these figures say so
rather than filling in.
"""),
    code('''
res = F.load_results(MODELS)
if res is None:
    print(f"No results.json in {MODELS}.")
    print("Run ANTARVANI_train.ipynb first; the corpus figures above do not")
    print("need it and are already saved.")
else:
    cv = res.get("crossValidation", {})
    top1, chance = cv.get("top1", 0), cv.get("chance", 0.05)
    print(f"top-1 {top1:.1%}   top-3 {cv.get('top3', 0):.1%}   "
          f"chance {chance:.1%}")
    if top1 <= chance * 1.3:
        print()
        print("This model is at chance: it is predicting the same thing for")
        print("every clip. The figures below are drawn anyway and will show")
        print("it plainly - a flat confusion diagonal and per-phrase bars at")
        print("or under the chance line. Fix the model before these go in a")
        print("report; the crop figures in section 5 are where to look first.")
    for path in [F.fig_summary(res, clips, spec, FIGS, cfg),
                 F.fig_training(res, FIGS, cfg),
                 F.fig_folds(res, FIGS, cfg),
                 F.fig_confusion(res, spec, FIGS, cfg),
                 F.fig_per_phrase(res, spec, FIGS, cfg),
                 F.fig_speakers(res, FIGS, cfg),
                 F.fig_personalisation(res, FIGS, cfg)]:
        if path and Path(path).is_file():
            display(Image(str(path)))
'''),

    md("""
## 8. The website

Builds the folder the project site reads: the figures it uses, plus a
`figures.json` holding the corpus counts and — once there is a run — the
headline numbers. Unzip the download into `web/public/data/` and deploy.

The site reads this file rather than being edited: if the run is not there,
or is still at chance, it says so on the page itself.
"""),
    code('''
web_dir = F.export_web(FIGS, clips, spec, res, work / "web_export",
                       cropper=cropper, face_speaker=FACE_SPEAKER, cfg=cfg)

import shutil
from google.colab import files
bundle = shutil.make_archive("/content/antarvani_web_data", "zip", web_dir)
print()
print("Unzip this into web/public/data/ in the app folder, then:")
print("    firebase deploy --only hosting")
files.download(bundle)
'''),

    md("""
## 9. One zip with everything

The archive to keep, and the one to send on: the run's own numbers, every
figure as PNG and PDF, what the website reads, and the corpus counts with a
manifest.

Speakers appear as numbers only — no volunteer's name is anywhere in it.
"""),
    code('''
from google.colab import files

bundle = F.bundle_results(
    figs=FIGS, web=work / "web_export", model_dir=MODELS,
    clips=clips, spec=spec,
    out_zip=str(work / f"ANTARVANI_results_{LANG}"), cfg=cfg)

import zipfile
with zipfile.ZipFile(bundle) as z:
    names = z.namelist()
print()
print(f"{len(names)} files:")
for n in sorted(names):
    print("  ", n)

print()
print(f"Saved in Drive at {bundle}")
print("Downloading a copy too:")
files.download(bundle)
'''),
]

nb = {
    "cells": cells,
    "metadata": {
        "colab": {"provenance": [], "toc_visible": True},
        "kernelspec": {"display_name": "Python 3", "name": "python3"},
        "language_info": {"name": "python"},
    },
    "nbformat": 4,
    "nbformat_minor": 0,
}

OUT.write_text(json.dumps(nb, indent=1, ensure_ascii=False), encoding="utf-8")
print(f"wrote {OUT}  ({len(cells)} cells, "
      f"{OUT.stat().st_size / 1024:.0f} KB)")
