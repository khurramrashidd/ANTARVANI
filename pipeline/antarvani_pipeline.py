#!/usr/bin/env python3
"""
ANTARVANI - corpus in Drive  ->  trained lip-reading model the app downloads.

One language at a time. Everything is derived from what is in the folder, so
adding speakers, takes, phrases or a whole new language needs no code change:
put the videos in Drive, run the notebook again, paste one link in the app.

Stages (each can be called on its own; run_all() chains them):
  1. load_language   find the language's folder and phrase list
  2. scan            list the clips, read speaker / phrase / take from names
  3. preprocess      video -> 48 x 88 x 88 mouth crops, cached, new clips only
  4. cross_validate  leave-speakers-out folds -> honest accuracy
  5. personalise     few-shot prototype study on the held-out speakers
  6. train_final     one model on every clip
  7. export          .tflite + model card (.json) + results + figures
  8. publish_github  optional: upload both files as a GitHub release
"""
from __future__ import annotations

import datetime as _dt
import hashlib
import json
import os
import re
import time
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

# --------------------------------------------------------------- constants
# These four numbers are a contract with the phone. The app reads them from
# the model card and prepares its camera frames the same way, so changing
# them here changes them there on the next model download.
TARGET_FPS = 16.0
WINDOW_S = 3.0
FRAMES = int(round(TARGET_FPS * WINDOW_S))  # 48
CROP = 88
# Crop side, as a multiple of the distance between the outer eye corners,
# centred on the mouth.
#
# This was 1.6, which put the eyes inside the frame: a face crop, not a
# mouth crop. Two things were wrong with that. The lips were about 30x18
# pixels of the 88x88, so most of the resolution went on cheeks; and with
# eyes and face shape in view the network can tell WHO is speaking, which
# is the one shortcut that cannot survive leave-speakers-out - it learns
# the speaker instead of the phrase.
#
# 0.9 frames the mouth from nose-base to chin. The lips take roughly three
# times the area, and there is nothing in frame that identifies a person.
EYE_BOX_SCALE = 0.9
EMB_DIM = 192
VIDEO_EXT = {".mp4", ".mov", ".3gp", ".mkv", ".avi", ".webm"}

EYE_L, EYE_R = 33, 263       # MediaPipe FaceMesh: outer eye corners
LIP_CORNERS = (61, 291)

PHRASE_DIR = re.compile(r"^P(\d{2})(?:_.*)?$")
# S014_P03_t02.mp4  (what the app writes)
APP_NAME = re.compile(r"^(S\d{3,})_(P\d{2})_t(\d+)$", re.IGNORECASE)

# Personalisation blend. Fixed in advance, not tuned on the test speakers.
PERS_ALPHA = 0.5
PERS_TAU = 0.1

HINDI = {
    "code": "hi", "name": "Hindi", "tts": "hi-IN",
    "phrases": [
        ["P01", "मुझे पानी चाहिए", "mujhe paani chahiye", "I need water"],
        ["P02", "दर्द हो रहा है", "dard ho raha hai", "I'm in pain"],
        ["P03", "डॉक्टर को बुलाओ", "doctor ko bulao", "Call the doctor"],
        ["P04", "मुझे भूख लगी है", "mujhe bhookh lagi hai", "I'm hungry"],
        ["P05", "बाथरूम जाना है", "bathroom jaana hai", "I need the toilet"],
        ["P06", "पंखा चालू करो", "pankha chaalu karo", "Turn the fan on"],
        ["P07", "लाइट बंद करो", "light band karo", "Turn the light off"],
        ["P08", "मुझे ठंड लग रही है", "mujhe thand lag rahi hai", "I'm cold"],
        ["P09", "थोड़ा ऊपर उठाओ", "thoda oopar uthao", "Sit me up a bit"],
        ["P10", "दवा का समय हुआ", "dawa ka samay hua", "Time for medicine"],
        ["P11", "मुझे नींद आ रही है", "mujhe neend aa rahi hai", "I'm sleepy"],
        ["P12", "सांस लेने में तकलीफ", "saans lene mein takleef", "Trouble breathing"],
        ["P13", "घर जाना है", "ghar jaana hai", "I want to go home"],
        ["P14", "किसी को बुलाओ", "kisi ko bulao", "Call someone"],
        ["P15", "ठीक है", "theek hai", "Yes / it's fine"],
        ["P16", "नहीं चाहिए", "nahi chahiye", "I don't want it"],
        ["P17", "धन्यवाद", "dhanyavaad", "Thank you"],
        ["P18", "थोड़ा रुको", "thoda ruko", "Wait a moment"],
        ["P19", "खिड़की खोलो", "khidki kholo", "Open the window"],
        ["P20", "चादर ठीक करो", "chaadar theek karo", "Fix the blanket"],
    ],
}


@dataclass
class Config:
    lang: str = "hi"
    corpus_dir: str = ""           # folder holding P01..P20 ('' = find it)
    work_dir: str = ""             # '' = find the shared ANTARVANI_train
    drive_root: str = "/content/drive/MyDrive"
    min_phrases: int = 20   # a speaker trains only once this many phrases
                            # of theirs are in Drive
    folds: int = 5
    epochs: int = 60
    batch: int = 16
    seed: int = 7
    checkpoint: bool = True        # save inside a fold, so a GPU cut-off
                                   # costs an epoch instead of a fold
    allow_cpu: bool = False        # refuse to train without a GPU
    log_every: int = 1             # epochs between progress lines; 0 is off,
                                   # 5 is every fifth. First and last always
                                   # print.
    smoke_test: bool = True        # before training, prove the model can
                                   # memorise a few clips
    stall_epochs: int = 15         # give up on a fold still at chance after
                                   # this many epochs. 0 never gives up.
    patience: int = 6              # stop a fold once training accuracy has
                                   # saturated for this many epochs. 0 runs
                                   # every epoch.
    augment: bool = True           # random zoom, shift, mirror, lighting and
                                   # time-slide. Off only for diagnosis.
    crop_scale: float = EYE_BOX_SCALE   # how tight the mouth crop is. The
                                   # cache key includes it, so changing it
                                   # re-crops rather than silently reusing
                                   # the old frames.
    account: str = ""              # which Google account is running this
    github_repo: str = ""          # "user/repo" - '' = do not upload
    github_token: str = ""
    notes: str = ""
    log: list = field(default_factory=list)

    def say(self, *a):
        line = " ".join(str(x) for x in a)
        self.log.append(line)
        print(line)


# ------------------------------------------------------------ 1. language
def find_corpus(drive_root: str) -> str | None:
    """The folder that holds P01, P02 ... Looks three levels deep."""
    root = Path(drive_root)
    if not root.is_dir():
        return None
    best, best_n = None, 0
    level = [root]
    for _ in range(3):
        nxt = []
        for d in level:
            try:
                subs = [p for p in d.iterdir() if p.is_dir()]
            except OSError:
                continue
            n = sum(1 for p in subs if PHRASE_DIR.match(p.name))
            if n > best_n:
                best, best_n = d, n
            nxt += [p for p in subs if not p.name.startswith((".", "_"))
                    and not PHRASE_DIR.match(p.name)]
        level = nxt
    return str(best) if best_n >= 3 else None


def load_language(cfg: Config):
    """Returns (folder holding the P.. folders, language dict).

    Hindi sits directly in the corpus folder, because that is where the first
    recordings went. Every later language gets its own sub-folder, lang_<code>,
    which the app creates together with a phrases.json describing it.
    """
    corpus = cfg.corpus_dir
    if corpus and not Path(corpus).is_dir():
        # The same shared folder sits at a different path in each account's
        # Drive. A path typed for one account is a hint, not a failure.
        cfg.say(f"note: {corpus} is not in this Drive - looking for the "
                "corpus folder instead")
        corpus = ""
    if not corpus:
        corpus = find_named(cfg.drive_root, "ANTARVANI") or \
            find_corpus(cfg.drive_root)
    if not corpus or not Path(corpus).is_dir():
        raise SystemExit(
            "Could not find the corpus folder (the one holding P01, P02 ...).\n"
            "Set CORPUS_DIR at the top of the notebook to its full path, e.g.\n"
            "  /content/drive/MyDrive/Silent_Voice")
    corpus = Path(corpus)

    # The work folder must not sit inside the corpus folder: the cache would
    # then be mixed in with the recordings, and a later scan could try to
    # read its own output.
    work = Path(cfg.work_dir)
    if work.resolve() == corpus.resolve() or corpus.resolve() in work.resolve().parents:
        raise SystemExit(
            f"WORK_DIR ({work}) is inside the corpus folder ({corpus}).\n"
            "Give WORK_DIR a folder of its own, e.g.\n"
            f"  WORK_DIR = \"{corpus.parent / 'ANTARVANI_train'}\"")

    if cfg.lang == "hi":
        root, spec = corpus, HINDI
        pj = corpus / "phrases.json"
    else:
        root = corpus / f"lang_{cfg.lang}"
        pj = root / "phrases.json"
        spec = None
        if not root.is_dir():
            have = sorted(p.name[5:] for p in corpus.iterdir()
                          if p.is_dir() and p.name.startswith("lang_"))
            raise SystemExit(
                f"No folder lang_{cfg.lang} in {corpus}.\n"
                f"Languages present: hi{''.join(', ' + h for h in have)}.\n"
                "Add the language in the app first (Corpus > Languages).")
    if pj.is_file():
        spec = json.loads(pj.read_text(encoding="utf-8"))
    if spec is None:
        raise SystemExit(f"{pj} is missing - it lists the phrases for "
                         f"'{cfg.lang}'. The app writes it when the language "
                         "is added.")
    spec = normalise_language(spec, cfg.lang)
    cfg.say(f"language : {spec['name']} ({spec['code']}), "
            f"{len(spec['phrases'])} phrases")
    cfg.say(f"folder   : {root}")
    return str(root), spec


def normalise_language(spec: dict, code: str | None = None) -> dict:
    """Accepts phrases as [id, text, roman, english] rows or as dicts."""
    out = {"code": (spec.get("code") or code or "").strip().lower(),
           "name": spec.get("name") or code,
           "tts": spec.get("tts") or f"{code}-IN",
           "phrases": []}
    for i, p in enumerate(spec.get("phrases", [])):
        if isinstance(p, dict):
            row = [p.get("id"), p.get("text") or p.get("native"),
                   p.get("roman", ""), p.get("english", "")]
        else:
            row = list(p) + [""] * (4 - len(p))
        want = f"P{i + 1:02d}"
        if row[0] != want:
            raise SystemExit(f"phrases must be numbered in order: expected "
                             f"{want}, found {row[0]!r}")
        if not row[1]:
            raise SystemExit(f"{want} has no text")
        out["phrases"].append({"id": row[0], "text": row[1],
                               "roman": row[2] or "", "english": row[3] or ""})
    if not 2 <= len(out["phrases"]) <= 99:
        raise SystemExit("a language needs between 2 and 99 phrases")
    return out


# ---------------------------------------------- the same folders, any account
def find_named(drive_root: str, name: str, depth: int = 3) -> str | None:
    """Finds a folder by name anywhere near the top of this Drive.

    Four accounts share one corpus and one work folder, and a shared folder
    sits at a different path in each account's Drive depending on where the
    shortcut was added. So nothing is hardcoded: the folder is looked up by
    name, wherever the person put it.
    """
    root = Path(drive_root)
    if not root.is_dir():
        return None
    level = [root]
    for _ in range(depth):
        nxt = []
        for d in level:
            try:
                subs = [x for x in d.iterdir() if x.is_dir()]
            except OSError:
                continue
            for x in subs:
                if x.name == name:
                    return str(x)
            nxt += [x for x in subs if not x.name.startswith((".", "_"))]
        level = nxt
    return None


