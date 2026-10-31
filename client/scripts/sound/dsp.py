"""Small DSP toolkit for building the Outbreak sound set offline.

Everything is float32 mono at SR unless a function says stereo. Needs numpy, scipy, soundfile and
lameenc (pip install numpy scipy soundfile lameenc matplotlib).
"""
from __future__ import annotations

import math
from fractions import Fraction

import numpy as np
from scipy import signal

SR = 44100
rng = np.random.default_rng(1337)


def reseed(n: int) -> None:
    global rng
    rng = np.random.default_rng(n)


# ---------- basics ----------

def n_of(sec: float) -> int:
    return int(round(sec * SR))


def tline(sec: float) -> np.ndarray:
    return np.arange(n_of(sec)) / SR


def db(x: float) -> float:
    return 10 ** (x / 20)


def peak(x: np.ndarray) -> float:
    return float(np.max(np.abs(x))) if len(x) else 0.0


def norm(x: np.ndarray, peak_db: float = -3.0) -> np.ndarray:
    p = peak(x)
    return x if p < 1e-9 else x * (db(peak_db) / p)


def fade(x: np.ndarray, fin: float = 0.005, fout: float = 0.005) -> np.ndarray:
    x = x.copy()
    a, b = min(n_of(fin), len(x)), min(n_of(fout), len(x))
    if a:
        x[:a] *= np.linspace(0, 1, a) ** 1.0
    if b:
        x[len(x) - b:] *= np.linspace(1, 0, b)
    return x


def pad(x: np.ndarray, total: float) -> np.ndarray:
    n = n_of(total)
    if len(x) >= n:
        return x[:n]
    return np.concatenate([x, np.zeros(n - len(x), dtype=x.dtype)])


def mix(layers, total: float | None = None) -> np.ndarray:
    """layers: (signal, offset_sec, gain_db). Returns the sum (mono)."""
    end = 0
    for s, off, _ in layers:
        end = max(end, n_of(off) + len(s))
    if total is not None:
        end = n_of(total)
    out = np.zeros(end, dtype=np.float64)
    for s, off, g in layers:
        i = n_of(off)
        j = min(end, i + len(s))
        if j > i:
            out[i:j] += s[: j - i] * db(g)
    return out.astype(np.float32)


def trim(x: np.ndarray, thresh_db: float = -50.0, keep_tail: float = 0.0) -> np.ndarray:
    a = np.abs(x)
    ref = a.max() if len(a) else 1
    idx = np.where(a > ref * db(thresh_db))[0]
    if len(idx) == 0:
        return x
    i0, i1 = idx[0], idx[-1] + 1 + n_of(keep_tail)
    return x[i0:min(len(x), i1)]


def resample_ratio(x: np.ndarray, ratio: float) -> np.ndarray:
    """Play back at `ratio` speed (ratio 2 = octave up, half as long)."""
    fr = Fraction(ratio).limit_denominator(2000)
    return signal.resample_poly(x, fr.denominator, fr.numerator).astype(np.float32)


def pitch(x: np.ndarray, semis: float) -> np.ndarray:
    return resample_ratio(x, 2 ** (semis / 12))


def to_sr(x: np.ndarray, sr: int) -> np.ndarray:
    if sr == SR:
        return x
    fr = Fraction(SR, sr)
    return signal.resample_poly(x, fr.numerator, fr.denominator).astype(np.float32)


def stretch_to(x: np.ndarray, sec: float) -> np.ndarray:
    return resample_ratio(x, len(x) / n_of(sec))


# ---------- filters ----------

def _sos(kind, fc, order=2, fs=SR):
    return signal.butter(order, fc, btype=kind, fs=fs, output="sos")


def lp(x, fc, order=2):
    return signal.sosfilt(_sos("low", min(fc, SR * 0.45), order), x).astype(np.float32)


def hp(x, fc, order=2):
    return signal.sosfilt(_sos("high", fc, order), x).astype(np.float32)


def bp(x, lo, hi, order=2):
    return signal.sosfilt(_sos("band", [lo, min(hi, SR * 0.45)], order), x).astype(np.float32)


def notchless_dc(x):
    return hp(x, 20.0, 1)


def svf_lp(x: np.ndarray, fc, q: float = 0.7) -> np.ndarray:
    """Chamberlin state-variable low-pass with a per-sample cutoff (scalar or array)."""
    n = len(x)
    fc = np.broadcast_to(np.asarray(fc, dtype=np.float64), (n,))
    f = 2 * np.sin(np.pi * np.clip(fc, 20, SR / 6.5) / SR)
    out = np.empty(n, dtype=np.float32)
    low = band = 0.0
    qq = 1.0 / q
    xs = x.astype(np.float64)
    for i in range(n):
        low += f[i] * band
        high = xs[i] - low - qq * band
        band += f[i] * high
        out[i] = low
    return out


