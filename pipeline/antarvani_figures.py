"""Figures for the ANTARVANI synopsis, presentation and paper.

Everything here is drawn from the corpus and from a real training run. The
corpus and pipeline figures need no model at all, so they are available the
moment clips are in Drive; the result figures read `results.json` and simply
say so when it is not there yet.

House rules, so twenty figures look like one piece of work:
  * one palette, one font scale, white background, 200 dpi
  * type large enough to survive a projector at the back of a room
  * no gridlines, borders or legends that carry no information
  * every figure saves as PNG and PDF - PNG for slides, PDF for the paper,
    where a vector figure stays sharp at any zoom

Faces are a privacy matter, not a design one. Mouth crops are the model's
real input and are close to unidentifiable, so they are used freely. A whole
face is only ever drawn for the speaker named in FACE_SPEAKER, which is for
a member of the team who has agreed to appear - never a volunteer.
"""

from __future__ import annotations

import json
import math
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

from antarvani_pipeline import (CROP, EYE_BOX_SCALE, EYE_L, EYE_R, FRAMES,
                                LIP_CORNERS, TARGET_FPS, Config, sample_indices)

# ------------------------------------------------------------------ style
INK = "#1A1C22"          # near-black, softer than pure black on a projector
MUTED = "#6B7280"
PRIMARY = "#4F46E5"      # the app's indigo
PRIMARY_SOFT = "#C7D2FE"
GOOD = "#059669"
WARN = "#D97706"
BAD = "#DC2626"
GRID = "#E5E7EB"
SEQ = ["#EEF2FF", "#C7D2FE", "#A5B4FC", "#818CF8", "#6366F1", "#4F46E5",
       "#4338CA", "#3730A3"]


def style():
    """Applies the house style. Call once per notebook."""
    import matplotlib as mpl
    from matplotlib import pyplot as plt

    mpl.rcParams.update({
        "figure.dpi": 110,
        "savefig.dpi": 200,
        "savefig.bbox": "tight",
        "savefig.facecolor": "white",
        "figure.facecolor": "white",
        "axes.facecolor": "white",
        "font.size": 12,
        "axes.titlesize": 14,
        "axes.titleweight": "bold",
        "axes.labelsize": 12,
        "axes.edgecolor": MUTED,
        "axes.labelcolor": INK,
        "axes.titlecolor": INK,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "xtick.color": MUTED,
        "ytick.color": MUTED,
        "xtick.labelsize": 11,
        "ytick.labelsize": 11,
        "legend.frameon": False,
        "text.color": INK,
        "image.cmap": "magma",
    })
    for family in ("DejaVu Sans", "Noto Sans Devanagari", "Nirmala UI"):
        try:
            mpl.font_manager.findfont(family, fallback_to_default=False)
            mpl.rcParams["font.family"] = family
            break
        except Exception:
            continue
    return plt


def save(fig, name: str, out: Path, cfg: Config | None = None) -> Path:
    """Writes <out>/<name>.png and .pdf, and says where they went."""
    out.mkdir(parents=True, exist_ok=True)
    png = out / f"{name}.png"
    fig.savefig(png)
    try:
        fig.savefig(out / f"{name}.pdf")
    except Exception:
        pass           # a missing vector backend is not worth stopping for
    if cfg is not None:
        cfg.say(f"  saved {png.name}")
    import matplotlib.pyplot as plt
    plt.close(fig)
    return png


def _phrase_label(spec: dict, pid: str, chars: int = 22) -> str:
    for p in spec["phrases"]:
        if p["id"] == pid:
            t = p.get("roman") or p.get("text") or p.get("english") or pid
            return t if len(t) <= chars else t[: chars - 1] + "…"
    return pid


def _tiles(ax, items):
    """A row of big numbers. Reads from the back of a room, which a table
    of the same four figures does not.

    An item is (value, label) or (value, label, colour); a baseline such as
    chance is given MUTED so it does not read as another achievement.
    """
    ax.axis("off")
    n = len(items)
    for i, item in enumerate(items):
        value, label = item[0], item[1]
        colour = item[2] if len(item) > 2 else PRIMARY
        x = (i + 0.5) / n
        ax.text(x, 0.62, value, ha="center", va="center", fontsize=34,
                fontweight="bold", color=colour, transform=ax.transAxes)
        ax.text(x, 0.22, label, ha="center", va="center", fontsize=12,
                color=MUTED, transform=ax.transAxes)


# =====================================================  1. the corpus
def fig_corpus(clips: list[dict], spec: dict, out: Path,
               cfg: Config | None = None) -> Path:
    """What was collected: the figure that opens a results section."""
    plt = style()
    ids = [p["id"] for p in spec["phrases"]]
    per_phrase = {i: 0 for i in ids}
    per_speaker: dict[str, set] = defaultdict(set)
    takes: dict[str, int] = defaultdict(int)
    for c in clips:
        per_phrase[c["phrase"]] = per_phrase.get(c["phrase"], 0) + 1
        per_speaker[c["speaker"]].add(c["phrase"])
        takes[c["speaker"]] += 1

    secs = len(clips) * 3.0
    fig = plt.figure(figsize=(13, 7.6))
    gs = fig.add_gridspec(3, 2, height_ratios=[0.38, 1, 1], hspace=0.62,
                          wspace=0.22)

    _tiles(fig.add_subplot(gs[0, :]), [
        (f"{len(per_speaker)}", "speakers"),
        (f"{len(clips)}", "clips"),
        (f"{len(ids)}", "phrases"),
        (f"{secs / 60:.0f} min", "of video"),
    ])

    # clips per phrase -------------------------------------------------
    ax = fig.add_subplot(gs[1, :])
    vals = [per_phrase[i] for i in ids]
    bars = ax.bar(range(len(ids)), vals, color=PRIMARY_SOFT,
                  edgecolor=PRIMARY, linewidth=0.8)
    # Amber only where a phrase is genuinely behind the rest; colouring
    # six bars that happen to tie for lowest says nothing.
    if vals and min(vals) < 0.85 * float(np.mean(vals)):
        lo = min(vals)
        for b, v in zip(bars, vals):
            if v == lo:
                b.set_color("#FDE68A")
                b.set_edgecolor(WARN)
    ax.set_xticks(range(len(ids)))
    ax.set_xticklabels(ids, rotation=90, fontsize=9)
    ax.set_ylabel("clips")
    ax.set_title("Clips per phrase", loc="left")
    ax.yaxis.grid(True, color=GRID, lw=0.8)
    ax.set_axisbelow(True)
    if vals:
        ax.axhline(float(np.mean(vals)), color=MUTED, lw=1, ls="--")
        ax.text(0.2, float(np.mean(vals)), f"mean {np.mean(vals):.0f}",
                va="bottom", fontsize=10, color=MUTED)

    # clips per speaker ------------------------------------------------
    ax = fig.add_subplot(gs[2, 0])
    order = sorted(takes, key=lambda s: -takes[s])
    ax.bar(range(len(order)), [takes[s] for s in order], color=PRIMARY)
    ax.set_xlabel("speaker (most clips first)")
    ax.set_ylabel("clips")
    ax.set_title("Clips per speaker", loc="left")
    ax.yaxis.grid(True, color=GRID, lw=0.8)
    ax.set_axisbelow(True)

    # how complete each session is -------------------------------------
    ax = fig.add_subplot(gs[2, 1])
    done = [len(v) for v in per_speaker.values()]
    n = len(ids)
    if done:
        ax.hist(done, bins=range(0, n + 2), color=PRIMARY_SOFT,
                edgecolor=PRIMARY, align="left")
        full = sum(1 for d in done if d >= n)
        ax.axvline(n, color=GOOD, lw=1.6)
        ax.text(n - 0.3, ax.get_ylim()[1] * 0.92, f"{full} complete ",
                ha="right", fontsize=11, color=GOOD, fontweight="bold")
    ax.set_xlabel("phrases recorded")
    ax.set_ylabel("speakers")
    ax.set_title("Session completeness", loc="left")
    ax.yaxis.grid(True, color=GRID, lw=0.8)
    ax.set_axisbelow(True)

    fig.suptitle("ANTARVANI corpus", x=0.009, y=1.0, ha="left", fontsize=17,
                 fontweight="bold")
    return save(fig, "fig01_corpus", out, cfg)


