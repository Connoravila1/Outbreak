"""Registry, raw-file loader and the output stage (loudness, fades, mp3, manifest)."""
from __future__ import annotations

import json
import os
import sys

import numpy as np
import soundfile as sf

import dsp
from dsp import SR

RAW = os.environ.get("OUTBREAK_SOUND_RAW", "")
OUT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "public", "audio"))

# Where each recorded source lives under RAW (one folder per downloaded pack).
KI = "oga-interface-sounds/Audio/"            # Kenney Interface Sounds (CC0)
RPG = "oga-rpg-sound-pack/RPG Sound Pack/"    # RPG Sound Pack by artisticdude (CC0)
R50 = "oga-50-rpg-sound-effects/OGG/"         # Kenney RPG Audio (CC0)
SCIFI = "oga-sci-fi-sounds/Audio/"            # Kenney Sci-Fi Sounds (CC0)
G16 = "oga-16-monster-growls/"                # 16 Monster Growls by StarNinjas (CC0)
UI51 = "oga-51-ui-sound-effects-buttons-switches-and-clicks/"  # Kenney UI Audio (CC0)
WIND = "oga-mild-wind-background-noise/wind_background_noise_2.wav"
BREATH = "oga-horror-breathing/horrorbreathing/horrorbreathing.wav"
STATIC = "oga-frequency-static-sound-effects/static1.wav"
HEART = "oga-heartbeat-sounds/"

_cache: dict[str, np.ndarray] = {}


def raw(rel: str, start: float = 0.0, end: float | None = None, do_trim: bool = True) -> np.ndarray:
    """A recorded source as mono float32 at SR, optionally cut to [start, end) seconds."""
    if rel not in _cache:
        x, sr = sf.read(os.path.join(RAW, rel), always_2d=True, dtype="float32")
        _cache[rel] = dsp.to_sr(x.mean(1), sr)
    x = _cache[rel]
    i = dsp.n_of(start)
    j = dsp.n_of(end) if end is not None else len(x)
    y = x[i:j]
    y = y - y.mean()
    if end is not None:
        y = dsp.fade(y, 0.0, 0.012)
    if do_trim:
        y = dsp.trim(y, -55)
    return y.astype(np.float32)


def rawn(rel: str, **kw) -> np.ndarray:
    """raw() peak-normalised to 0 dBFS so layers can be balanced by gain alone."""
    return dsp.norm(raw(rel, **kw), 0.0)


# ---------- registry ----------

SOUNDS: dict[str, dict] = {}
# momentary-loudness ceilings (LUFS) per category; peaks are held at the file's `peak` setting
TARGET = {"ui": -23.0, "sfx": -18.0, "reward": -17.0, "stinger": -15.0, "alarm": -11.0,
          "onboard": -16.0, "amb": -34.0, "music": -22.0}
PEAK = {"ui": -3.0, "sfx": -3.0, "reward": -3.0, "stinger": -3.0, "alarm": -1.5,
        "onboard": -3.0, "amb": -6.0, "music": -3.0}
BUS = {"ui": "ui", "sfx": "sfx", "reward": "sfx", "stinger": "sfx", "alarm": "sfx", "onboard": "sfx",
       "amb": "ambience", "music": "music"}


def snd(key: str, cat: str, kbps: int = 96, fin: float = 0.005, fout: float = 0.005, loop: bool = False,
        note: str = "", gain_db: float = 0.0, maxdur: float = 0.0):
    def deco(fn):
        SOUNDS[key] = dict(fn=fn, cat=cat, kbps=kbps, fin=fin, fout=fout, loop=loop, note=note, gain_db=gain_db, maxdur=maxdur)
        return fn
    return deco


def finish(key: str, spec: dict, x: np.ndarray) -> tuple[np.ndarray, dict]:
    """Trim, fade, set level by peak and loudness ceiling, and describe the result."""
    cat = spec["cat"]
    if not spec["loop"]:
        x = dsp.trim(x, -52, keep_tail=0.01)
        if spec["maxdur"] and len(x) > dsp.n_of(spec["maxdur"]):
            x = x[: dsp.n_of(spec["maxdur"])]
            spec = dict(spec, fout=0.3)
    x = x - x.mean(axis=0)  # kill DC
    x = dsp.fade(x, spec["fin"], spec["fout"]) if not spec["loop"] else x
    g_peak = dsp.db(PEAK[cat]) / max(dsp.peak(x), 1e-9)
    lufs = dsp.momentary_lufs(x * g_peak)
    g = g_peak * dsp.db(min(0.0, TARGET[cat] - lufs)) * dsp.db(spec["gain_db"])
    y = (x * g).astype(np.float32)
    return y, dict(lufs=dsp.momentary_lufs(y))


def build_all(only: str | None = None) -> dict:
    os.makedirs(OUT, exist_ok=True)
    manifest = {}
    for key, spec in SOUNDS.items():
        if only and not key.startswith(only):
            continue
        dsp.reseed(sum(map(ord, key)) * 7919)
        x = spec["fn"]()
        y, meta = finish(key, spec, x)
        sub = "bed" if spec["cat"] in ("amb", "music") else "sfx"
        os.makedirs(os.path.join(OUT, sub), exist_ok=True)
        rel = f"{sub}/{key}.mp3"
        dsp.encode_mp3(y, os.path.join(OUT, rel), spec["kbps"] if y.ndim == 1 else max(spec["kbps"], 96))
        manifest[key] = dict(file=rel, frames=int(len(y)), rate=SR, ch=1 if y.ndim == 1 else y.shape[1],
                             dur=round(len(y) / SR, 3), cat=spec["cat"], bus=BUS[spec["cat"]], loop=spec["loop"],
                             note=spec["note"])
        if spec["loop"] and spec["cat"] in ("amb", "music"):
            m = y.mean(axis=1) if y.ndim == 2 else y
            w = dsp.n_of(0.05)
            r = lambda a: 20 * np.log10(np.sqrt((a ** 2).mean()) + 1e-9)
            manifest[key]["seam_db"] = round(float(r(m[-w:]) - r(m[:w])), 2)
            manifest[key]["jump"] = round(float(abs(m[0] - m[-1]) / (np.abs(np.diff(m)).mean() + 1e-9)), 2)
        print(f"{key:24s} {len(y)/SR:6.2f}s {spec['cat']:8s} lufs {meta['lufs']:6.1f}", file=sys.stderr)
    return manifest


def write_manifest(m: dict) -> None:
    p = os.path.join(OUT, "manifest.json")
    old = {}
    if os.path.exists(p):
        old = json.load(open(p))
    old.update(m)
    with open(p, "w") as f:
        json.dump(dict(sorted(old.items())), f, indent=1)