def svf_bp(x: np.ndarray, fc, q: float = 4.0) -> np.ndarray:
    n = len(x)
    fc = np.broadcast_to(np.asarray(fc, dtype=np.float64), (n,))
    f = 2 * np.sin(np.pi * np.clip(fc, 20, SR / 6.5) / SR)
    out = np.empty(n, dtype=np.float32)
    low = band = 0.0
    qq = 1.0 / q
    xs = x.astype(np.float64)
    for i in range(n):
        low += f[i] * band
        high = xs[i] - low - qq * band
        band += f[i] * high
        out[i] = band
    return out


def sat(x, drive=2.0):
    return (np.tanh(x * drive) / np.tanh(drive)).astype(np.float32)


def radio(x, lo=380.0, hi=3200.0, drive=2.5, hiss=0.0):
    """Walkie-talkie colour: band-limited, driven, a little hiss."""
    y = bp(x, lo, hi, 2)
    y = sat(y / (peak(y) + 1e-9), drive)
    if hiss:
        y = y + bp(noise(len(y) / SR), 1500, 5000) * hiss
    return y.astype(np.float32)


def bitcrush(x, bits=8, hold=1):
    q = 2 ** (bits - 1)
    y = np.round(x * q) / q
    if hold > 1:
        y = np.repeat(y[::hold], hold)[: len(x)]
    return y.astype(np.float32)


# ---------- generators ----------

def noise(sec: float, kind: str = "white") -> np.ndarray:
    n = n_of(sec)
    w = rng.standard_normal(n).astype(np.float32)
    if kind == "white":
        return w * 0.35
    if kind == "pink":
        b = [0.049922035, -0.095993537, 0.050612699, -0.004408786]
        a = [1, -2.494956002, 2.017265875, -0.522189400]
        y = signal.lfilter(b, a, w)
        return (y / (np.abs(y).max() + 1e-9) * 0.5).astype(np.float32)
    if kind == "brown":
        y = np.cumsum(w)
        y = hp(y.astype(np.float32), 25, 1)
        return (y / (np.abs(y).max() + 1e-9) * 0.5).astype(np.float32)
    raise ValueError(kind)


def osc(kind: str, freq, sec: float, phase: float = 0.0) -> np.ndarray:
    n = n_of(sec)
    f = np.broadcast_to(np.asarray(freq, dtype=np.float64), (n,))
    ph = phase + 2 * np.pi * np.cumsum(f) / SR
    if kind == "sine":
        return np.sin(ph).astype(np.float32)
    frac = (ph / (2 * np.pi)) % 1.0
    if kind == "saw":
        return (2 * frac - 1).astype(np.float32)
    if kind == "square":
        return np.where(frac < 0.5, 1.0, -1.0).astype(np.float32)
    if kind == "tri":
        return (4 * np.abs(frac - 0.5) - 1).astype(np.float32)
    raise ValueError(kind)


def sweep(f0, f1, sec, curve="exp"):
    t = np.linspace(0, 1, n_of(sec))
    if curve == "exp":
        return f0 * (f1 / f0) ** t
    return f0 + (f1 - f0) * t


def supersaw(freq: float, sec: float, cents=(-9, -3, 0, 4, 10), kind="saw", vib=0.0) -> np.ndarray:
    out = np.zeros(n_of(sec), dtype=np.float32)
    t = tline(sec)
    for i, c in enumerate(cents):
        f = freq * 2 ** (c / 1200)
        if vib:
            f = f * (1 + vib * np.sin(2 * np.pi * (5.2 + 0.3 * i) * t))
        out += osc(kind, f, sec, phase=i * 1.7)
    return out / len(cents)


def bell(freq: float, sec: float, bright=1.0, inharm=1.0) -> np.ndarray:
    """Additive bell: inharmonic partials with their own decays."""
    t = tline(sec)
    parts = [(1.0, 1.0, 1.0), (2.0 * inharm ** 0.5 * 1.002, 0.55, 0.7), (2.76 * inharm, 0.4 * bright, 0.45), (5.4 * inharm, 0.25 * bright, 0.28), (8.93 * inharm, 0.12 * bright, 0.16)]
    out = np.zeros_like(t, dtype=np.float32)
    for m, a, d in parts:
        f = freq * m
        if f > 16000:
            continue
        out += (a * np.exp(-t / (sec * 0.22 * d))).astype(np.float32) * np.sin(2 * np.pi * f * t).astype(np.float32)
    out *= np.minimum(1, t / 0.002).astype(np.float32)
    out *= np.minimum(1, (sec - t) / 0.03).astype(np.float32)
    return out / 2.2