def fig_coverage(clips: list[dict], spec: dict, out: Path,
                 cfg: Config | None = None) -> Path:
    """Speaker x phrase grid. One look says where the holes are."""
    plt = style()
    ids = [p["id"] for p in spec["phrases"]]
    speakers = sorted({c["speaker"] for c in clips})
    grid = np.zeros((len(speakers), len(ids)), int)
    si = {s: i for i, s in enumerate(speakers)}
    pi = {p: i for i, p in enumerate(ids)}
    for c in clips:
        if c["speaker"] in si and c["phrase"] in pi:
            grid[si[c["speaker"]], pi[c["phrase"]]] += 1

    from matplotlib.colors import ListedColormap, BoundaryNorm
    cmap = ListedColormap(["#E4E7EC", PRIMARY_SOFT, PRIMARY, "#3730A3"])
    norm = BoundaryNorm([0, 1, 2, 3, 99], cmap.N)

    h = max(4.0, 0.26 * len(speakers) + 2.2)
    fig, ax = plt.subplots(figsize=(12, h))
    ax.imshow(grid, cmap=cmap, norm=norm, aspect="auto")
    ax.set_xticks(range(len(ids)))
    ax.set_xticklabels(ids, rotation=90, fontsize=9)
    ax.set_yticks(range(len(speakers)))
    ax.set_yticklabels(speakers, fontsize=9)
    ax.set_xticks(np.arange(-0.5, len(ids), 1), minor=True)
    ax.set_yticks(np.arange(-0.5, len(speakers), 1), minor=True)
    ax.grid(which="minor", color="white", linewidth=1.4)
    ax.tick_params(which="minor", length=0)
    for s in ax.spines.values():
        s.set_visible(False)

    filled = int((grid > 0).sum())
    total = grid.size or 1
    ax.set_title(
        f"Who recorded what  -  {filled} of {total} cells filled "
        f"({100 * filled / total:.0f}%)", loc="left", pad=14)
    from matplotlib.patches import Patch
    ax.legend(handles=[Patch(facecolor="#E4E7EC", label="none"),
                       Patch(facecolor=PRIMARY_SOFT, label="1 take"),
                       Patch(facecolor=PRIMARY, label="2 takes"),
                       Patch(facecolor="#3730A3", label="3+")],
              ncol=4, loc="upper right", bbox_to_anchor=(1.0, -0.06),
              fontsize=10)
    return save(fig, "fig02_coverage", out, cfg)


def fig_timeline(clips: list[dict], out: Path,
                 cfg: Config | None = None) -> Path:
    """How the corpus grew. Real collection effort, plainly shown."""
    plt = style()
    days: dict[str, int] = defaultdict(int)
    for c in clips:
        try:
            ts = Path(c["path"]).stat().st_mtime
        except OSError:
            continue
        days[datetime.fromtimestamp(ts).strftime("%Y-%m-%d")] += 1
    if not days:
        return Path()
    keys = sorted(days)
    counts = [days[k] for k in keys]
    cum = np.cumsum(counts)
    x = [datetime.strptime(k, "%Y-%m-%d") for k in keys]

    fig, ax = plt.subplots(figsize=(12, 4.6))
    ax.fill_between(x, cum, color=PRIMARY_SOFT, alpha=0.75)
    ax.plot(x, cum, color=PRIMARY, lw=2.4)
    ax.scatter(x, cum, s=26, color=PRIMARY, zorder=3)
    best = int(np.argmax(counts))
    ax.annotate(f"busiest day: {counts[best]} clips",
                xy=(x[best], cum[best]), xytext=(0, 26),
                textcoords="offset points", ha="center", fontsize=11,
                color=INK,
                arrowprops=dict(arrowstyle="-", color=MUTED, lw=1))
    ax.set_ylabel("clips collected (running total)")
    ax.set_title("Collection timeline", loc="left")
    ax.yaxis.grid(True, color=GRID, lw=0.8)
    ax.set_axisbelow(True)
    fig.autofmt_xdate()
    return save(fig, "fig03_timeline", out, cfg)


# ==============================================  2. what the model sees
def _read_frames(path: str, want: int = 0):
    import cv2
    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        return [], 30.0
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    if not 5 <= fps <= 240:
        fps = 30.0
    frames = []
    while True:
        ok, f = cap.read()
        if not ok:
            break
        frames.append(f)
        if want and len(frames) >= want:
            break
    cap.release()
    return frames, fps


