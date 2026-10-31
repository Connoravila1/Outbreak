"""Technical check of the shipped audio (decoded from the mp3s, so encoder effects show up).

usage: python qa_report.py [--png OUTDIR]
Prints one row per file: duration, peak, RMS, momentary LUFS (K-weighted, loudest 400 ms), DC offset,
leading/trailing silence, spectral centroid, and for loops the level match and sample jump at the seam.
With --png, writes spectrogram contact sheets to OUTDIR.
"""
from __future__ import annotations

import json
import math
import os
import sys

import numpy as np
import soundfile as sf

import dsp

AUDIO = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "public", "audio"))
SIL = 10 ** (-50 / 20)


def rms_db(x):
    return 20 * math.log10(math.sqrt(float((x ** 2).mean())) + 1e-9)


def analyse(path, loop):
    x, sr = sf.read(path, always_2d=True, dtype="float32")
    m = x.mean(1)
    n = len(m)
    a = np.abs(m)
    pk = 20 * math.log10(a.max() + 1e-9)
    act = np.where(a > SIL)[0]
    lead = act[0] / sr * 1000 if len(act) else n / sr * 1000
    trail = (n - 1 - act[-1]) / sr * 1000 if len(act) else 0
    k = min(len(m), 1 << 20)
    sp = np.abs(np.fft.rfft(m[:k]))
    fr = np.fft.rfftfreq(k, 1 / sr)
    cen = float((sp * fr).sum() / (sp.sum() + 1e-9))
    row = dict(dur=n / sr, pk=pk, rms=rms_db(m), lufs=dsp.momentary_lufs(x.T[0] if x.shape[1] == 1 else x),
               dc=float(m.mean()), lead=lead, trail=trail, cen=cen, sr=sr, ch=x.shape[1])
    if loop:
        w = int(0.05 * sr)
        # encoder delay shifts the decoded start by up to ~1100 samples, so compare 50 ms windows
        row["seam_db"] = rms_db(m[-w:]) - rms_db(m[:w])
        row["jump"] = float(np.abs(m[0] - m[-1]) / (np.abs(np.diff(m)).mean() + 1e-9))
    return row, m, sr


def main():
    png = sys.argv[sys.argv.index("--png") + 1] if "--png" in sys.argv else None
    man = json.load(open(os.path.join(AUDIO, "manifest.json")))
    print(f"{'key':20s} {'dur':>6s} {'peak':>6s} {'rms':>6s} {'LUFSm':>6s} {'dc':>8s} {'lead':>6s} {'trail':>6s} {'cent':>6s}  notes")
    total = 0
    sigs = {}
    bad = []
    for key, e in man.items():
        p = os.path.join(AUDIO, e["file"])
        total += os.path.getsize(p)
        r, m, sr = analyse(p, False)
        if "seam_db" in e:
            r["seam_db"], r["jump"] = e["seam_db"], e["jump"]
        sigs[key] = (m, sr)
        notes = []
        if r["pk"] > -0.5:
            notes.append("PEAK HOT")
        if abs(r["dc"]) > 0.004:
            notes.append("DC")
        if r["lead"] > 40 and e["cat"] not in ("amb", "music"):
            notes.append("lead>40ms")
        if "seam_db" in r:
            notes.append(f"seam {r['seam_db']:+.1f}dB jump x{r['jump']:.1f}")
            if abs(r["seam_db"]) > 2.0 or r["jump"] > 8:
                notes.append("SEAM?")
        if notes and any(n.isupper() or n.startswith("SEAM") or n.startswith("lead") for n in notes):
            bad.append(key)
        print(f"{key:20s} {r['dur']:6.2f} {r['pk']:6.1f} {r['rms']:6.1f} {r['lufs']:6.1f} {r['dc']:8.5f} {r['lead']:6.0f} {r['trail']:6.0f} {r['cen']:6.0f}  {' '.join(notes)}")
    print(f"\n{len(man)} files, {total/1e6:.2f} MB total. Flagged: {bad or 'none'}")
    if png:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        os.makedirs(png, exist_ok=True)
        keys = list(sigs)
        per = 12
        for g in range(0, len(keys), per):
            grp = keys[g:g + per]
            fig, axs = plt.subplots(4, 3, figsize=(15, 11))
            for ax, k in zip(axs.flat, grp):
                m, sr = sigs[k]
                ax.specgram(m, NFFT=1024 if len(m) / sr < 5 else 4096, Fs=sr, noverlap=512 if len(m) / sr < 5 else 2048, cmap="magma", vmin=-120, vmax=-20)
                ax.set_ylim(0, 12000 if len(m) / sr < 5 else 6000)
                ax.set_title(f"{k}  {len(m)/sr:.1f}s", fontsize=9)
            for ax in list(axs.flat)[len(grp):]:
                ax.axis("off")
            fig.tight_layout()
            fig.savefig(os.path.join(png, f"spec_{g // per:02d}.png"), dpi=60)
            plt.close(fig)
        print("spectrograms in", png)


if __name__ == "__main__":
    main()