def resolve_work_dir(cfg: Config, corpus: Path) -> Path:
    """Where this run keeps its cache, its finished folds and its models.

    This must be the *same* folder for every account, or account two starts
    from nothing instead of carrying on. So an existing folder is always
    preferred over making a new one, and a new one says loudly that it is new.
    """
    if cfg.work_dir:
        work = Path(cfg.work_dir)
        work.mkdir(parents=True, exist_ok=True)
    else:
        found = find_named(cfg.drive_root, "ANTARVANI_train")
        if found:
            work = Path(found)
        else:
            work = Path(cfg.drive_root) / "ANTARVANI_train"
            work.mkdir(parents=True, exist_ok=True)
            cfg.say("")
            cfg.say("NOTE: no shared ANTARVANI_train folder was found in this")
            cfg.say(f"Drive, so a new one was made at {work}.")
            cfg.say("If the other accounts already have one, stop now, add a")
            cfg.say("shortcut to it, and run again - otherwise this account")
            cfg.say("will train from scratch instead of carrying on.")
        cfg.work_dir = str(work)

    # A stamp that is written once and never changes. Every account prints
    # it, so one glance says whether they really are sharing a folder.
    stamp = work / "work_id.json"
    if stamp.is_file():
        try:
            wid = json.loads(stamp.read_text(encoding="utf-8")).get("id", "?")
        except Exception:
            wid = "?"
    else:
        wid = hashlib.md5(
            f"{datetime_now()}{work}".encode()).hexdigest()[:8]
        stamp.write_text(json.dumps({"id": wid, "madeBy": cfg.account,
                                     "madeAt": datetime_now()}, indent=1),
                         encoding="utf-8")
    cfg.say(f"work     : {work}")
    cfg.say(f"work id  : {wid}   (must be the same on every account)")
    return work


def datetime_now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


# ------------------------------------------------------------------ the GPU
def gpu_present() -> bool:
    try:
        import tensorflow as tf
        return bool(tf.config.list_physical_devices("GPU"))
    except Exception:
        return False


def require_gpu(cfg: Config, where: str = "") -> None:
    """Stops rather than grinding through hours of CPU training.

    When Colab's free GPU allowance runs out it hands back a CPU runtime
    instead of refusing outright. Training would still 'work' - perhaps
    fifteen times slower - and the first sign would be an evening gone. So
    the GPU is checked before the first fold and before every fold after it.
    """
    if cfg.allow_cpu or gpu_present():
        return
    cfg.say("")
    cfg.say("=" * 64)
    cfg.say("NO GPU AVAILABLE" + (f" ({where})" if where else ""))
    cfg.say("")
    cfg.say("Colab hands back a CPU runtime once the free GPU allowance is")
    cfg.say("used up. Training on it would take most of a day, so it stops")
    cfg.say("here instead. Everything finished so far is saved in Drive.")
    cfg.say("")
    cfg.say("Either try Runtime > Change runtime type > T4 GPU, or open this")
    cfg.say("notebook from your next Google account and Run all - it will")
    cfg.say("carry on from exactly this point.")
    cfg.say("=" * 64)
    raise SystemExit("No GPU - switch accounts and run again.")


# ------------------------------------------------- one account at a time
LOCK_STALE = 40 * 60   # seconds


def _lock_file(resume: Path) -> Path:
    return resume / "lock.json"