def env_ad(sec: float, a: float, d_tau: float) -> np.ndarray:
    t = tline(sec)
    e = np.exp(-t / d_tau)
    e *= np.minimum(1.0, t / max(a, 1e-4))
    return e.astype(np.float32)


def adsr(sec: float, a: float, d: float, s: float, r: float) -> np.ndarray:
    n = n_of(sec)
    e = np.ones(n, dtype=np.float32) * s
    na, nd, nr = n_of(a), n_of(d), n_of(r)
    na = min(na, n)
    e[:na] = np.linspace(0, 1, na) if na else e[:na]
    nd = min(nd, n - na)
    if nd > 0:
        e[na:na + nd] = np.linspace(1, s, nd)
    nr = min(nr, n)
    if nr > 0:
        e[n - nr:] *= np.linspace(1, 0, nr)
    return e


def thump(freq=55.0, sec=0.28, drop=2.2, tau=0.07, click=0.25) -> np.ndarray:
    """A kick-like body: a sine that falls from freq*drop to freq."""
    t = tline(sec)
    f = freq * (1 + (drop - 1) * np.exp(-t / 0.018))
    ph = 2 * np.pi * np.cumsum(f) / SR
    y = np.sin(ph) * np.exp(-t / tau) * np.minimum(1, t / 0.003) * np.minimum(1, (sec - t) / 0.012)
    if click:
        c = lp(noise(sec), 1800) * np.exp(-t / 0.006) * np.minimum(1, (sec - t) / 0.012)
        y = y + click * c
    return y.astype(np.float32)


def heart_beat(strength=1.0, gap=0.17, f1=54.0, f2=46.0, sec=0.55) -> np.ndarray:
    """One lub-dub, felt more than heard."""
    lub = thump(f1, 0.26, 2.0, 0.065, 0.2) * 1.0
    dub = thump(f2, 0.24, 1.9, 0.055, 0.15) * 0.7
    y = mix([(lub, 0.0, 0), (dub, gap, 0)], sec)
    # a touch of body so small phone speakers still hint at it
    y = y + 0.35 * sat(bp(y, 90, 260), 2.0)
    return (y * strength).astype(np.float32)


def crackle(sec: float, density: float = 40.0, lo=1500, hi=9000, decay=0.003) -> np.ndarray:
    n = n_of(sec)
    out = np.zeros(n, dtype=np.float32)
    k = rng.poisson(density * sec)
    for _ in range(k):
        i = rng.integers(0, max(1, n - 400))
        L = min(n - i, int(SR * decay * 6))
        amp = rng.uniform(0.2, 1.0) ** 2
        out[i:i + L] += (rng.standard_normal(L) * np.exp(-np.arange(L) / (SR * decay)) * amp).astype(np.float32)
    return bp(out, lo, hi, 1)


# ---------- space ----------

def make_ir(sec=1.2, tone=4000.0, pre=0.0, stereo=False):
    n = n_of(sec)
    t = np.arange(n) / SR
    def one():
        w = rng.standard_normal(n)
        w *= np.exp(-t / (sec / 6.9))
        w = signal.sosfilt(_sos("low", tone, 1), w)
        # air absorbs highs over time
        w2 = signal.sosfilt(_sos("low", max(300, tone / 4), 1), w)
        mixv = np.exp(-t / (sec / 3))
        w = w * (1 - mixv) + w2 * mixv
        w[:int(pre * SR)] = 0
        return w / (np.sqrt((w ** 2).sum()) + 1e-9)
    return (np.stack([one(), one()], 1) if stereo else one()).astype(np.float32)


def reverb(x: np.ndarray, sec=1.0, wet=0.25, tone=4000.0, tail=True) -> np.ndarray:
    """Add a synthetic room. `wet` is the wet level relative to the dry signal (0.25 = -12 dB)."""
    ir = make_ir(sec, tone)
    y = signal.fftconvolve(x, ir).astype(np.float32)
    n = len(x) + (len(ir) if tail else 0)
    y = np.pad(y, (0, max(0, n - len(y))))[:n]
    r_x = np.sqrt((x ** 2).mean() + 1e-12)
    r_y = np.sqrt((y[: len(x)] ** 2).mean() + 1e-12)
    out = np.zeros(n, dtype=np.float32)
    out[: len(x)] = x
    return out + y * (wet * r_x / r_y)


def echo(x: np.ndarray, delay=0.18, fb=0.35, n=4, damp=3000.0) -> np.ndarray:
    d = n_of(delay)
    out = np.zeros(len(x) + d * n, dtype=np.float32)
    out[: len(x)] += x
    cur = x
    for k in range(1, n + 1):
        cur = lp(cur, damp, 1) * fb
        out[d * k: d * k + len(cur)] += cur
    return out