def fig_face_crop(clip_path: str, cropper, out: Path,
                  cfg: Config | None = None) -> Path:
    """The alignment step, on a real frame: eye corners, the rotated box
    they define, and the 88x88 the model is handed.

    Only ever called for a speaker who has agreed to appear.
    """
    import cv2
    from matplotlib.patches import Polygon
    plt = style()

    frames, _ = _read_frames(clip_path)
    if not frames:
        return Path()
    mid = frames[len(frames) // 2]
    rgb = cv2.cvtColor(mid, cv2.COLOR_BGR2RGB)
    h, w = mid.shape[:2]
    lm = cropper._landmarks(rgb)
    if lm is None:
        return Path()

    def pt(i):
        return np.array([lm[i].x * w, lm[i].y * h], np.float32)

    eye_l, eye_r = pt(EYE_L), pt(EYE_R)
    mouth = (pt(LIP_CORNERS[0]) + pt(LIP_CORNERS[1])) / 2.0
    d = eye_r - eye_l
    ang = math.atan2(float(d[1]), float(d[0]))
    side = (float(np.linalg.norm(d)) or 1.0) * EYE_BOX_SCALE
    ca, sa = math.cos(ang), math.sin(ang)
    half = side / 2.0
    box = np.array([[-half, -half], [half, -half], [half, half], [-half, half]])
    box = np.array([[x * ca - y * sa + mouth[0], x * sa + y * ca + mouth[1]]
                    for x, y in box])

    fig, axes = plt.subplots(1, 3, figsize=(13, 5),
                             gridspec_kw={"width_ratios": [1.5, 1, 1]})
    axes[0].imshow(rgb)
    axes[0].plot([eye_l[0], eye_r[0]], [eye_l[1], eye_r[1]], color=WARN,
                 lw=2.2, marker="o", ms=7)
    axes[0].add_patch(Polygon(box, closed=True, fill=False, edgecolor=PRIMARY,
                              lw=2.6))
    axes[0].scatter([mouth[0]], [mouth[1]], s=70, color=PRIMARY, zorder=4,
                    edgecolor="white", linewidth=1.4)
    axes[0].set_title("1  find the face", loc="left")

    pad = int(side * 0.9)
    x0 = max(0, int(mouth[0] - pad)); x1 = min(w, int(mouth[0] + pad))
    y0 = max(0, int(mouth[1] - pad)); y1 = min(h, int(mouth[1] + pad))
    axes[1].imshow(rgb[y0:y1, x0:x1])
    axes[1].add_patch(Polygon(box - [x0, y0], closed=True, fill=False,
                              edgecolor=PRIMARY, lw=2.6))
    axes[1].set_title("2  box the mouth", loc="left")

    crop = cropper.crop(mid)
    if crop is not None:
        axes[2].imshow(crop, cmap="gray", vmin=0, vmax=255)
    axes[2].set_title(f"3  {CROP}x{CROP} grey", loc="left")

    for a in axes:
        a.set_xticks([]); a.set_yticks([])
        for s in a.spines.values():
            s.set_color(GRID)
    fig.suptitle(
        "Eye-aligned mouth crop: the box is rotated to level the eyes and "
        "scaled by the distance between them, so the mouth fills the same "
        "area whatever the camera distance",
        x=0.009, y=1.04, ha="left", fontsize=12, color=MUTED)
    return save(fig, "fig04_face_crop", out, cfg)


def _crops_of(path: str, cropper) -> list[np.ndarray]:
    frames, fps = _read_frames(path)
    if not frames:
        return []
    crops, seen = [], {}
    for i in sample_indices(len(frames), fps):
        if i not in seen:
            seen[i] = cropper.crop(frames[i])
        c = seen[i]
        crops.append(c if c is not None
                     else (crops[-1] if crops
                           else np.zeros((CROP, CROP), np.uint8)))
    return crops


def fig_sequence(clip_path: str, cropper, out: Path, label: str = "",
                 cfg: Config | None = None) -> Path:
    """All 48 frames of one utterance - the model's entire input, on a page."""
    plt = style()
    crops = _crops_of(clip_path, cropper)
    if not crops:
        return Path()
    cols, rows = 12, int(math.ceil(len(crops) / 12))
    fig, axes = plt.subplots(rows, cols, figsize=(13, 1.18 * rows + 0.9))
    for i, ax in enumerate(np.atleast_1d(axes).ravel()):
        ax.set_xticks([]); ax.set_yticks([])
        for s in ax.spines.values():
            s.set_color(GRID)
        if i < len(crops):
            ax.imshow(crops[i], cmap="gray", vmin=0, vmax=255)
            ax.set_xlabel(f"{i / TARGET_FPS:.2f}s", fontsize=7, color=MUTED,
                          labelpad=1)
        else:
            ax.axis("off")
    fig.suptitle(
        f"One utterance as the model receives it{f'  -  {label}' if label else ''}"
        f"  -  {len(crops)} frames, {TARGET_FPS:.0f} fps, "
        f"{CROP}x{CROP} greyscale",
        x=0.009, y=1.0, ha="left", fontsize=14, fontweight="bold")
    fig.tight_layout()
    return save(fig, "fig05_sequence", out, cfg)


def fig_grid(clips: list[dict], spec: dict, cropper, out: Path,
             n_phrases: int = 5, n_speakers: int = 7,
             cfg: Config | None = None) -> Path:
    """The same phrases across different people: what the model has to see
    past. Mouth crops only, so nobody is identifiable."""
    plt = style()
    by: dict[tuple[str, str], str] = {}
    for c in clips:
        by.setdefault((c["phrase"], c["speaker"]), c["path"])
    speakers = sorted({s for _, s in by})
    phrases = [p["id"] for p in spec["phrases"]]
    # the speakers and phrases with the most cells filled, so the grid is full
    speakers = sorted(speakers,
                      key=lambda s: -sum((p, s) in by for p in phrases)
                      )[:n_speakers]
    phrases = sorted(phrases,
                     key=lambda p: -sum((p, s) in by for s in speakers)
                     )[:n_phrases]
    phrases.sort()

    fig, axes = plt.subplots(len(phrases), len(speakers),
                             figsize=(1.35 * len(speakers) + 2.6,
                                      1.35 * len(phrases) + 1.2))
    axes = np.atleast_2d(axes)
    for r, p in enumerate(phrases):
        for c_i, s in enumerate(speakers):
            ax = axes[r, c_i]
            ax.set_xticks([]); ax.set_yticks([])
            for sp in ax.spines.values():
                sp.set_color(GRID)
            path = by.get((p, s))
            if path:
                crops = _crops_of(path, cropper)
                if crops:
                    ax.imshow(crops[len(crops) // 2], cmap="gray",
                              vmin=0, vmax=255)
                    continue
            ax.set_facecolor("#F9FAFB")
            ax.text(0.5, 0.5, "-", ha="center", va="center", color=GRID,
                    transform=ax.transAxes)
    for r, p in enumerate(phrases):
        axes[r, 0].set_ylabel(f"{p}\n{_phrase_label(spec, p, 14)}",
                              fontsize=9, rotation=0, ha="right",
                              va="center", labelpad=10, color=INK)
    for c_i, s in enumerate(speakers):
        axes[0, c_i].set_title(s, fontsize=10, pad=6)
    fig.suptitle("The same phrase, different speakers", x=0.009, y=1.0,
                 ha="left", fontsize=14, fontweight="bold")
    fig.tight_layout()
    return save(fig, "fig06_speaker_grid", out, cfg)


def fig_motion(clips: list[dict], spec: dict, cropper, out: Path,
               n_phrases: int = 4, per_phrase: int = 4,
               cfg: Config | None = None) -> Path:
    """Mouth movement over the three seconds, phrase by phrase.

    Frame-to-frame change inside the crop, which needs no extra landmarks
    and is exactly the signal the convolutions are given. Different phrases
    having visibly different envelopes is the evidence that there is
    something in these videos to learn at all.
    """
    plt = style()
    by: dict[str, list[str]] = defaultdict(list)
    for c in clips:
        by[c["phrase"]].append(c["path"])
    phrases = sorted(by, key=lambda p: -len(by[p]))[:n_phrases]
    phrases.sort()
    if not phrases:
        return Path()

    fig, axes = plt.subplots(1, len(phrases), figsize=(3.4 * len(phrases), 3.9),
                             sharey=True)
    axes = np.atleast_1d(axes)
    for ax, p in zip(axes, phrases):
        curves = []
        for path in by[p][:per_phrase]:
            crops = _crops_of(path, cropper)
            if len(crops) < 4:
                continue
            a = np.stack(crops).astype(np.float32) / 255.0
            d = np.abs(np.diff(a, axis=0)).mean(axis=(1, 2))
            # A three-frame mean. Camera noise at 16 fps is jagged enough to
            # bury the envelope; the axis label says the smoothing is there.
            curves.append(np.convolve(d, np.ones(3) / 3, mode="same"))
        if not curves:
            ax.axis("off")
            continue
        M = np.stack(curves)
        t = np.arange(M.shape[1]) / TARGET_FPS
        for row in M:
            ax.plot(t, row, color=PRIMARY, alpha=0.22, lw=1.1)
        ax.plot(t, M.mean(0), color=PRIMARY, lw=2.8)
        ax.set_title(f"{p}  {_phrase_label(spec, p, 16)}", loc="left",
                     fontsize=11)
        ax.set_xlabel("seconds")
        ax.yaxis.grid(True, color=GRID, lw=0.8)
        ax.set_axisbelow(True)
    axes[0].set_ylabel("mouth movement\n(3-frame mean)")
    fig.suptitle("Mouth movement over the three-second window",
                 x=0.009, y=1.02, ha="left", fontsize=14, fontweight="bold")
    fig.tight_layout()
    return save(fig, "fig07_motion", out, cfg)


# =============================================  3. the system, as a diagram
def fig_pipeline(out: Path, cfg: Config | None = None) -> Path:
    """Phone to phrase, in one strip. The slide that explains the project."""
    from matplotlib.patches import FancyArrowPatch, FancyBboxPatch
    plt = style()

    steps = [
        ("Camera", "3 s video\nfront camera\nno audio, ever"),
        ("Face mesh", "MediaPipe\n468 landmarks\nper frame"),
        ("Align & crop", f"eye-levelled\n{CROP}x{CROP} grey\n{FRAMES} frames"),
        ("3D CNN", "5 Conv3D\n+ 2 Conv1D\n192-d embedding"),
        ("Personalise", "blend with the\nuser's own\nprototypes"),
        ("Phrase", "1 of 20\nspoken aloud\nby the phone"),
    ]
    fig, ax = plt.subplots(figsize=(13.5, 3.0))
    ax.set_xlim(-0.04, len(steps) + 0.04)
    ax.set_ylim(0, 1); ax.axis("off")
    for i, (title, body) in enumerate(steps):
        last = i == len(steps) - 1
        ax.add_patch(FancyBboxPatch(
            (i + 0.06, 0.2), 0.88, 0.62,
            boxstyle="round,pad=0.015,rounding_size=0.04",
            linewidth=1.6, edgecolor=PRIMARY if not last else GOOD,
            facecolor="#EEF2FF" if not last else "#ECFDF5"))
        ax.text(i + 0.5, 0.715, title, ha="center", va="center", fontsize=13,
                fontweight="bold", color=INK)
        ax.text(i + 0.5, 0.44, body, ha="center", va="center", fontsize=10.5,
                color=MUTED, linespacing=1.5)
        if not last:
            ax.add_patch(FancyArrowPatch(
                (i + 0.95, 0.51), (i + 1.045, 0.51),
                arrowstyle="-|>", mutation_scale=17, color=MUTED, lw=1.5))
    ax.text(0.06, 0.06, "Everything above runs on the phone. No audio is "
                        "recorded at any stage.",
            fontsize=11, color=MUTED)
    fig.suptitle("ANTARVANI: camera to phrase", x=0.009, y=1.02, ha="left",
                 fontsize=16, fontweight="bold")
    return save(fig, "fig08_pipeline", out, cfg)


def fig_architecture(out: Path, n_classes: int = 20,
                     cfg: Config | None = None) -> Path:
    """The network as a stack of boxes, each the width of its tensor."""
    from matplotlib.patches import FancyBboxPatch
    plt = style()

    t, h, w = FRAMES, CROP, CROP
    rows = [("input", f"{t}x{h}x{w}x1", 0)]
    for f, (st, sh, sw) in [(32, (1, 2, 2)), (64, (1, 2, 2)), (96, (2, 2, 2)),
                            (128, (2, 2, 2)), (128, (1, 2, 2))]:
        prev_c = rows[-1][1].split("x")[-1]
        t, h, w = math.ceil(t / st), math.ceil(h / sh), math.ceil(w / sw)
        params = 27 * int(prev_c) * f
        rows.append((f"Conv3D {f}  stride {st}{sh}{sw}", f"{t}x{h}x{w}x{f}",
                     params))
    flat = h * w * 128
    rows.append(("Reshape", f"{t}x{flat}", 0))
    rows.append(("Conv1D 192", f"{t}x192", 3 * flat * 192))
    rows.append(("Conv1D 192", f"{t}x192", 3 * 192 * 192))
    rows.append(("GlobalAvgPool  -> embedding", "192", 0))
    rows.append((f"Dropout 0.5 + Dense {n_classes}", f"{n_classes}",
                 192 * n_classes))

    # A box as wide as its tensor is big, on a log scale — the funnel from
    # 372k values down to 20 is the shape of the network, and a column of
    # equal boxes would hide it.
    def volume(shape: str) -> float:
        n = 1
        for part in shape.split("x"):
            n *= int(part)
        return n

    vols = [math.log10(volume(sh)) for _, sh, _ in rows]
    lo, hi = min(vols), max(vols)
    span = (hi - lo) or 1.0
    total = sum(p for _, _, p in rows)

    fig, ax = plt.subplots(figsize=(10.5, 0.58 * len(rows) + 1.5))
    ax.set_xlim(0, 10); ax.set_ylim(-0.9, len(rows)); ax.axis("off")
    for i, (name, shape, params) in enumerate(rows):
        y = len(rows) - i - 1
        width = 1.5 + 4.8 * ((vols[i] - lo) / span)
        shade = SEQ[min(int(round(i / max(1, len(rows) - 1) * (len(SEQ) - 1))),
                        len(SEQ) - 1)]
        ax.add_patch(FancyBboxPatch(
            (0.25, y + 0.16), width, 0.68,
            boxstyle="round,pad=0.01,rounding_size=0.06",
            linewidth=1.4, edgecolor=PRIMARY, facecolor=shade))
        # A label wider than its box goes beside it rather than running
        # off the end of a dark rectangle onto white paper.
        dark = SEQ.index(shade) >= 5
        fits = 0.082 * len(name) + 0.35 < width
        ax.text(0.45 if fits else 0.25 + width + 0.22, y + 0.5, name,
                va="center", fontsize=11, fontweight="bold",
                color=("white" if dark else INK) if fits else INK)
        ax.text(6.7, y + 0.5, shape, va="center", fontsize=10.5,
                color=MUTED, family="monospace")
        if params:
            ax.text(9.9, y + 0.5, f"{params / 1000:.0f}k", va="center",
                    ha="right", fontsize=10, color=MUTED)
    ax.text(6.7, len(rows) - 0.1, "output shape", fontsize=9.5, color=MUTED)
    ax.text(9.9, len(rows) - 0.1, "weights", fontsize=9.5, color=MUTED,
            ha="right")
    fig.subplots_adjust(top=0.94, bottom=0.02)
    fig.suptitle(f"Network  -  {total / 1e6:.2f} M parameters, 3.56 MB as "
                 f"TFLite float16", x=0.009, y=1.0, ha="left", fontsize=15,
                 fontweight="bold")
    ax.text(0.25, -0.55, "No MaxPool3D and no GRU: TFLite has neither, so the "
                         "downsampling is strided convolution and the temporal "
                         "head is Conv1D.", fontsize=10.5, color=MUTED)
    return save(fig, "fig09_architecture", out, cfg)


# ================================================  4. results, if they exist
def results_dir(model_dir: Path) -> Path | None:
    """The folder holding the newest run's results.json.

    Training writes each run to models/<lang>/v1, v2, v3... so pointing at
    models/<lang> itself finds nothing. Newest wins, by version number
    rather than by name, so v10 sorts after v9.
    """
    d = Path(model_dir)
    if (d / "results.json").is_file():
        return d
    runs = []
    for p in d.glob("v*"):
        if p.is_dir() and (p / "results.json").is_file():
            try:
                runs.append((int(p.name[1:]), p))
            except ValueError:
                continue
    return max(runs)[1] if runs else None


def load_results(model_dir: Path) -> dict | None:
    d = results_dir(model_dir)
    if d is None:
        return None
    try:
        return json.loads((d / "results.json").read_text(encoding="utf-8"))
    except Exception:
        return None


def fig_confusion(res: dict, spec: dict, out: Path,
                  cfg: Config | None = None) -> Path:
    plt = style()
    cv = res.get("crossValidation", {})
    cm = np.array(cv.get("confusion") or [], float)
    if cm.size == 0:
        return Path()
    ids = [p["id"] for p in spec["phrases"]][: cm.shape[0]]
    norm = cm / np.clip(cm.sum(1, keepdims=True), 1, None)

    fig, ax = plt.subplots(figsize=(9.6, 8.4))
    im = ax.imshow(norm, cmap="Purples", vmin=0, vmax=1)
    ax.set_xticks(range(len(ids))); ax.set_xticklabels(ids, rotation=90, fontsize=9)
    ax.set_yticks(range(len(ids))); ax.set_yticklabels(ids, fontsize=9)
    ax.set_xlabel("predicted"); ax.set_ylabel("spoken")
    for i in range(len(ids)):
        v = norm[i, i]
        if v > 0.01:
            ax.text(i, i, f"{v * 100:.0f}", ha="center", va="center",
                    fontsize=8, color="white" if v > 0.5 else INK)
    fig.colorbar(im, ax=ax, fraction=0.045, label="share of that phrase")
    ax.set_title(f"Confusion, leave-speakers-out  -  "
                 f"top-1 {100 * cv.get('top1', 0):.1f}%", loc="left", pad=12)
    return save(fig, "fig10_confusion", out, cfg)


def fig_per_phrase(res: dict, spec: dict, out: Path,
                   cfg: Config | None = None) -> Path:
    plt = style()
    cv = res.get("crossValidation", {})
    per = cv.get("perClass") or {}
    if not per:
        return Path()
    ids = [p["id"] for p in spec["phrases"] if per.get(p["id"]) is not None]
    vals = [100 * per[i] for i in ids]
    order = np.argsort(vals)
    ids = [ids[i] for i in order]; vals = [vals[i] for i in order]
    chance = 100 * cv.get("chance", 0.05)

    fig, ax = plt.subplots(figsize=(10, 0.34 * len(ids) + 2.2))
    colors = [GOOD if v >= 2 * chance else WARN if v >= chance else BAD
              for v in vals]
    ax.barh(range(len(ids)), vals, color=colors)
    ax.set_yticks(range(len(ids)))
    ax.set_yticklabels([f"{i}  {_phrase_label(spec, i, 20)}" for i in ids],
                       fontsize=9)
    ax.axvline(chance, color=INK, lw=1.3, ls="--")
    ax.text(chance, len(ids) - 0.4, f" chance {chance:.0f}%", fontsize=10,
            color=INK)
    ax.set_xlabel("accuracy (%)")
    ax.xaxis.grid(True, color=GRID, lw=0.8)
    ax.set_axisbelow(True)
    ax.set_title("Accuracy per phrase", loc="left", pad=10)
    return save(fig, "fig11_per_phrase", out, cfg)


def fig_folds(res: dict, out: Path, cfg: Config | None = None) -> Path:
    plt = style()
    cv = res.get("crossValidation", {})
    accs = [100 * a for a in (cv.get("foldTop1") or [])]
    if not accs:
        return Path()
    chance = 100 * cv.get("chance", 0.05)
    fig, ax = plt.subplots(figsize=(7.6, 4.4))
    ax.bar(range(1, len(accs) + 1), accs, color=PRIMARY, width=0.62)
    ax.axhline(chance, color=INK, ls="--", lw=1.3)
    ax.text(len(accs) + 0.45, chance, " chance", va="center", fontsize=10)
    ax.axhline(float(np.mean(accs)), color=GOOD, lw=1.6)
    ax.text(0.55, np.mean(accs), f" mean {np.mean(accs):.1f}%", va="bottom",
            fontsize=11, color=GOOD, fontweight="bold")
    ax.set_xticks(range(1, len(accs) + 1))
    ax.set_xlabel("fold (each tests on speakers no model in it has seen)")
    ax.set_ylabel("top-1 (%)")
    ax.yaxis.grid(True, color=GRID, lw=0.8)
    ax.set_axisbelow(True)
    ax.set_title("Cross-validation by fold", loc="left")
    return save(fig, "fig12_folds", out, cfg)


def fig_training(res: dict, out: Path, cfg: Config | None = None) -> Path:
    """Loss and training accuracy over the epochs, one line per fold.

    The figure that settles the argument. If these curves climb to the top
    and the held-out bar stays at chance, the model learned the training
    speakers and nothing general — overfitting. If they never leave chance,
    nothing was learned at all and the fault is upstream of the model. A
    reader can see which in one glance, which is why it belongs in the
    paper rather than only in a log.
    """
    plt = style()
    cv = res.get("crossValidation", {})
    hists = [h for h in (cv.get("foldHistory") or []) if h.get("accuracy")]
    if not hists:
        return Path()
    chance = 100 * cv.get("chance", 0.05)
    held = 100 * cv.get("top1", 0)

    fig, axes = plt.subplots(1, 2, figsize=(11.6, 4.4))
    for i, h in enumerate(hists):
        ep = np.arange(1, len(h["accuracy"]) + 1)
        shade = SEQ[min(2 + i, len(SEQ) - 1)]
        axes[0].plot(ep, h.get("loss", []), color=shade, lw=2,
                     label=f"fold {i + 1}")
        axes[1].plot(ep, [100 * a for a in h["accuracy"]], color=shade, lw=2,
                     label=f"fold {i + 1}")

    axes[0].set_ylabel("training loss")
    axes[1].set_ylabel("training accuracy (%)")
    axes[1].axhline(chance, color=INK, ls="--", lw=1.3)
    axes[1].text(1, chance, f" chance {chance:.0f}%", va="top", fontsize=10)
    # When the model is at chance the two lines coincide and their labels
    # print on top of each other, which is the one case where this figure
    # most needs to be readable.
    if abs(held - chance) > 0.5:
        axes[1].axhline(held, color=GOOD, lw=1.8)
        axes[1].text(1, held, f" held-out speakers {held:.1f}%", va="bottom",
                     fontsize=10, color=GOOD, fontweight="bold")
    else:
        axes[1].text(0.99, 0.04,
                     f"held-out speakers {held:.1f}% — at chance",
                     transform=axes[1].transAxes, ha="right", fontsize=10.5,
                     color=BAD, fontweight="bold")
    for a in axes:
        a.set_xlabel("epoch")
        a.yaxis.grid(True, color=GRID, lw=0.8)
        a.set_axisbelow(True)
    if len(hists) > 1:
        axes[1].legend(ncol=min(len(hists), 5), fontsize=9.5)

    fig.suptitle("Training curves, fold by fold", x=0.009, y=1.02, ha="left",
                 fontsize=14, fontweight="bold")
    fig.tight_layout()
    return save(fig, "fig16_training", out, cfg)


def fig_personalisation(res: dict, out: Path,
                        cfg: Config | None = None) -> Path:
    """The project's own contribution: what a handful of the user's own
    recordings is worth."""
    plt = style()
    pers = res.get("personalisation") or {}
    shots = pers.get("shots") or {}
    if not shots:
        return Path()
    ks = sorted(int(k) for k in shots)
    base = [100 * shots[str(k)]["base"] for k in ks]
    done = [100 * shots[str(k)]["personalised"] for k in ks]

    fig, ax = plt.subplots(figsize=(8.4, 4.8))
    ax.plot(ks, base, color=MUTED, lw=2.2, marker="o", ms=7,
            label="model alone")
    ax.plot(ks, done, color=PRIMARY, lw=3, marker="o", ms=8,
            label="with the user's own clips")
    ax.fill_between(ks, base, done, color=PRIMARY_SOFT, alpha=0.6)
    for k, b, d in zip(ks, base, done):
        if d - b > 0.3:
            ax.annotate(f"+{d - b:.0f} pts", xy=(k, (b + d) / 2), fontsize=10.5,
                        ha="center", color=PRIMARY, fontweight="bold")
    ax.set_xticks(ks)
    ax.margins(x=0.09)
    ax.set_xlabel("clips per phrase recorded by the user")
    ax.set_ylabel("top-1 (%)")
    ax.yaxis.grid(True, color=GRID, lw=0.8)
    ax.set_axisbelow(True)
    ax.legend(loc="lower right")
    ax.set_title("Few-shot personalisation", loc="left")
    return save(fig, "fig13_personalisation", out, cfg)


def fig_speakers(res: dict, out: Path, cfg: Config | None = None) -> Path:
    plt = style()
    per = (res.get("crossValidation") or {}).get("perSpeaker") or {}
    if not per:
        return Path()
    ids = sorted(per, key=lambda s: per[s])
    vals = [100 * per[i] for i in ids]
    chance = 100 * (res.get("crossValidation") or {}).get("chance", 0.05)
    fig, ax = plt.subplots(figsize=(10, 0.3 * len(ids) + 2.2))
    ax.barh(range(len(ids)), vals, color=PRIMARY)
    ax.set_yticks(range(len(ids))); ax.set_yticklabels(ids, fontsize=9)
    ax.axvline(chance, color=INK, ls="--", lw=1.3)
    ax.set_xlabel("top-1 (%)")
    ax.xaxis.grid(True, color=GRID, lw=0.8)
    ax.set_axisbelow(True)
    ax.set_title("Accuracy per held-out speaker", loc="left", pad=10)
    return save(fig, "fig14_speakers", out, cfg)


def fig_summary(res: dict, clips: list[dict], spec: dict, out: Path,
                cfg: Config | None = None) -> Path:
    """One slide with the headline numbers, honestly labelled."""
    plt = style()
    cv = res.get("crossValidation") or {}
    pers = res.get("personalisation") or {}
    shots = pers.get("shots") or {}
    best = max((v.get("personalised", 0) for v in shots.values()), default=0)
    fig = plt.figure(figsize=(12.5, 4.2))
    gs = fig.add_gridspec(2, 1, height_ratios=[1, 0.5], hspace=0.1)
    _tiles(fig.add_subplot(gs[0]), [
        (f"{100 * cv.get('top1', 0):.1f}%", "top-1, unseen speaker"),
        (f"{100 * cv.get('top3', 0):.1f}%", "top-3, unseen speaker"),
        (f"{100 * best:.1f}%", "with personalisation"),
        (f"{100 * cv.get('chance', 0.05):.0f}%", "chance", MUTED),
    ])
    ax = fig.add_subplot(gs[1]); ax.axis("off")
    ax.text(0.5, 0.75,
            f"{len({c['speaker'] for c in clips})} speakers, {len(clips)} clips, "
            f"{len(spec['phrases'])} phrases, "
            f"{cv.get('folds', 0)}-fold leave-speakers-out",
            ha="center", fontsize=12.5, color=INK)
    ax.text(0.5, 0.3,
            "Every test clip was predicted by a model that never saw that "
            "person. Standard deviation across folds "
            f"{100 * cv.get('top1Std', 0):.1f} points.",
            ha="center", fontsize=11, color=MUTED)
    return save(fig, "fig15_summary", out, cfg)


# ==========================================  5. hand it all to the website
WEB_FIGURES = [
    ("fig01_corpus.png", "corpus", True, "The corpus at a glance",
     "Speakers, clips, how evenly the twenty phrases are covered, and how "
     "complete each session is."),
    ("fig02_coverage.png", "corpus", True, "Who recorded what",
     "One square per speaker and phrase. The gaps are the sessions still to "
     "finish."),
    ("fig03_timeline.png", "corpus", False, "Collection timeline",
     "How the corpus grew, day by day."),
    ("fig04_face_crop.png", "corpus", True, "Finding the mouth",
     "The box is rotated to level the eyes and scaled by the distance "
     "between them, so the mouth fills the same area whatever the camera "
     "distance."),
    ("fig05_sequence.png", "corpus", True, "One utterance, as the model gets it",
     "Forty-eight frames of 88x88 greyscale over three seconds. This is the "
     "model's entire input."),
    ("fig06_speaker_grid.png", "corpus", True, "The same phrase, different people",
     "What the model has to see past: every face makes these shapes "
     "differently."),
    ("fig07_motion.png", "corpus", True, "Mouth movement over three seconds",
     "Different phrases have visibly different envelopes, which is the "
     "evidence that there is something here to learn."),
    ("fig08_pipeline.png", "model", True, "Camera to phrase",
     "Every stage runs on the phone. No audio is recorded at any point."),
    ("fig09_architecture.png", "model", True, "The network",
     "Each box is as wide as its tensor: 372k values in, twenty out."),
    ("fig15_summary.png", "results", True, "Headline",
     "Leave-speakers-out, so no test clip was predicted by a model that had "
     "met that person."),
    ("fig12_folds.png", "results", False, "Fold by fold",
     "How much the result moves depending on which speakers are held out."),
    ("fig10_confusion.png", "results", True, "Confusion",
     "Which phrases get mistaken for which."),
    ("fig11_per_phrase.png", "results", False, "Accuracy per phrase",
     "Phrase by phrase, against the one-in-twenty baseline."),
    ("fig14_speakers.png", "results", False, "Accuracy per held-out speaker",
     "Some faces are much easier than others - the gap personalisation is "
     "meant to close."),
    ("fig16_training.png", "results", True, "Training curves",
     "Training loss and accuracy per epoch, with the held-out result marked. "
     "Curves that climb while the held-out line stays low mean overfitting; "
     "curves that never leave chance mean nothing was learned."),
    ("fig13_personalisation.png", "results", True, "Few-shot personalisation",
     "What a handful of the user's own recordings is worth."),
]


def export_web(figs: Path, clips: list[dict], spec: dict, res: dict | None,
               out: Path, cropper=None, face_speaker: str = "",
               cfg: Config | None = None) -> Path:
    """Builds the folder the website reads: figures.json and the PNGs.

    Only figures that were actually produced go into the manifest, so the
    site never shows a broken frame, and `results` stays null until there
    is a run to report. The site is built to handle both.
    """
    import shutil

    out = Path(out)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    listed = []
    for name, group, wide, title, caption in WEB_FIGURES:
        src = Path(figs) / name
        if not src.is_file():
            continue
        shutil.copy2(src, out / name)
        listed.append({"file": name, "group": group, "wide": wide,
                       "title": title, "caption": caption})

    # The hero filmstrip. Mouth crops only, and only from a speaker who has
    # agreed to appear - this one goes on a public page.
    strip, who = [], ""
    if face_speaker and cropper is not None:
        clip = next((c for c in clips if c["speaker"] == face_speaker), None)
        if clip is not None:
            crops = _crops_of(clip["path"], cropper)
            import cv2
            for i, idx in enumerate(np.linspace(0, max(0, len(crops) - 1), 16,
                                                dtype=int)):
                name = f"strip_{i:02d}.png"
                cv2.imwrite(str(out / name), crops[int(idx)])
                strip.append(name)
            who = f"{face_speaker} · team member, recorded with consent"

    speakers = {c["speaker"] for c in clips}
    full = sum(1 for s in speakers
               if len({c["phrase"] for c in clips if c["speaker"] == s})
               >= len(spec["phrases"]))

    payload = {
        "generatedUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "corpus": {
            "speakers": len(speakers),
            "clips": len(clips),
            "phrases": len(spec["phrases"]),
            "minutes": round(len(clips) * 3.0 / 60),
            "completeSpeakers": full,
        },
        "strip": strip,
        "stripWho": who,
        "figures": listed,
        "results": None,
    }

    if res:
        cv = res.get("crossValidation") or {}
        shots = (res.get("personalisation") or {}).get("shots") or {}
        best_k, best_v = "", 0.0
        for k, v in shots.items():
            if v.get("personalised", 0) > best_v:
                best_k, best_v = k, v["personalised"]
        top1 = cv.get("top1", 0.0)
        chance = cv.get("chance", 1 / max(1, len(spec["phrases"])))
        payload["results"] = {
            "top1": top1,
            "top3": cv.get("top3", 0.0),
            "chance": chance,
            "top1Std": cv.get("top1Std", 0.0),
            "folds": cv.get("folds", 0),
            # Said plainly in the data, so the site cannot dress it up.
            "atChance": bool(top1 <= chance * 1.3),
            "protocol": f"{cv.get('folds', 0)}-fold leave-speakers-out",
            **({"personalisedBest": best_v,
                "personalisedShots": int(best_k)} if best_v else {}),
        }

    (out / "figures.json").write_text(
        json.dumps(payload, indent=1, ensure_ascii=False), encoding="utf-8")

    if cfg is not None:
        cfg.say(f"web export: {len(listed)} figures + figures.json -> {out}")
        if payload["results"] is None:
            cfg.say("  (no results.json yet - the site will say so itself)")
        elif payload["results"]["atChance"]:
            cfg.say("  (the run is at chance; the site will say so plainly)")
    return out


# ===================================  6. one zip holding the whole outcome
def bundle_results(figs: Path, web: Path, model_dir: Path,
                   clips: list[dict], spec: dict, out_zip: str,
                   cfg: Config | None = None) -> str:
    """Everything a report, a deck or a paper could need, in one archive.

    Pulled together rather than listed by hand, because the thing that goes
    wrong with "send me the results" is always the one file nobody thought
    to include. What goes in:

        results/   results.json, the model card, which speakers trained it
        figures/   every figure, PNG for slides and PDF for the paper
        web/       what the website reads
        corpus/    counts and a manifest, speaker IDs only

    No volunteer names anywhere: the pipeline only ever knows a speaker by
    the number in the filename, so there are none to leak.
    """
    import csv
    import platform
    import shutil
    from collections import Counter

    stage = Path(out_zip).with_suffix("")
    if stage.exists():
        shutil.rmtree(stage)
    for sub in ("results", "figures", "web", "corpus"):
        (stage / sub).mkdir(parents=True)

    # ---- the run itself
    rdir = results_dir(Path(model_dir))
    got_results = False
    if rdir is not None:
        for f in sorted(rdir.iterdir()):
            # The .tflite is the one thing nobody reading a report needs,
            # and it is most of the megabytes.
            if f.is_file() and f.suffix != ".tflite":
                shutil.copy2(f, stage / "results" / f.name)
        got_results = True
    hist = Path(model_dir) / "speakers_history.json"
    if hist.is_file():
        shutil.copy2(hist, stage / "results" / hist.name)

    # ---- figures
    n_figs = 0
    for f in sorted(Path(figs).glob("*")):
        if f.suffix.lower() in (".png", ".pdf"):
            shutil.copy2(f, stage / "figures" / f.name)
            n_figs += f.suffix.lower() == ".png"

    # ---- what the website reads
    if Path(web).is_dir():
        for f in sorted(Path(web).iterdir()):
            if f.is_file():
                shutil.copy2(f, stage / "web" / f.name)

    # ---- the corpus, in numbers
    speakers = sorted({c["speaker"] for c in clips})
    ids = [p["id"] for p in spec["phrases"]]
    per_phrase = Counter(c["phrase"] for c in clips)
    per_speaker = Counter(c["speaker"] for c in clips)
    phrases_of = {s: len({c["phrase"] for c in clips if c["speaker"] == s})
                  for s in speakers}
    summary = {
        "generatedUtc": datetime.now(timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "language": spec.get("code"),
        "speakers": len(speakers),
        "clips": len(clips),
        "phrases": len(ids),
        "minutesOfVideo": round(len(clips) * 3.0 / 60, 1),
        "completeSpeakers": sum(1 for s in speakers
                                if phrases_of[s] >= len(ids)),
        "clipsPerPhrase": {i: per_phrase.get(i, 0) for i in ids},
        "clipsPerSpeaker": {s: per_speaker[s] for s in speakers},
        "phrasesPerSpeaker": phrases_of,
        "coverageFilled": sum(1 for s in speakers for i in ids
                              if any(c["speaker"] == s and c["phrase"] == i
                                     for c in clips)),
        "coverageCells": len(speakers) * len(ids),
    }
    (stage / "corpus" / "corpus_summary.json").write_text(
        json.dumps(summary, indent=1), encoding="utf-8")

    with (stage / "corpus" / "manifest.csv").open(
            "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["speaker", "phrase", "take", "file"])
        for c in sorted(clips, key=lambda c: (c["speaker"], c["phrase"],
                                              c.get("take", 1))):
            w.writerow([c["speaker"], c["phrase"], c.get("take", 1),
                        Path(c["path"]).name])

    # ---- enough about the machine to write a Methods paragraph
    try:
        import tensorflow as tf
        tf_v = tf.__version__
    except Exception:
        tf_v = "not imported"
    (stage / "corpus" / "environment.txt").write_text(
        f"python {platform.python_version()}\n"
        f"platform {platform.platform()}\n"
        f"numpy {np.__version__}\n"
        f"tensorflow {tf_v}\n"
        f"frames {FRAMES}  crop {CROP}  fps {TARGET_FPS}\n",
        encoding="utf-8")

    (stage / "README.txt").write_text(
        "ANTARVANI — results bundle\n"
        f"made {datetime.now(timezone.utc):%Y-%m-%d %H:%M UTC}\n\n"
        "results/   results.json (accuracy, confusion, personalisation),\n"
        "           the model card, and trained_speakers.json saying which\n"
        "           speakers the model was trained on.\n"
        "           " + ("present\n" if got_results else
                         "EMPTY - no training run found yet.\n") +
        "figures/   every figure. PNG for slides, PDF for the paper.\n"
        "web/       figures.json and the images the website reads.\n"
        "corpus/    corpus_summary.json, manifest.csv, environment.txt.\n\n"
        "Speakers appear as numbers only. No volunteer's name is in this\n"
        "archive, and none should ever be added to it.\n",
        encoding="utf-8")

    path = shutil.make_archive(str(stage), "zip", stage)
    shutil.rmtree(stage)
    mb = Path(path).stat().st_size / 1e6
    if cfg is not None:
        cfg.say(f"bundle: {Path(path).name}  ({mb:.1f} MB, "
                f"{n_figs} figures, results {'yes' if got_results else 'NO'})")
    return path