def claim_lock(resume: Path, cfg: Config, force: bool = False) -> None:
    """Stops two accounts training the same thing at once.

    Both would write the same fold files, and whichever finished last would
    win - wasting a whole session's GPU for nothing.
    """
    import socket
    me = cfg.account or socket.gethostname()
    f = _lock_file(resume)
    if f.is_file() and not force:
        try:
            held = json.loads(f.read_text(encoding="utf-8"))
        except Exception:
            held = {}
        age = time.time() - float(held.get("at", 0))
        if held.get("by") and held.get("by") != me and age < LOCK_STALE:
            mins = int(age // 60)
            raise SystemExit(
                f"Another account ({held['by']}) started training {mins} "
                f"minute(s) ago.\nWait for it to finish, or if you are sure "
                "it has stopped, set FORCE = True in the settings cell.")
    f.write_text(json.dumps({"by": me, "at": time.time(),
                             "since": datetime_now()}, indent=1),
                 encoding="utf-8")


def touch_lock(resume: Path, cfg: Config) -> None:
    import socket
    try:
        _lock_file(resume).write_text(
            json.dumps({"by": cfg.account or socket.gethostname(),
                        "at": time.time(), "since": datetime_now()},
                       indent=1), encoding="utf-8")
    except Exception:
        pass


def release_lock(resume: Path) -> None:
    try:
        _lock_file(resume).unlink(missing_ok=True)
    except Exception:
        pass


# ----------------------------------------------------------------- 2. scan
SKIP_FILE = "_skip_speakers.txt"
HOLDING_DIR = "_in_progress"


def skip_list(root: str, cfg: Config) -> set[str]:
    """Speakers the app has marked rejected, read from _skip_speakers.txt.

    A rejection has to take effect without anything being moved: the videos
    may belong to a collector who is not around to move them, and waiting on
    that would mean training on a session the master admin has thrown out.
    So the app writes the IDs here and this is the list that decides.
    """
    # Speaker numbers are shared across languages, so the app writes one
    # list at the top of the corpus folder. For Hindi that is this folder;
    # for a lang_xx folder it is the one above.
    here = Path(root)
    f = next((p for p in (here / SKIP_FILE, here.parent / SKIP_FILE)
              if p.is_file()), None)
    if f is None:
        return set()
    out = set()
    for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.split("#", 1)[0].strip().upper()
        if line:
            out.add(line)
    if out:
        cfg.say(f"skip list: {len(out)} rejected speaker(s) left out "
                f"({', '.join(sorted(out)[:8])}"
                f"{'...' if len(out) > 8 else ''})")
    return out


def holding_count(root: str) -> int:
    """Clips parked in _in_progress because their session is unfinished."""
    d = Path(root) / HOLDING_DIR
    if not d.is_dir():
        return 0
    return sum(1 for f in d.rglob("*") if f.suffix.lower() in VIDEO_EXT)


def scan(root: str, spec: dict, cfg: Config) -> list[dict]:
    """Every usable clip. Folders that are not P01..Pnn (_rejected, _deleted,
    _in_progress, lang_xx, anything else) are ignored, so rejected and
    half-recorded speakers never train."""
    n = len(spec["phrases"])
    clips, odd = [], []
    for d in sorted(p for p in Path(root).iterdir() if p.is_dir()):
        m = PHRASE_DIR.match(d.name)
        if not m:
            if re.match(r"^PO\d", d.name, re.IGNORECASE):
                raise SystemExit(f"Folder {d.name!r} uses the letter O, not "
                                 f"the digit 0. Rename it to P0{d.name[2:]}.")
            continue
        idx = int(m.group(1))
        if not 1 <= idx <= n:
            cfg.say(f"note: {d.name} is outside P01..P{n:02d} - ignored")
            continue
        pid = f"P{idx:02d}"
        for f in sorted(d.iterdir()):
            if f.suffix.lower() not in VIDEO_EXT:
                continue
            a = APP_NAME.match(f.stem)
            if a and a.group(2).upper() == pid:
                speaker, take = a.group(1).upper(), int(a.group(3))
            else:
                # Put in Drive by hand and never imported through the app.
                # Each such file counts as its own speaker, which is the safe
                # assumption: it can never leak between train and test.
                speaker, take = "X" + hashlib.md5(
                    f.stem.encode()).hexdigest()[:6], 1
                odd.append(f.name)
            st = f.stat()
            clips.append({
                "path": str(f), "name": f.name, "phrase": pid,
                "label": idx - 1, "speaker": speaker, "take": take,
                # The geometry is part of the identity of a cached crop.
                # Without it, changing the crop scale would reuse frames cut
                # to the old one and the change would appear to do nothing.
                "key": hashlib.md5(
                    f"{pid}/{f.name}/{st.st_size}/{CROP}/{cfg.crop_scale:.3f}"
                    .encode()).hexdigest()[:16],
            })
    if odd:
        cfg.say(f"note: {len(odd)} file(s) are not named by the app "
                f"(e.g. {odd[0]}). Import them in the app (Corpus > Import) "
                "so they get a speaker number.")

    skip = skip_list(root, cfg)
    if skip:
        before = len(clips)
        clips = [c for c in clips if c["speaker"].upper() not in skip]
        dropped = before - len(clips)
        if dropped:
            cfg.say(f"skip list: {dropped} clip(s) left out of training")

    waiting = holding_count(root)
    if waiting:
        cfg.say(f"note: {waiting} clip(s) sit in {HOLDING_DIR}/ and are NOT "
                "trained on - those sessions are unfinished. If one of them "
                "is finished, open the app and use the \"Clips in the wrong "
                "folder\" card to move them in.")
    return clips


def select_speakers(clips: list[dict], spec: dict, cfg: Config):
    """Keeps only the speakers whose set is complete enough to train on.

    A half-recorded speaker is not neutral: their missing phrases pull those
    classes down and their present ones are over-weighted, so a speaker with
    six phrases in Drive makes the model worse at the other fourteen. The
    clips are not thrown away — they are simply not used until the rest of
    that session reaches Drive, which it will as soon as the collector
    uploads.

    Returns (clips to train on, a record of who was used and who was not).
    """
    ids = [p["id"] for p in spec["phrases"]]
    n = len(ids)
    want = min(max(1, cfg.min_phrases), n)

    by = defaultdict(list)
    for c in clips:
        by[c["speaker"]].append(c)

    kept, used, skipped = [], [], []
    for sp in sorted(by):
        cs = by[sp]
        have = {c["phrase"] for c in cs}
        missing = [i for i in ids if i not in have]
        row = {"speaker": sp, "clips": len(cs), "phrases": len(have),
               "missing": missing}
        if len(have) >= want:
            used.append(row)
            kept.extend(cs)
        else:
            skipped.append(row)

    cfg.say("")
    cfg.say(f"speakers with at least {want} of {n} phrases in Drive: "
            f"{len(used)}  -> training on these")
    for r in used:
        short = (f"  (missing {', '.join(r['missing'])})"
                 if r["missing"] else "")
        cfg.say(f"  {r['speaker']}  {r['clips']:4d} clips  "
                f"{r['phrases']}/{n} phrases{short}")

    if skipped:
        cfg.say("")
        cfg.say(f"speakers skipped, not enough in Drive yet: {len(skipped)}")
        for r in skipped:
            miss = ", ".join(r["missing"][:8])
            more = " …" if len(r["missing"]) > 8 else ""
            cfg.say(f"  {r['speaker']}  {r['clips']:4d} clips  "
                    f"{r['phrases']}/{n} phrases  missing {miss}{more}")
        cfg.say("")
        cfg.say("  Those clips exist on somebody's phone. In the app: "
                "Collect data >")
        cfg.say("  Progress & uploads > Collectors shows whose phone, and "
                "lets you nudge them.")
        cfg.say("  They join training by themselves on the next run once "
                "they reach Drive.")

    if not kept:
        raise SystemExit(
            f"No speaker has {want} of {n} phrases in Drive yet, so there is "
            "nothing to train on.\nEither wait for the uploads, or lower "
            "MIN_PHRASES in the settings cell.")

    roster = {"minPhrases": want, "phraseCount": n,
              "used": used, "skipped": skipped,
              "speakerIds": [r["speaker"] for r in used]}
    return kept, roster


def describe(clips: list[dict], spec: dict, cfg: Config) -> dict:
    by_s = defaultdict(list)
    for c in clips:
        by_s[c["speaker"]].append(c)
    per_phrase = Counter(c["phrase"] for c in clips)
    multi = [s for s, cs in by_s.items()
             if max(Counter(c["phrase"] for c in cs).values()) >= 2]

    cfg.say("")
    cfg.say(f"TOTAL clips    : {len(clips)}")
    cfg.say(f"TOTAL speakers : {len(by_s)}  ({len(multi)} with repeated takes)")
    cfg.say(f"TOTAL phrases  : {len(spec['phrases'])}")

    cfg.say("")
    cfg.say("clips per phrase")
    for p in spec["phrases"]:
        n = per_phrase[p["id"]]
        who = len({c["speaker"] for c in clips if c["phrase"] == p["id"]})
        bar = "#" * min(n, 40)
        flag = "   <-- NONE" if n == 0 else ""
        cfg.say(f"  {p['id']}  {n:4d} clips  {who:3d} speakers  {bar}{flag}")

    cfg.say("")
    cfg.say("clips per speaker")
    for sp in sorted(by_s):
        cs = by_s[sp]
        takes = Counter(c["phrase"] for c in cs)
        cfg.say(f"  {sp}  {len(cs):4d} clips  {len(takes):3d} phrases  "
                f"up to {max(takes.values())} takes each")

    missing = [p["id"] for p in spec["phrases"] if per_phrase[p["id"]] == 0]
    if missing:
        cfg.say("")
        cfg.say(f"WARNING  : no clips at all for {', '.join(missing)} - the "
                "model cannot learn a phrase it has never seen")
    lo = min((per_phrase[p["id"]] for p in spec["phrases"]), default=0)
    hi = max(per_phrase.values(), default=0)
    cfg.say(f"per phrase: {lo} to {hi} clips")
    cfg.say("")
    return {"clips": len(clips), "speakers": len(by_s),
            "multiTakeSpeakers": len(multi), "missingPhrases": missing,
            "perPhrase": {p["id"]: per_phrase[p["id"]]
                          for p in spec["phrases"]}}


# ------------------------------------------------- surviving a hard stop
def save_npz(path: Path, **arrays) -> None:
    """Writes a .npz so that a killed session cannot leave a half file.

    Colab does not warn before it stops a runtime. A file being written at
    that moment is left truncated, and numpy raises on it the next run — so
    the work looks finished but cannot be read. Writing to a temporary name
    and renaming afterwards means the real name only ever appears complete.
    """
    # The suffix has to stay .npz: numpy appends .npz to any savez path
    # that does not already end in it, and the rename below would then look
    # for a file that was never written.
    tmp = path.with_name(path.name + ".part.npz")
    np.savez_compressed(tmp, **arrays)
    try:
        os.replace(tmp, path)
    except OSError:
        # Some mounted filesystems refuse rename; fall back to a copy.
        import shutil
        shutil.copyfile(tmp, path)
        tmp.unlink(missing_ok=True)


def save_text(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".part")
    tmp.write_text(text, encoding="utf-8")
    try:
        os.replace(tmp, path)
    except OSError:
        path.write_text(text, encoding="utf-8")
        tmp.unlink(missing_ok=True)


def readable_npz(path: Path) -> bool:
    """True if the file is whole. Opening is not enough — the array has to
    come out, because a truncated archive only fails on decompression."""
    try:
        with np.load(path) as z:
            return z["x"].shape[0] > 0
    except Exception:
        return False


def health_check(cfg: Config) -> None:
    """Fails now, with a sentence, rather than in an hour with a stack trace."""
    work = Path(cfg.work_dir)
    try:
        work.mkdir(parents=True, exist_ok=True)
        probe = work / ".write_test"
        probe.write_text("ok", encoding="utf-8")
        got = probe.read_text(encoding="utf-8")
        probe.unlink(missing_ok=True)
        if got != "ok":
            raise OSError("read back the wrong thing")
    except Exception as e:
        raise SystemExit(
            f"Cannot write to the work folder ({work}): {e}\n"
            "Either Drive is not mounted, or this account only has view "
            "access to the shared folder. Re-run the Drive mount cell, and "
            "check the folder is shared with this account as Editor.")


# ------------------------------------------------------- what to do now
def plan_banner(cfg: Config, clips_total: int = 0) -> None:
    """Says, in plain words, whether this runtime is the right one, and what
    a restart would and would not cost."""
    cache = Path(cfg.work_dir) / "cache" / cfg.lang
    cached = len(list(cache.glob("*.npz"))) if cache.is_dir() else 0
    base = Path(cfg.work_dir) / "resume" / cfg.lang
    folds, final = set(), False
    if base.is_dir():
        for d in base.iterdir():
            if d.is_dir():
                folds |= {x.name for x in d.glob("fold*.npz")}
                final = final or (d / "final.weights.h5").is_file()
    gpu = gpu_present()

    print()
    print("=" * 66)
    print("WHAT TO DO NOW")
    print("=" * 66)
    print(f"This runtime has: {'a GPU' if gpu else 'NO GPU (CPU only)'}")
    print()
    print("  Cropping the videos  ->  CPU is fine, and it spends none of")
    print("                           your GPU allowance")
    print("  Training the model   ->  needs a GPU; on CPU it takes about")
    print("                           fifteen times longer")
    print()
    if clips_total:
        print(f"  clips to crop   : {cached} of {clips_total} already done")
    else:
        print(f"  clips cropped   : {cached}")
    print(f"  folds trained   : {len(folds)}"
          f"{' (final model also done)' if final else ''}")
    print()
    print("Switching the runtime type RESTARTS the machine and empties")
    print("/content. That is safe. Nothing slow is kept there:")
    print()
    print(f"    {cfg.work_dir}")
    print()
    print("holds the crops, every finished fold and a checkpoint inside the")
    print("fold being trained, and all of it is written as it finishes. On")
    print("the next run each of those is read back, so no crop and no fold")
    print("is ever done twice. The most a hard stop costs you is the epochs")
    print("since the last checkpoint.")
    print()
    if not gpu and cached < max(clips_total, 1):
        print("NEXT: leave CROP_ONLY = True and Run all. Cropping does not")
        print("      need a GPU. Switch to T4 afterwards for the training.")
    elif not gpu:
        print("NEXT: Runtime > Change runtime type > T4 GPU, then Run all.")
        print("      If Colab will not give one, this account's allowance is")
        print("      used up - open this notebook from the next account and")
        print("      Run all. It carries on from the numbers above.")
    else:
        print("NEXT: Run all. Training will start, or carry on, on this GPU.")
    print("=" * 66)
    print()


# ----------------------------------------------------------- 3. preprocess
FACE_MODEL_URL = ("https://storage.googleapis.com/mediapipe-models/"
                  "face_landmarker/face_landmarker/float16/1/"
                  "face_landmarker.task")


class LipCropper:
    """Eye-aligned, face-size-normalised mouth crop.

    Uses MediaPipe's FaceLandmarker (the current API; its landmark numbering
    is the same 468-point mesh). Older MediaPipe builds that still ship the
    legacy FaceMesh are used as a fallback.
    """

    def __init__(self, model_dir: str = "/content"):
        import mediapipe as mp
        self.mp = mp
        self.task = self.mesh = None
        try:
            from mediapipe.tasks import python as mp_python
            from mediapipe.tasks.python import vision
            path = Path(model_dir) / "face_landmarker.task"
            if not path.is_file() or path.stat().st_size < 100_000:
                import urllib.request
                path.parent.mkdir(parents=True, exist_ok=True)
                urllib.request.urlretrieve(FACE_MODEL_URL, str(path))
            self.task = vision.FaceLandmarker.create_from_options(
                vision.FaceLandmarkerOptions(
                    base_options=mp_python.BaseOptions(
                        model_asset_path=str(path)),
                    running_mode=vision.RunningMode.IMAGE, num_faces=1,
                    min_face_detection_confidence=0.5))
        except Exception as e:
            if not hasattr(mp, "solutions"):
                raise SystemExit(f"Could not start the face landmarker: {e}")
            self.mesh = mp.solutions.face_mesh.FaceMesh(
                static_image_mode=False, max_num_faces=1,
                refine_landmarks=False, min_detection_confidence=0.5,
                min_tracking_confidence=0.5)

    def _landmarks(self, rgb):
        if self.task is not None:
            res = self.task.detect(self.mp.Image(
                image_format=self.mp.ImageFormat.SRGB,
                data=np.ascontiguousarray(rgb)))
            return res.face_landmarks[0] if res.face_landmarks else None
        res = self.mesh.process(rgb)
        return (res.multi_face_landmarks[0].landmark
                if res.multi_face_landmarks else None)

    def crop(self, bgr, box_scale: float = EYE_BOX_SCALE):
        import cv2
        h, w = bgr.shape[:2]
        lm = self._landmarks(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))
        if lm is None:
            return None

        def pt(i):
            return np.array([lm[i].x * w, lm[i].y * h], np.float32)

        eye_l, eye_r = pt(EYE_L), pt(EYE_R)
        mouth = (pt(LIP_CORNERS[0]) + pt(LIP_CORNERS[1])) / 2.0
        d = eye_r - eye_l
        angle = float(np.degrees(np.arctan2(d[1], d[0])))
        box = (float(np.linalg.norm(d)) or 1.0) * box_scale
        M = cv2.getRotationMatrix2D((float(mouth[0]), float(mouth[1])),
                                    angle, CROP / box)
        M[0, 2] += CROP / 2 - mouth[0]
        M[1, 2] += CROP / 2 - mouth[1]
        out = cv2.warpAffine(bgr, M, (CROP, CROP), flags=cv2.INTER_LINEAR)
        return cv2.cvtColor(out, cv2.COLOR_BGR2GRAY)


def sample_indices(n_frames: int, src_fps: float) -> list[int]:
    """Fixed rate over a fixed window: real speaking speed is kept. A short
    clip holds its last frame; a long one is cut at the window."""
    if n_frames == 0 or src_fps <= 0:
        return []
    return [min(int(round((i / TARGET_FPS) * src_fps)), n_frames - 1)
            for i in range(FRAMES)]


def process_clip(path: str, cropper: LipCropper,
                 box_scale: float = EYE_BOX_SCALE):
    import cv2
    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        return None, "cannot open"
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    if not 5 <= fps <= 240:
        fps = 30.0
    frames = []
    while True:
        ok, f = cap.read()
        if not ok:
            break
        frames.append(f)
    cap.release()
    if not frames:
        return None, "no frames"
    if len(frames) / fps < 1.2:
        return None, f"only {len(frames) / fps:.1f}s long"
    crops, hits, seen = [], 0, {}
    for i in sample_indices(len(frames), fps):
        if i not in seen:
            seen[i] = cropper.crop(frames[i], box_scale)
        c = seen[i]
        if c is not None:
            hits += 1
            crops.append(c)
        else:
            crops.append(crops[-1] if crops
                         else np.zeros((CROP, CROP), np.uint8))
    if hits / FRAMES < 0.6:
        return None, f"face found in only {hits / FRAMES:.0%} of frames"
    return np.stack(crops), None