def stereo_from(l: np.ndarray, r: np.ndarray) -> np.ndarray:
    n = max(len(l), len(r))
    return np.stack([pad(l, n / SR), pad(r, n / SR)], 1).astype(np.float32)


def widen(x: np.ndarray, sec=1.0, tone=5000.0, amount=1.0) -> np.ndarray:
    """Mono to stereo through two different short reverbs (decorrelated)."""
    irs = make_ir(sec, tone, stereo=True)
    l = signal.fftconvolve(x, irs[:, 0])[: len(x)]
    r = signal.fftconvolve(x, irs[:, 1])[: len(x)]
    sc = np.sqrt((x ** 2).mean() + 1e-12) / (np.sqrt((l ** 2).mean() + 1e-12))
    l, r = l * sc * amount, r * sc * amount
    return np.stack([x * (1 - 0.5 * amount) + l * 0.7, x * (1 - 0.5 * amount) + r * 0.7], 1).astype(np.float32)


# ---------- loops ----------

def loop_crossfade(x: np.ndarray, sec: float, xf: float = 2.0) -> np.ndarray:
    """x is longer than `sec` by at least `xf`. Returns a seam-free loop of exactly `sec`.

    out[i] for i<xf fades the head in while the material that *follows* the loop end fades out,
    so the wrap from the last sample to the first is a continuation of the source.
    """
    L, X = n_of(sec), n_of(xf)
    assert len(x) >= L + X, (len(x), L + X)
    out = x[:L].copy()
    th = np.linspace(0, np.pi / 2, X)
    shape = (X,) + (1,) * (x.ndim - 1)
    out[:X] = x[:X] * np.sin(th).reshape(shape) + x[L:L + X] * np.cos(th).reshape(shape)
    return out


def loop_wrap(x: np.ndarray, sec: float) -> np.ndarray:
    """Fold everything after `sec` (reverb tails) back onto the start."""
    L = n_of(sec)
    out = x[:L].copy()
    tail = x[L:]
    k = min(len(tail), L)
    out[:k] += tail[:k]
    return out


# ---------- measurement ----------

def _kw(x: np.ndarray):
    """BS.1770 K-weighting filters at SR."""
    G, Q, fc = 3.999843853973347, 0.7071752369554196, 1681.9744509555319
    A = 10 ** (G / 40)
    w0 = 2 * math.pi * fc / SR
    alpha = math.sin(w0) / (2 * Q)
    c = math.cos(w0)
    b = [A * ((A + 1) + (A - 1) * c + 2 * math.sqrt(A) * alpha), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - 2 * math.sqrt(A) * alpha)]
    a = [(A + 1) - (A - 1) * c + 2 * math.sqrt(A) * alpha, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - 2 * math.sqrt(A) * alpha]
    y = signal.lfilter(np.array(b) / a[0], np.array(a) / a[0], x)
    fc2, Q2 = 38.13547087613982, 0.5003270373253953
    w0 = 2 * math.pi * fc2 / SR
    alpha = math.sin(w0) / (2 * Q2)
    c = math.cos(w0)
    b = [(1 + c) / 2, -(1 + c), (1 + c) / 2]
    a = [1 + alpha, -2 * c, 1 - alpha]
    return signal.lfilter(np.array(b) / a[0], np.array(a) / a[0], y)


def momentary_lufs(x: np.ndarray) -> float:
    """Loudest 400 ms window, K-weighted, ungated (mono or stereo)."""
    ch = [x] if x.ndim == 1 else [x[:, i] for i in range(x.shape[1])]
    w = [_kw(c.astype(np.float64)) for c in ch]
    ms = sum(np.square(c) for c in w)
    n = n_of(0.4)
    if len(ms) < n:
        m = ms.sum() / n
    else:
        cs = np.cumsum(np.insert(ms, 0, 0.0))
        m = ((cs[n:] - cs[:-n]) / n).max()
    return -0.691 + 10 * math.log10(m + 1e-12)


def integrated_lufs(x: np.ndarray) -> float:
    ch = [x] if x.ndim == 1 else [x[:, i] for i in range(x.shape[1])]
    ms = sum(np.square(_kw(c.astype(np.float64))) for c in ch)
    return -0.691 + 10 * math.log10(ms.mean() + 1e-12)


def encode_mp3(x: np.ndarray, path: str, kbps: int) -> None:
    import lameenc
    ch = 1 if x.ndim == 1 else x.shape[1]
    pcm = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    enc = lameenc.Encoder()
    enc.set_bit_rate(kbps)
    enc.set_in_sample_rate(SR)
    enc.set_channels(ch)
    enc.set_quality(2)
    data = enc.encode(pcm.tobytes()) + enc.flush()
    with open(path, "wb") as f:
        f.write(data)