def preprocess(clips: list[dict], cache_dir: str, cfg: Config) -> list[dict]:
    """Fills the cache for clips it has not seen. Returns the usable clips.
    The cache lives on Drive, so a second run only touches new videos."""
    cache = Path(cache_dir)
    cache.mkdir(parents=True, exist_ok=True)
    bad_file = cache / "_skipped.json"
    bad = json.loads(bad_file.read_text()) if bad_file.is_file() else {}
    todo = [c for c in clips
            if not (cache / f"{c['key']}.npz").is_file() and c["key"] not in bad]
    cfg.say(f"preprocess: {len(clips) - len(todo)} cached, {len(todo)} new")
    if todo:
        cropper = LipCropper(str(Path(cache_dir).parent))
        for n, c in enumerate(todo, 1):
            arr, err = process_clip(c["path"], cropper, cfg.crop_scale)
            if err:
                bad[c["key"]] = {"name": c["name"], "why": err}
                cfg.say(f"  skip {c['phrase']}/{c['name']}: {err}")
            else:
                save_npz(cache / f"{c['key']}.npz", x=arr)
            if n % 25 == 0 or n == len(todo):
                print(f"  {n}/{len(todo)}")
                save_text(bad_file, json.dumps(bad, indent=1))
        save_text(bad_file, json.dumps(bad, indent=1))
    # A session killed during a write leaves a file that exists but cannot
    # be read. Catch that here, where it can still be fixed, rather than an
    # hour later in the middle of training.
    good = [c for c in clips if (cache / f"{c['key']}.npz").is_file()]
    broken = [c for c in good if not readable_npz(cache / f"{c['key']}.npz")]
    if broken:
        cfg.say(f"{len(broken)} cached clip(s) were damaged by an interrupted "
                "run - cropping them again")
        cropper = LipCropper(str(Path(cache_dir).parent))
        for c in broken:
            (cache / f"{c['key']}.npz").unlink(missing_ok=True)
            arr, err = process_clip(c["path"], cropper, cfg.crop_scale)
            if err:
                bad[c["key"]] = {"name": c["name"], "why": err}
            else:
                save_npz(cache / f"{c['key']}.npz", x=arr)
        save_text(bad_file, json.dumps(bad, indent=1))
        good = [c for c in clips if (cache / f"{c['key']}.npz").is_file()
                and c["key"] not in bad]

    skipped = [bad[c["key"]] for c in clips if c["key"] in bad]
    if skipped:
        cfg.say(f"{len(skipped)} clip(s) unusable (no face / too short). "
                "Reject them in the app so they stop counting.")
    return good


# --------------------------------------------- 3b. look before you train
#
# Two runs were lost to faults that a thirty-second look at the data would
# have caught: an augmentation that replaced every clip with 48 copies of
# its first frame, and before that a face detector that never ran. Both
# produced the same thing on screen - a loss sitting at ln(n_classes) for
# an hour - and neither was visible from the training log.
#
# So nothing trains now until the data has been looked at, measured, and
# shown to be learnable. The checks below are cheap, they run before the
# GPU does any real work, and each one stops the run with the reason
# rather than letting it burn an hour to arrive at chance.

# A clip whose frames are literally identical has motion 0.00. Anything
# above this is real movement, however small. An absolute "healthy" level
# is NOT set here on purpose: how much a mouth crop changes between frames
# depends on the crop size, the frame rate and the speaker, and a number
# guessed here would eventually stop a perfectly good corpus. The checks
# that can fail are the ones with no free parameter - identical frames,
# a blank cache, augmentation that removes movement that was there, and a
# model that cannot memorise forty clips.
STILL_EPS = 0.02      # below this a clip is frozen, not merely calm
FLAT_CLIP_MAX = 0.10  # share of frozen clips tolerated


class PreflightError(RuntimeError):
    """The data cannot be learned from. Raised before training starts."""


def clip_motion(X: np.ndarray) -> np.ndarray:
    """Mean frame-to-frame change per clip, on the 0-255 scale.

    This is the number that matters for lip reading: a clip with no motion
    carries no phrase, however sharp each individual frame looks.
    """
    return np.abs(np.diff(X.astype(np.int16), axis=1)).mean(axis=(1, 2, 3))


def check_data(X, y, g, n_classes: int, cfg: Config) -> dict:
    """What is actually in the cache, and whether it could teach anything."""
    motion = clip_motion(X)
    flat = int((motion < STILL_EPS).sum())
    per_clip_std = X.reshape(len(X), -1).std(axis=1)
    counts = np.bincount(y, minlength=n_classes)

    cfg.say("")
    cfg.say("data going into training")
    cfg.say(f"  shape        {X.shape}  {X.dtype}")
    cfg.say(f"  pixel range  {X.min()}-{X.max()}   mean {X.mean():.1f}")
    cfg.say(f"  per-clip std {per_clip_std.min():.1f} to "
            f"{per_clip_std.max():.1f}  (0 means a blank clip)")
    cfg.say(f"  motion       {motion.min():.2f} to {motion.max():.2f}, "
            f"median {np.median(motion):.2f}")
    cfg.say(f"  frozen clips {flat} of {len(X)} (identical frames)")
    cfg.say(f"  classes      {counts.min()} to {counts.max()} clips each")
    cfg.say(f"  speakers     {len(set(g.tolist()))}")

    if X.max() == X.min():
        raise PreflightError("every pixel of every clip is the same value - "
                             "the cache is blank. Delete the cache folder "
                             "and let it rebuild.")
    if flat > FLAT_CLIP_MAX * len(X):
        raise PreflightError(
            f"{flat} of {len(X)} clips are frozen - every frame identical "
            f"({100 * flat / len(X):.0f}%). A still clip carries no phrase. "
            "Either the face detector locked onto something that is not a "
            "mouth, or the cache was written by a broken run: delete "
            "<work>/cache/<lang> and let it rebuild.")
    if counts.min() == 0:
        missing = [i for i, c in enumerate(counts) if c == 0]
        raise PreflightError(f"no clips at all for class(es) {missing}")

    return {"motion": float(np.median(motion)), "stillClips": flat,
            "pixelMin": int(X.min()), "pixelMax": int(X.max())}


def check_augmentation(X, n_classes: int, cfg: Config) -> None:
    """Does a clip still move after augmentation?

    The exact fault that cost a day: crop_and_resize was cutting all 48
    boxes out of frame 0, so every augmented clip was a still picture
    while the cached data it came from was perfectly fine. Measuring
    motion before and against after is the one check that sees it.
    """
    import tensorflow as tf

    fn = _augment(n_classes)
    take = min(8, len(X))
    before, after = [], []
    for i in np.linspace(0, len(X) - 1, take, dtype=int):
        raw = X[i]
        aug = fn(tf.constant(raw), tf.constant(np.int32(0)))[0].numpy()
        before.append(clip_motion(raw[None])[0])
        after.append(clip_motion((aug[..., 0] * 255).astype(np.uint8)[None])[0])

    b, a = float(np.mean(before)), float(np.mean(after))
    cfg.say(f"  augmentation motion {b:.2f} before -> {a:.2f} after")
    if b > STILL_EPS and a < 0.5 * b:
        raise PreflightError(
            f"augmentation is destroying the movement in the clips "
            f"(motion {b:.2f} -> {a:.2f}). The model would be trained on "
            "stills. Check _augment before going further.")


def can_it_learn(X, y, n_classes: int, cfg: Config,
                 per_class: int = 2, epochs: int = 150) -> float:
    """Is the model moving at all on a handful of clips?

    This test exists to catch one failure, the one that actually
    happened: every fold pinned at a loss of exactly ln(n_classes) for
    sixty epochs, because the augmentation was handing the model 48
    copies of frame 0 and every class looked identical. That signature is
    unmistakable - nothing moves, ever - and it costs two minutes to find
    instead of an hour.

    It is NOT a measure of how well the model will do. An earlier version
    judged a fixed accuracy at epoch 25, which on 40 clips at batch 16 is
    75 gradient updates: far too few for a 1.77 M parameter network to
    memorise twenty classes, so it failed healthy data. The real run gets
    twenty times as many updates. The lesson: give the test enough steps
    to be meaningful, then judge movement rather than a threshold, and
    when it is unsure let the full run proceed - a false alarm costs a
    whole GPU session, a slow learner costs nothing but the hour you were
    going to spend anyway.

    Returns the best training accuracy seen, or nan if skipped.
    """
    idx = []
    for c in range(n_classes):
        have = np.where(y == c)[0]
        idx.extend(have[:per_class].tolist())
    idx = np.array(idx)
    if len(idx) < n_classes:
        cfg.say("  (too few clips for the memorisation test; skipped)")
        return float("nan")

    chance = 1.0 / n_classes
    uniform = float(np.log(n_classes))   # loss of a model that knows nothing

    # Small batches on purpose: 40 clips at batch 8 is 5 updates an epoch,
    # so 150 epochs is 750 - enough that reaching chance means something.
    steps = int(np.ceil(len(idx) / 8)) * epochs
    cfg.say("")
    cfg.say(f"movement test: {len(idx)} clips, {epochs} epochs, "
            f"{steps} gradient updates")
    cfg.say(f"  looking for any movement off chance ({chance:.1%}) and below "
            f"a loss of {uniform:.3f}")

    def run(augment: bool, tag: str) -> tuple[float, float]:
        quiet = Config(**{**cfg.__dict__, "epochs": epochs, "batch": 8,
                          "checkpoint": False, "augment": augment,
                          "stall_epochs": 0, "patience": 0,
                          "log_every": max(10, epochs // 5)})
        quiet.say = cfg.say
        _, _, hist = fit(X[idx], y[idx], n_classes, quiet, seed=cfg.seed,
                         label=f"  {tag}")
        acc = max(hist.get("accuracy", [0.0]))
        loss = min(hist.get("loss", [uniform * 2]))
        return float(acc), float(loss)

    plain_acc, plain_loss = run(False, "plain   ")
    cfg.say(f"  without augmentation: best acc {plain_acc:.1%}, "
            f"best loss {plain_loss:.3f}")

    # Run the augmented pass for information only. On 40 clips every epoch
    # is a fresh view, so this is a far harder task than the real run and
    # a low number here means nothing - it is printed, never judged.
    if cfg.augment:
        aug_acc, aug_loss = run(True, "augmented")
        cfg.say(f"  with augmentation:    best acc {aug_acc:.1%}, "
                f"best loss {aug_loss:.3f}   (for information only)")
    else:
        aug_acc, aug_loss = plain_acc, plain_loss

    # Dead means dead: the loss never got under the value a model that
    # outputs a flat distribution would score, AND accuracy never left
    # chance. Both, because either alone is noise on a sample this small.
    #
    # Two tolerances, neither of them guessed. The loss one is numerical:
    # when every input is identical the best the model can do is output
    # the class prior, which scores exactly ln(n_classes), and the broken
    # run sat at 2.9957 against ln(20) = 2.99573 - inside floating-point
    # noise of the bound, so a bare `< uniform` would have waved it
    # through. One per cent of the bound is wider than that noise and far
    # narrower than real learning. The accuracy one comes from the sample
    # size: on these clips a single extra correct clip moves accuracy by
    # 1/len(idx), so anything smaller is one clip of luck, not learning.
    moved_loss = plain_loss < uniform * 0.99
    moved_acc = plain_acc > chance + 1.0 / len(idx)
    if not moved_loss and not moved_acc:
        raise PreflightError(
            f"after {steps} gradient updates on {len(idx)} clips the model "
            f"has not moved at all: best loss {plain_loss:.3f} against "
            f"{uniform:.3f} for a model that knows nothing, best accuracy "
            f"{plain_acc:.1%} against {chance:.1%} for a coin flip. It "
            "cannot fit data it has already seen, so the signal is not in "
            "the clips: either the crops are not showing the mouth, or the "
            "cache was written by a broken run. Look at the preview "
            "figure, and if the crops look wrong delete "
            "<work>/cache/<lang> and let it rebuild.")

    if plain_acc < 3 * chance:
        cfg.say("")
        cfg.say(f"  note: only {plain_acc:.1%} on {len(idx)} clips - early on "
                "the curve, not stuck.")
        cfg.say(f"  The loss is moving ({uniform:.3f} -> {plain_loss:.3f}) "
                "and the full run gets")
        cfg.say(f"  far more updates than this test, so training goes ahead.")
    return float(aug_acc)


def preflight(X, y, g, n_classes: int, cfg: Config) -> dict:
    """Every check, in the order that fails cheapest first."""
    report = check_data(X, y, g, n_classes, cfg)
    check_augmentation(X, n_classes, cfg)
    if cfg.smoke_test:
        report["memorised"] = can_it_learn(X, y, n_classes, cfg)
    cfg.say("")
    cfg.say("preflight passed - the data moves, the augmentation keeps the")
    cfg.say("movement, and the model is learning rather than stuck.")
    return report


def choose_crop(clips: list[dict], spec: dict, cfg: Config,
                scales=(0.7, 0.9, 1.1, 1.3, 1.6), n_clips: int = 3,
                strip_at: float = 0.9):
    """The same clips cropped at several scales, side by side, to pick from.

    Cropping all eight hundred clips to find out the framing was wrong
    costs twenty-five minutes. Cropping three costs twenty seconds, and
    the right scale is something you can see and cannot usefully compute:
    it depends on how close these volunteers sat to the camera.

    Writes nothing to the cache - this is only a picture.
    """
    import cv2
    import matplotlib.pyplot as plt

    # different speakers, so a single oddly-framed person cannot decide it
    seen_speakers, chosen = set(), []
    for c in clips:
        if c["speaker"] in seen_speakers:
            continue
        seen_speakers.add(c["speaker"])
        chosen.append(c)
        if len(chosen) == n_clips:
            break
    if not chosen:
        raise SystemExit("No clips to look at.")

    cropper = LipCropper()
    rows = []
    for c in chosen:
        cap = cv2.VideoCapture(c["path"])
        fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
        if not 5 <= fps <= 240:
            fps = 30.0
        frames = []
        while True:
            ok, f = cap.read()
            if not ok:
                break
            frames.append(f)
        cap.release()
        if not frames:
            continue
        idx = sample_indices(len(frames), fps)
        mid = frames[idx[len(idx) // 2]]
        rows.append((c, mid, frames, idx))

    if not rows:
        raise SystemExit("Could not read any of the clips.")

    fig, axes = plt.subplots(len(rows), len(scales),
                             figsize=(1.7 * len(scales), 1.85 * len(rows)))
    axes = np.atleast_2d(axes)
    for r, (c, mid, _, _) in enumerate(rows):
        for k, sc in enumerate(scales):
            ax = axes[r, k]
            out = cropper.crop(mid, sc)
            if out is not None:
                ax.imshow(out, cmap="gray", vmin=0, vmax=255)
            else:
                ax.text(0.5, 0.5, "no face", ha="center", va="center",
                        transform=ax.transAxes, fontsize=8)
            ax.set_xticks([]); ax.set_yticks([])
            if r == 0:
                ax.set_title(f"{sc:g}", fontsize=12, fontweight="bold")
            if k == 0:
                ax.set_ylabel(f"{c['speaker']}\n{c['phrase']}", fontsize=8,
                              rotation=0, ha="right", va="center", labelpad=22)
    fig.suptitle("CROP_SCALE - pick the one where the mouth fills the square",
                 fontsize=12, y=1.0)
    fig.tight_layout()
    plt.show()

    # and one full strip at the suggested scale, so motion is visible too
    c, _, frames, idx = rows[0]
    steps = np.linspace(0, len(idx) - 1, 12).astype(int)
    fig2, axs = plt.subplots(1, 12, figsize=(12.6, 1.5))
    for j, t in enumerate(steps):
        out = cropper.crop(frames[idx[t]], strip_at)
        if out is not None:
            axs[j].imshow(out, cmap="gray", vmin=0, vmax=255)
        axs[j].set_xticks([]); axs[j].set_yticks([])
    fig2.suptitle(f"{c['speaker']} {c['phrase']} across the three seconds, "
                  f"at CROP_SCALE = {strip_at:g}", fontsize=11, y=1.06)
    fig2.tight_layout()
    plt.show()
    return [c["speaker"] for c, _, _, _ in rows]


def preview_frames(X, y, spec: dict, n_clips: int = 4, n_frames: int = 12,
                   seed: int = 0):
    """Shows what the model is about to be trained on, twice over.

    The top strip of each pair is the cached crop; the bottom is the same
    clip after augmentation, which is what actually reaches the network.
    Showing only one of the two is how an augmentation that replaced every
    clip with a still frame survived a whole day of looking at crop
    pictures that were perfectly fine.

    Returns the figure so a notebook can display it inline.
    """
    import matplotlib.pyplot as plt
    import tensorflow as tf

    rng = np.random.RandomState(seed)
    pick = rng.choice(len(X), size=min(n_clips, len(X)), replace=False)
    fn = _augment(len(spec["phrases"]))
    steps = np.linspace(0, FRAMES - 1, n_frames, dtype=int)

    rows = 2 * len(pick)
    fig, axes = plt.subplots(rows, n_frames,
                             figsize=(1.05 * n_frames, 1.12 * rows))
    axes = np.atleast_2d(axes)

    for r, i in enumerate(pick):
        raw = X[i]
        aug = fn(tf.constant(raw), tf.constant(np.int32(y[i])))[0].numpy()
        aug = (aug[..., 0] * 255).astype(np.uint8)
        pid = spec["phrases"][int(y[i])]["id"]
        for band, (strip, tag) in enumerate(
                ((raw, f"{pid} cached"), (aug, f"{pid} augmented"))):
            for c, t in enumerate(steps):
                ax = axes[2 * r + band, c]
                ax.imshow(strip[t], cmap="gray", vmin=0, vmax=255)
                ax.set_xticks([]); ax.set_yticks([])
                for sp in ax.spines.values():
                    sp.set_color("#cccccc")
                if c == 0:
                    ax.set_ylabel(tag, fontsize=8, rotation=0, ha="right",
                                  va="center", labelpad=38)
            m = clip_motion(strip[None])[0]
            axes[2 * r + band, -1].set_xlabel(f"motion {m:.1f}", fontsize=7)

    fig.suptitle("What the model is fed - cached crop above, augmented "
                 "below.\nIf the augmented row is a still picture, stop.",
                 fontsize=11, y=1.0)
    fig.tight_layout()
    return fig


def load_arrays(clips: list[dict], cache_dir: str):
    X = np.stack([np.load(Path(cache_dir) / f"{c['key']}.npz")["x"]
                  for c in clips]).astype(np.uint8)
    y = np.array([c["label"] for c in clips], np.int64)
    g = np.array([c["speaker"] for c in clips])
    return X, y, g


# ---------------------------------------------------------------- 4. model
def build_model(n_classes: int):
    """Returns (trainer, exporter). They share every weight; the exporter
    also hands out the embedding the app uses for personalisation.

    Strided Conv3D instead of MaxPool3D, and a Conv1D head instead of a GRU:
    both swaps are forced by TFLite, which has neither operator built in.
    """
    from tensorflow.keras import layers, models
    inp = layers.Input((FRAMES, CROP, CROP, 1), name="clip")
    x = inp
    for filters, stride in [(32, (1, 2, 2)), (64, (1, 2, 2)), (96, (2, 2, 2)),
                            (128, (2, 2, 2)), (128, (1, 2, 2))]:
        x = layers.Conv3D(filters, 3, strides=stride, padding="same",
                          use_bias=False)(x)
        x = layers.BatchNormalization()(x)
        x = layers.ReLU()(x)
    _, t, h, w, c = x.shape
    x = layers.Reshape((t, h * w * c))(x)
    x = layers.Conv1D(EMB_DIM, 3, padding="same", activation="relu")(x)
    x = layers.Conv1D(EMB_DIM, 3, padding="same", activation="relu")(x)
    emb = layers.GlobalAveragePooling1D(name="embedding")(x)
    out = layers.Dense(n_classes, activation="softmax", name="probs")(
        layers.Dropout(0.5)(emb))
    return models.Model(inp, out), models.Model(inp, [out, emb])


def _augment(n_classes: int):
    import tensorflow as tf

    def fn(x, y):
        x = tf.cast(x, tf.float32) / 255.0                    # (T,H,W)
        x = x[..., None]
        # one random zoom + shift for the whole clip (camera distance and
        # the small difference between the two face detectors)
        s = tf.random.uniform([], 0.86, 1.16)
        cx = 0.5 + tf.random.uniform([], -0.07, 0.07)
        cy = 0.5 + tf.random.uniform([], -0.07, 0.07)
        box = tf.stack([cy - s / 2, cx - s / 2, cy + s / 2, cx + s / 2])
        # box_indices says WHICH frame each box is cut from. Passing zeros
        # cut all 48 boxes out of frame 0, so every augmented clip became
        # 48 copies of its own first frame — a still face, before the
        # person had started mouthing anything. Every class looked the
        # same, and the model sat at chance on its own training data.
        # tf.range is the whole point: box i belongs to frame i.
        x = tf.image.crop_and_resize(
            x, tf.tile(box[None], [FRAMES, 1]),
            tf.range(FRAMES), [CROP, CROP])
        if tf.random.uniform([]) < 0.5:                       # mirrored camera
            x = tf.reverse(x, axis=[2])
        # lighting
        x = (x - 0.5) * tf.random.uniform([], 0.75, 1.3) + 0.5
        x = x + tf.random.uniform([], -0.12, 0.12)
        x = tf.clip_by_value(x, 0.0, 1.0)
        # started speaking a little early or late: slide in time, hold edges
        k = tf.random.uniform([], -4, 5, tf.int32)
        idx = tf.clip_by_value(tf.range(FRAMES) + k, 0, FRAMES - 1)
        x = tf.gather(x, idx)
        return x, tf.one_hot(y, n_classes)
    return fn


def _plain(n_classes: int):
    """Normalise and one-hot, and nothing else."""
    import tensorflow as tf

    def fn(x, y):
        return (tf.cast(x, tf.float32) / 255.0)[..., None], \
            tf.one_hot(y, n_classes)
    return fn


def _prep(x):
    return (x.astype(np.float32) / 255.0)[..., None]


class EpochLog:
    """One line per epoch, with an estimate of how much longer the fold has.

    Keras's own verbose=1 writes a progress bar per batch, which in Colab
    means hundreds of redrawn lines and a notebook that is unpleasant to
    scroll back through afterwards. verbose=2 is one line per epoch but
    says nothing about which fold it is in or how long is left, and the
    numbers it prints are the ones somebody watching a 40-minute run
    actually wants.

    The loss and accuracy here are on the TRAINING data, by definition: the
    held-out speakers are not touched until the fold is over. Training
    accuracy climbing while the fold's top-1 stays at chance is the
    signature of overfitting; training accuracy that never leaves chance
    means the model is not learning at all. Those are different problems,
    and this is the line that tells them apart.
    """

    def __init__(self, cfg, label: str, epochs: int):
        self.cfg, self.label, self.epochs = cfg, label, epochs
        self.t0 = None

    def make(self):
        import tensorflow as tf

        outer = self

        class _Cb(tf.keras.callbacks.Callback):
            def on_train_begin(self, logs=None):
                outer.t0 = time.time()

            def on_epoch_end(self, epoch, logs=None):
                every = max(0, int(outer.cfg.log_every))
                n = epoch + 1
                if not every:
                    return
                # Always show the first and the last, whatever the interval.
                if n != 1 and n != outer.epochs and n % every:
                    return
                logs = logs or {}
                gone = time.time() - (outer.t0 or time.time())
                left = gone / n * (outer.epochs - n)
                outer.cfg.say(
                    f"    {outer.label} epoch {n:>3}/{outer.epochs}"
                    f"   loss {logs.get('loss', float('nan')):.3f}"
                    f"   train acc {logs.get('accuracy', 0):6.1%}"
                    f"   {gone:5.0f}s gone, ~{left:4.0f}s left")

        return _Cb()


class Stalled(RuntimeError):
    """Training sat at chance. Raised so the run stops instead of
    producing four more folds of the same nothing."""


def _guards(cfg, n_classes: int, label: str, state: dict):
    """Two stopping rules, both reading TRAINING accuracy only.

    Reading the training metric matters. Early stopping on the held-out
    speakers would choose the epoch that flatters them and quietly turn
    the cross-validation score into a number that has seen its own test
    set. Nothing here ever looks at the held-out fold.

      * stall  - at chance well past the point where a working model has
                 moved, so stop the whole run and say so. An hour of
                 five folds arriving at 5.0% teaches nothing that the
                 fifteenth epoch had not already said.
      * settle - training accuracy has saturated, so the remaining epochs
                 only cost time. This is what makes EPOCHS a ceiling
                 rather than a fixed cost.
    """
    import tensorflow as tf

    chance = 1.0 / n_classes
    floor = chance * 1.6

    class _Guard(tf.keras.callbacks.Callback):
        def __init__(self):
            super().__init__()
            self.best = 0.0
            self.flat = 0

        def on_epoch_end(self, epoch, logs=None):
            acc = (logs or {}).get("accuracy", 0.0)
            n = epoch + 1

            if cfg.stall_epochs and n >= cfg.stall_epochs and acc < floor:
                state["stalled"] = (n, acc)
                self.model.stop_training = True
                return

            if acc > self.best + 1e-4:
                self.best, self.flat = acc, 0
            else:
                self.flat += 1
            # Only once it is genuinely trained. Stopping early at a
            # middling accuracy would also cut the cosine learning-rate
            # schedule short, which changes the model for the worse.
            if cfg.patience and self.best >= 0.97 and self.flat >= cfg.patience:
                state["settled"] = (n, self.best)
                self.model.stop_training = True

    return _Guard()


def fit(X, y, n_classes: int, cfg: Config, seed: int,
        backup: Path | None = None, label: str = ""):
    """Fixed number of epochs with cosine decay. No early stopping on purpose:
    stopping on the held-out speakers would leak them into the result.

    [backup] turns on Keras's preemption handling. It is the one way to stop
    and restart mid-training without changing the result: it restores the
    weights, the Adam moments and the epoch counter together, so the cosine
    learning-rate schedule carries on from the right place. Restoring only
    the weights - the obvious thing to write - would quietly train a
    different model.
    """
    import tensorflow as tf
    tf.keras.utils.set_random_seed(seed)
    trainer, exporter = build_model(n_classes)
    steps = max(1, int(np.ceil(len(X) / cfg.batch)))
    lr = tf.keras.optimizers.schedules.CosineDecay(1e-3, steps * cfg.epochs)
    trainer.compile(
        optimizer=tf.keras.optimizers.Adam(lr),
        loss=tf.keras.losses.CategoricalCrossentropy(label_smoothing=0.1),
        metrics=["accuracy"])
    # Augmentation off is a diagnostic, not a training mode: it answers
    # "can this model fit this data at all", separately from "can it fit
    # it through the augmentation".
    prep = _augment(n_classes) if cfg.augment else _plain(n_classes)
    ds = (tf.data.Dataset.from_tensor_slices((X, y.astype(np.int32)))
          .shuffle(len(X), seed=seed, reshuffle_each_iteration=True)
          .map(prep, num_parallel_calls=tf.data.AUTOTUNE)
          .batch(cfg.batch).prefetch(tf.data.AUTOTUNE))
    cbs = []
    if backup is not None and cfg.checkpoint:
        try:
            backup.mkdir(parents=True, exist_ok=True)
            cbs.append(tf.keras.callbacks.BackupAndRestore(
                backup_dir=str(backup)))
        except Exception as e:
            cfg.say(f"  (checkpointing off: {e})")

    if cfg.log_every:
        cbs.append(EpochLog(cfg, label, cfg.epochs).make())
    state: dict = {}
    cbs.append(_guards(cfg, n_classes, label, state))

    h = trainer.fit(ds, epochs=cfg.epochs, verbose=0, callbacks=cbs)

    if "settled" in state:
        n, best = state["settled"]
        cfg.say(f"    {label} stopped at epoch {n}: training accuracy "
                f"settled at {best:.1%}")
    if "stalled" in state:
        n, acc = state["stalled"]
        raise Stalled(
            f"{label} was still at {acc:.1%} after {n} epochs, against a "
            f"{1.0 / n_classes:.1%} chance baseline. The model is not "
            "learning its own training data, so the remaining folds would "
            "say the same thing an hour from now. Stopping.\n"
            "        Look at the crop figures first: section 5 of the "
            "figures notebook shows exactly what the model is being fed.")

    # The whole curve, not just where it ended. Throwing it away meant no
    # training-curve figure could ever be drawn, and that figure is how a
    # reader tells "never learned" from "learned and did not generalise".
    history = {k: [float(x) for x in v] for k, v in h.history.items()}
    return exporter, float(h.history["accuracy"][-1]), history


def predict(exporter, X, batch=32):
    p, e = exporter.predict(_prep(X), batch_size=batch, verbose=0)
    return p, e


# Bumped when a change makes previously-saved folds invalid.
#   2 — crop_and_resize was cutting all 48 boxes from frame 0, so every
#       augmented clip was 48 copies of a still face and the model sat at
#       chance on its own training data.
TRAIN_REV = 2


def signature(clips: list[dict], cfg: Config, n_classes: int) -> str:
    """Identifies one exact job: this set of clips with these settings.

    Work already finished is stored under this name, so a run that was cut
    short (Colab taking the GPU back, a closed laptop) picks up where it
    stopped instead of starting over. Add a video and the name changes, as
    it must: every fold has to be retrained once the data changes.
    """
    h = hashlib.sha256()
    for key in sorted(c["key"] for c in clips):
        h.update(key.encode())
    h.update(f"|{cfg.folds}|{cfg.epochs}|{cfg.batch}|{cfg.seed}|{n_classes}"
             .encode())
    # Folds saved by an older pipeline cannot be mixed with new ones: the
    # augmentation bug that left every clip a still frame produced folds
    # that look finished and are worthless. Raise this whenever a change
    # alters what the model is trained on, and every account starts clean
    # instead of resuming someone else's wrong answer.
    h.update(f"|rev{TRAIN_REV}".encode())
    return h.hexdigest()[:16]


def cross_validate(X, y, g, n_classes: int, cfg: Config,
                   resume: Path | None = None) -> dict:
    """Leave-speakers-out. Every clip is predicted by a model that never saw
    its speaker, which is the only number that says anything about a new
    patient."""
    from sklearn.model_selection import GroupKFold
    speakers = sorted(set(g.tolist()))
    k = min(cfg.folds, len(speakers))
    oof_p = np.zeros((len(X), n_classes), np.float32)
    oof_e = np.zeros((len(X), EMB_DIM), np.float32)
    fold_of = np.full(len(X), -1)
    accs = []
    train_accs: list[float | None] = []
    histories: list[dict] = []
    for f, (tr, te) in enumerate(GroupKFold(n_splits=k).split(X, y, g)):
        done = resume / f"fold{f}.npz" if resume is not None else None
        p = e = None
        if done is not None and done.is_file():
            try:
                d = np.load(done)
                if np.array_equal(d["idx"], te):
                    p, e = d["p"], d["e"]
                    cfg.say(f"  fold {f + 1}/{k}: already done in an earlier "
                            f"run -> top-1 {(p.argmax(1) == y[te]).mean():.1%}")
                    # Reused from disk, so there is no curve for this fold.
                    train_accs.append(None)
                    histories.append({})
            except Exception as err:
                cfg.say(f"  fold {f + 1}/{k}: saved copy unusable ({err})")
        if p is None:
            # Checked again here: the allowance can run out between folds,
            # and the next fold would silently run on CPU.
            require_gpu(cfg, f"before fold {f + 1} of {k}")
            if resume is not None:
                touch_lock(resume, cfg)
            model, tr_acc, hist = fit(
                X[tr], y[tr], n_classes, cfg, cfg.seed + f,
                backup=None if resume is None else resume / f"backup{f}",
                label=f"fold {f + 1}/{k}")
            train_accs.append(tr_acc)
            histories.append(hist)
            p, e = predict(model, X[te])
            if done is not None:
                save_npz(done, p=p, e=e, idx=te)
            cfg.say(f"  fold {f + 1}/{k}: {len(set(g[tr]))} speakers train, "
                    f"{len(set(g[te]))} test -> "
                    f"top-1 {(p.argmax(1) == y[te]).mean():.1%} "
                    f"(train {tr_acc:.1%})")
        oof_p[te], oof_e[te], fold_of[te] = p, e, f
        accs.append(float((p.argmax(1) == y[te]).mean()))
    top1 = float((oof_p.argmax(1) == y).mean())
    top3 = float(np.mean([y[i] in np.argsort(-oof_p[i])[:3]
                          for i in range(len(y))]))
    per_speaker = {s: float((oof_p[g == s].argmax(1) == y[g == s]).mean())
                   for s in speakers}
    per_class = {}
    for c in range(n_classes):
        m = y == c
        per_class[f"P{c + 1:02d}"] = (
            float((oof_p[m].argmax(1) == c).mean()) if m.any() else None)
    cm = np.zeros((n_classes, n_classes), int)
    for t, p in zip(y, oof_p.argmax(1)):
        cm[t, p] += 1
    # Said out loud, because it is the single most useful comparison in
    # the whole run and nobody should have to dig it out of a log.
    real = [a for a in train_accs if a is not None]
    if real:
        mean_tr = float(np.mean(real))
        cfg.say("")
        cfg.say(f"  train {mean_tr:.1%}   vs   held-out {top1:.1%}   "
                f"(chance {1.0 / n_classes:.1%})")
        if mean_tr <= 1.3 / n_classes:
            cfg.say("  -> the model did not learn the TRAINING data either. "
                    "That is a pipeline")
            cfg.say("     fault, not a shortage of speakers. Check the crop "
                    "pictures first.")
        elif top1 <= 1.3 / n_classes:
            cfg.say("  -> it learned the training speakers and none of the "
                    "held-out ones:")
            cfg.say("     overfitting. More speakers, more augmentation, or "
                    "a smaller model.")

    return {"folds": k, "foldTop1": accs, "foldTrainTop1": train_accs,
            "foldHistory": histories, "top1": top1, "top3": top3,
            "top1Std": float(np.std(accs)), "chance": 1.0 / n_classes,
            "perSpeaker": per_speaker, "perClass": per_class,
            "confusion": cm.tolist(), "_p": oof_p, "_e": oof_e}


# ------------------------------------------------------- 5. personalisation
def personalised_probs(p, e, protos: dict, alpha=PERS_ALPHA, tau=PERS_TAU):
    """Blend the base model with nearest-prototype matching.

    protos maps class index -> mean embedding of the patient's own samples.
    Only the personalised classes are re-weighted, and only within the
    probability the base model already gave to them, so a phrase the patient
    has not recorded is never pushed out. The phone runs this same formula.
    """
    if not protos:
        return p
    cls = sorted(protos)
    P = np.stack([protos[c] for c in cls])
    P = P / (np.linalg.norm(P, axis=1, keepdims=True) + 1e-8)
    v = e / (np.linalg.norm(e) + 1e-8)
    s = (P @ v) / tau
    q = np.exp(s - s.max())
    q = q / q.sum()
    out = p.copy()
    mass = float(p[cls].sum())
    out[cls] = (1 - alpha) * p[cls] + alpha * mass * q
    return out


def personalise_study(cv: dict, y, g, clips, cfg: Config, repeats=20) -> dict:
    """k-shot curve on speakers with repeated takes, using the fold model that
    never saw them. k samples per phrase become prototypes; the rest are the
    test. Reported next to the base model on the very same test clips."""
    rng = np.random.default_rng(cfg.seed)
    p_all, e_all = cv["_p"], cv["_e"]
    by = defaultdict(lambda: defaultdict(list))
    for i, c in enumerate(clips):
        by[c["speaker"]][int(y[i])].append(i)
    out = {"alpha": PERS_ALPHA, "tau": PERS_TAU, "shots": {}, "speakers": []}
    for k in (1, 2, 3, 5):
        base_s, pers_s, used = [], [], []
        for s, per_class in by.items():
            ok = {c: ix for c, ix in per_class.items() if len(ix) >= k + 1}
            if len(ok) < max(2, len(per_class) // 2):
                continue
            b, q = [], []
            for _ in range(repeats):
                protos, tests = {}, []
                for c, ix in ok.items():
                    pick = rng.permutation(ix)
                    protos[c] = e_all[pick[:k]].mean(0)
                    tests += list(pick[k:])
                for i in tests:
                    b.append(p_all[i].argmax() == y[i])
                    q.append(personalised_probs(
                        p_all[i], e_all[i], protos).argmax() == y[i])
            base_s.append(np.mean(b))
            pers_s.append(np.mean(q))
            used.append(s)
        if used:
            out["shots"][str(k)] = {
                "speakers": len(used),
                "base": float(np.mean(base_s)),
                "personalised": float(np.mean(pers_s)),
                "gain": float(np.mean(pers_s) - np.mean(base_s)),
                "perSpeakerBase": [float(v) for v in base_s],
                "perSpeakerPersonalised": [float(v) for v in pers_s]}
            out["speakers"] = sorted(set(out["speakers"]) | set(used))
            cfg.say(f"  {k}-shot: {np.mean(base_s):.1%} -> "
                    f"{np.mean(pers_s):.1%}  ({len(used)} speakers)")
    if not out["shots"]:
        cfg.say("  no speaker has repeated takes yet, so the personalisation "
                "study cannot run. Record Tier B (10-take) speakers.")
    return out


# --------------------------------------------------------------- 7. export
def to_tflite(exporter) -> bytes:
    import tensorflow as tf
    conv = tf.lite.TFLiteConverter.from_keras_model(exporter)
    conv.optimizations = [tf.lite.Optimize.DEFAULT]
    conv.target_spec.supported_types = [tf.float16]   # half the size, float I/O
    return conv.convert()


def tflite_predict(blob: bytes, X, n_classes: int):
    """Runs the exported file exactly as the phone will."""
    import tensorflow as tf
    it = tf.lite.Interpreter(model_content=blob)
    it.allocate_tensors()
    i_d = it.get_input_details()[0]
    outs = it.get_output_details()
    p_d = next(o for o in outs if o["shape"][-1] == n_classes)
    e_d = next(o for o in outs if o["index"] != p_d["index"])
    P, E = [], []
    for x in _prep(X):
        it.set_tensor(i_d["index"], x[None])
        it.invoke()
        P.append(it.get_tensor(p_d["index"])[0].copy())
        E.append(it.get_tensor(e_d["index"])[0].copy())
    return np.stack(P), np.stack(E)


def next_version(model_dir: Path) -> int:
    v = [int(m.group(1)) for p in model_dir.glob("v*")
         if (m := re.match(r"^v(\d+)$", p.name))]
    return max(v, default=0) + 1


def figures(cv: dict, pers: dict, spec: dict, out: Path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    ids = [p["id"] for p in spec["phrases"]]
    cm = np.array(cv["confusion"], float)
    row = cm.sum(1, keepdims=True)
    fig, ax = plt.subplots(figsize=(7.2, 6.2))
    im = ax.imshow(np.divide(cm, row, out=np.zeros_like(cm), where=row > 0),
                   cmap="Blues", vmin=0, vmax=1)
    ax.set_xticks(range(len(ids)), ids, rotation=90, fontsize=7)
    ax.set_yticks(range(len(ids)), ids, fontsize=7)
    ax.set_xlabel("predicted phrase")
    ax.set_ylabel("spoken phrase")
    ax.set_title("Speaker-independent confusion (row-normalised)")
    fig.colorbar(im, fraction=0.046)
    fig.tight_layout()
    fig.savefig(out / "fig_confusion.png", dpi=200)
    plt.close(fig)

    acc = [cv["perClass"][i] or 0 for i in ids]
    fig, ax = plt.subplots(figsize=(7.2, 3.2))
    ax.bar(ids, acc, color="#0E8C8C")
    ax.axhline(cv["chance"], color="#888", lw=1, ls="--")
    ax.text(len(ids) - 0.5, cv["chance"] + 0.02, "chance", ha="right",
            fontsize=8, color="#555")
    ax.set_ylim(0, 1)
    ax.set_ylabel("top-1 accuracy")
    ax.tick_params(axis="x", labelrotation=90, labelsize=7)
    ax.set_title("Accuracy per phrase, unseen speakers")
    fig.tight_layout()
    fig.savefig(out / "fig_per_phrase.png", dpi=200)
    plt.close(fig)

    if pers["shots"]:
        ks = sorted(int(k) for k in pers["shots"])
        fig, ax = plt.subplots(figsize=(5.2, 3.4))
        ax.plot(ks, [pers["shots"][str(k)]["base"] for k in ks], "o--",
                color="#888", label="base model")
        ax.plot(ks, [pers["shots"][str(k)]["personalised"] for k in ks], "o-",
                color="#1B2A6B", label="personalised")
        ax.set_xticks(ks)
        ax.set_xlabel("samples per phrase from the new speaker (k)")
        ax.set_ylabel("top-1 accuracy")
        ax.set_ylim(0, 1)
        ax.legend(frameon=False)
        ax.set_title("Few-shot personalisation")
        fig.tight_layout()
        fig.savefig(out / "fig_personalisation.png", dpi=200)
        plt.close(fig)


def paper_numbers(card: dict, res: dict) -> str:
    cv, d, pers = res["crossValidation"], res["data"], res["personalisation"]
    L = [f"# Numbers for the paper - {card['name']} model v{card['version']}",
         "", f"Trained {card['trainedAt']}. Copy these into the marked places "
         "in the paper. Every figure is from speakers the model never saw.", "",
         "| Quantity | Value |", "|---|---|",
         f"| Speakers | {d['speakers']} |",
         f"| Clips used | {d['clips']} |",
         f"| Speakers left out, set incomplete | "
         f"{len(d.get('roster', {}).get('skipped', []))} |",
         f"| Phrases | {len(card['labels'])} |",
         f"| Speakers with repeated takes | {d['multiTakeSpeakers']} |",
         f"| Folds (leave-speakers-out) | {cv['folds']} |",
         f"| Top-1 accuracy | {cv['top1']:.1%} (std across folds "
         f"{cv['top1Std']:.1%}) |",
         f"| Top-3 accuracy | {cv['top3']:.1%} |",
         f"| Chance level | {cv['chance']:.1%} |",
         f"| Model size | {card['sizeBytes'] / 1e6:.2f} MB |",
         f"| Parameters | {res['parameters']:,} |",
         f"| TFLite agrees with Keras | {res['tfliteAgreement']:.1%} |", ""]
    if pers["shots"]:
        L += ["| k (samples per phrase) | Base | Personalised | Gain | "
              "Speakers |", "|---|---|---|---|---|"]
        for k in sorted(pers["shots"], key=int):
            s = pers["shots"][k]
            L.append(f"| {k} | {s['base']:.1%} | {s['personalised']:.1%} | "
                     f"{s['gain'] * 100:+.1f} pts | {s['speakers']} |")
    else:
        L.append("Personalisation study: not run - no speaker has repeated "
                 "takes yet.")
    worst = sorted(((v, k) for k, v in cv["perClass"].items()
                    if v is not None))[:3]
    L += ["", "Hardest phrases: " + ", ".join(f"{k} ({v:.0%})"
                                                for v, k in worst)]
    roster = d.get("roster", {})
    if roster:
        used = ", ".join(roster.get("speakerIds", [])) or "none"
        left = ", ".join(r["speaker"] for r in roster.get("skipped", []))
        L += ["",
              f"A speaker joins training only once at least "
              f"{roster.get('minPhrases')} of {roster.get('phraseCount')} "
              f"phrases of theirs are in Drive.",
              f"Trained on: {used}.",
              f"Left out as incomplete: {left or 'none'}."]
    return "\n".join(L) + "\n"


def export(exporter, X, y, spec, data, cv, pers, cfg: Config) -> dict:
    n = len(spec["phrases"])
    blob = to_tflite(exporter)
    take = np.random.default_rng(0).permutation(len(X))[:min(40, len(X))]
    kp, _ = predict(exporter, X[take])
    tp, _ = tflite_predict(blob, X[take], n)
    agree = float((kp.argmax(1) == tp.argmax(1)).mean())
    if agree < 0.95:
        raise SystemExit(f"The exported model disagrees with the trained one "
                         f"on {1 - agree:.0%} of clips. Not publishing.")

    mdir = Path(cfg.work_dir) / "models" / cfg.lang
    mdir.mkdir(parents=True, exist_ok=True)
    version = next_version(mdir)
    out = mdir / f"v{version}"
    out.mkdir()
    stem = f"antarvani_{cfg.lang}_v{version}"
    (out / f"{stem}.tflite").write_bytes(blob)

    enough = data["speakers"] >= 3
    card = {
        "schema": 1, "lang": spec["code"], "name": spec["name"],
        "tts": spec["tts"], "version": version, "file": f"{stem}.tflite",
        "sha256": hashlib.sha256(blob).hexdigest(), "sizeBytes": len(blob),
        "frames": FRAMES, "size": CROP, "fps": TARGET_FPS,
        "windowS": WINDOW_S, "eyeBoxScale": cfg.crop_scale,
        "embeddingDim": EMB_DIM, "alpha": PERS_ALPHA, "tau": PERS_TAU,
        "minConfidence": 0.55, "labels": spec["phrases"],
        "speakers": data["speakers"], "clips": data["clips"],
        "minPhrases": data.get("roster", {}).get("minPhrases"),
        "top1": cv["top1"] if enough else None,
        "top3": cv["top3"] if enough else None,
        "trainedAt": _dt.datetime.now(_dt.timezone.utc)
        .strftime("%Y-%m-%d %H:%M UTC"),
        "notes": cfg.notes,
    }
    (out / f"{stem}.json").write_text(
        json.dumps(card, ensure_ascii=False, indent=1), encoding="utf-8")
    res = {"card": stem, "data": data,
           "speakerIds": data.get("roster", {}).get("speakerIds", []),
           "crossValidation": {k: v for k, v in cv.items()
                               if not k.startswith("_")},
           "personalisation": pers, "tfliteAgreement": agree,
           "parameters": int(exporter.count_params()),
           "config": {"folds": cfg.folds, "epochs": cfg.epochs,
                      "batch": cfg.batch, "seed": cfg.seed}}
    (out / "results.json").write_text(json.dumps(res, indent=1))

    # Who this model was trained on. Kept beside the model, and appended to
    # one running history, so months from now it is still possible to say
    # which speakers any given model version saw.
    roster = data.get("roster", {})
    (out / "trained_speakers.json").write_text(
        json.dumps({
            "lang": spec["code"],
            "modelVersion": version,
            "trainedAt": card["trainedAt"],
            "minPhrases": roster.get("minPhrases"),
            "speakerIds": roster.get("speakerIds", []),
            "used": roster.get("used", []),
            "skippedIncomplete": roster.get("skipped", []),
        }, indent=1),
        encoding="utf-8")

    hist_file = mdir / "speakers_history.json"
    try:
        hist = json.loads(hist_file.read_text(encoding="utf-8"))
        if not isinstance(hist, list):
            hist = []
    except Exception:
        hist = []
    hist.append({
        "modelVersion": version,
        "trainedAt": card["trainedAt"],
        "minPhrases": roster.get("minPhrases"),
        "speakers": len(roster.get("speakerIds", [])),
        "clips": data["clips"],
        "top1": cv["top1"] if enough else None,
        "speakerIds": roster.get("speakerIds", []),
        "skippedIds": [r["speaker"] for r in roster.get("skipped", [])],
    })
    hist_file.write_text(json.dumps(hist, indent=1), encoding="utf-8")
    (out / "paper_numbers.md").write_text(paper_numbers(card, res),
                                          encoding="utf-8")
    try:
        figures(cv, pers, spec, out)
    except Exception as e:  # a plot must never cost a trained model
        cfg.say(f"figures skipped: {e}")
    cfg.say(f"model    : {out / (stem + '.tflite')}  "
            f"({len(blob) / 1e6:.2f} MB, v{version})")
    return {"dir": str(out), "stem": stem, "card": card, "results": res}


# -------------------------------------------------------------- 8. publish
def publish_github(done: dict, cfg: Config) -> str | None:
    """Uploads the .tflite and .json as a release. Returns the card link."""
    import requests
    card, stem, d = done["card"], done["stem"], Path(done["dir"])
    tag = f"model-{card['lang']}-v{card['version']}"
    H = {"Authorization": f"Bearer {cfg.github_token}",
         "Accept": "application/vnd.github+json"}
    api = f"https://api.github.com/repos/{cfg.github_repo}"
    acc = (f"top-1 {card['top1']:.1%} on unseen speakers"
           if card["top1"] is not None else "pipeline test, not evaluated")
    r = requests.post(f"{api}/releases", headers=H, timeout=60, json={
        "tag_name": tag, "name": f"{card['name']} model v{card['version']}",
        "body": f"{card['speakers']} speakers, {card['clips']} clips, {acc}."})
    if r.status_code != 201:
        cfg.say(f"GitHub refused the release ({r.status_code}): "
                f"{r.json().get('message', r.text)[:200]}")
        return None
    up = r.json()["upload_url"].split("{")[0]
    for name, ctype in ((f"{stem}.tflite", "application/octet-stream"),
                        (f"{stem}.json", "application/json")):
        u = requests.post(f"{up}?name={name}", timeout=300,
                          headers={**H, "Content-Type": ctype},
                          data=(d / name).read_bytes())
        if u.status_code != 201:
            cfg.say(f"upload of {name} failed ({u.status_code})")
            return None
    return (f"https://github.com/{cfg.github_repo}/releases/download/"
            f"{tag}/{stem}.json")


# ------------------------------------------------------------------ run all
def preprocess_only(cfg: Config) -> dict:
    """Crops every video and stops. Needs no GPU, so run it on a CPU runtime
    and keep the GPU hours for training."""
    root, spec = load_language(cfg)
    resolve_work_dir(cfg, Path(root))
    health_check(cfg)
    clips = scan(root, spec, cfg)
    if not clips:
        raise SystemExit(f"No videos found under {root}.")
    clips, roster = select_speakers(clips, spec, cfg)
    cache = str(Path(cfg.work_dir) / "cache" / cfg.lang)
    clips = preprocess(clips, cache, cfg)
    data = describe(clips, spec, cfg)
    data["roster"] = roster
    cfg.say("Crops are cached. Switch to a GPU runtime and run the training "
            "cell; it will not redo any of this.")
    return data


def run_all(cfg: Config, force: bool = False) -> dict:
    root, spec = load_language(cfg)
    resolve_work_dir(cfg, Path(root))
    health_check(cfg)
    clips = scan(root, spec, cfg)
    if not clips:
        raise SystemExit(f"No videos found under {root}.")
    # Only complete speakers train; the rest wait for their uploads.
    clips, roster = select_speakers(clips, spec, cfg)
    cache = str(Path(cfg.work_dir) / "cache" / cfg.lang)
    clips = preprocess(clips, cache, cfg)
    data = describe(clips, spec, cfg)
    data["roster"] = roster
    X, y, g = load_arrays(clips, cache)
    return train_and_export(X, y, g, clips, spec, data, cfg, force=force)


def train_and_export(X, y, g, clips, spec, data, cfg: Config,
                     force: bool = False) -> dict:
    n = len(spec["phrases"])
    require_gpu(cfg, "before training")

    # Nothing expensive happens until the data has been shown to be
    # learnable. Both faults that cost a day would have been caught here
    # in under two minutes.
    data["preflight"] = preflight(X, y, g, n, cfg)

    sig = signature(clips, cfg, n)
    base = Path(cfg.work_dir) / "resume" / cfg.lang
    base.mkdir(parents=True, exist_ok=True)
    resume = base / sig
    resume.mkdir(parents=True, exist_ok=True)

    # Work is only reused when the clips AND the settings match. If another
    # account ran with different settings, say so plainly - otherwise this
    # looks like starting from scratch for no reason.
    others = [d for d in base.iterdir() if d.is_dir() and d.name != sig]
    if others and not any(resume.glob("fold*.npz")):
        cfg.say("")
        cfg.say(f"note: {len(others)} earlier run(s) are saved here under "
                "different settings or a different set of clips.")
        cfg.say("      They cannot be reused. Every account must use the "
                "same FOLDS, EPOCHS,")
        cfg.say("      MIN_PHRASES and seed, and see the same clips in Drive.")

    claim_lock(resume, cfg, force=force)
    try:
        return _train_and_export(X, y, g, clips, spec, data, cfg, resume, n)
    except BaseException:
        # Whatever went wrong - no GPU, a disconnect, Ctrl-C - the lock must
        # not outlive this run, or the next account waits forty minutes for
        # nothing.
        release_lock(resume)
        raise


def _train_and_export(X, y, g, clips, spec, data, cfg: Config,
                      resume: Path, n: int) -> dict:
    done_already = sorted(x.name for x in resume.glob("fold*.npz"))
    if done_already:
        cfg.say(f"resuming: {len(done_already)} fold(s) already finished "
                f"({', '.join(done_already)})")
    if (resume / "final.weights.h5").is_file():
        cfg.say("resuming: the final model is already trained")
    if data["speakers"] >= 3:
        cfg.say(f"\ncross-validation, {min(cfg.folds, data['speakers'])} folds "
                f"x {cfg.epochs} epochs")
        cv = cross_validate(X, y, g, n, cfg, resume)
        cfg.say(f"UNSEEN SPEAKERS: top-1 {cv['top1']:.1%}, top-3 "
                f"{cv['top3']:.1%}  (chance {cv['chance']:.1%})")
        cfg.say("\npersonalisation study")
        pers = personalise_study(cv, y, g, clips, cfg)
    else:
        cfg.say("\nFewer than 3 speakers: nothing can be held out, so no "
                "accuracy is reported. This run only proves the pipeline.")
        cv = {"folds": 0, "foldTop1": [], "top1": 0.0, "top3": 0.0,
              "top1Std": 0.0, "chance": 1.0 / n, "perSpeaker": {},
              "perClass": {f"P{i + 1:02d}": None for i in range(n)},
              "confusion": np.zeros((n, n), int).tolist()}
        pers = {"alpha": PERS_ALPHA, "tau": PERS_TAU, "shots": {},
                "speakers": []}
    cfg.say("\nfinal model on every clip")
    weights = resume / "final.weights.h5"
    exporter = None
    if weights.is_file():
        try:
            _, exporter = build_model(n)
            exporter.load_weights(str(weights))
            cfg.say("  already trained in an earlier run - loaded it")
        except Exception as e:
            cfg.say(f"  the saved model could not be read ({e}) - training "
                    "it again")
            exporter = None
            weights.unlink(missing_ok=True)
    if exporter is None:
        require_gpu(cfg, "before the final model")
        touch_lock(resume, cfg)
        exporter, _, _ = fit(X, y, n, cfg, cfg.seed + 100,
                             backup=resume / "backup_final",
                             label="final model")
        exporter.save_weights(str(weights))
    done = export(exporter, X, y, spec, data, cv, pers, cfg)
    link = None
    if cfg.github_repo and cfg.github_token:
        link = publish_github(done, cfg)
    done["link"] = link
    release_lock(resume)
    (Path(done["dir"]) / "log.txt").write_text("\n".join(cfg.log),
                                               encoding="utf-8")
    stem = done["stem"]
    print("\n" + "=" * 64)
    if link:
        print("PUBLISHED. In the app: Corpus > Overview > Publish a model,")
        print("paste this link and press Publish:\n")
        print("  " + link)
    else:
        print("TRAINED. To put it on every phone:")
        print(f"  1. Open {done['dir']}")
        print(f"  2. Make a GitHub release and attach {stem}.tflite and "
              f"{stem}.json")
        print(f"  3. Copy the link of {stem}.json")
        print("  4. In the app: Corpus > Overview > Publish a model, paste, "
              "Publish")
    print("=" * 64)
    return done
