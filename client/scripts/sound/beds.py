"""Loopable beds: the two map ambiences and the menu / onboarding theme (all stereo)."""
from __future__ import annotations

import numpy as np

import dsp
from dsp import SR, mix, lp, hp, bp, tline, n_of, pitch, noise, osc, thump, bell, reverb, sat
from lib import snd, raw, rawn, RPG, R50, WIND, BREATH
from sfx import beat, radio_beep, squelch


def _lfo(sec, hz, depth=0.5, phase=0.0):
    return 1 - depth + depth * 0.5 * (1 + np.sin(2 * np.pi * hz * tline(sec) + phase))


def _place(total, events):
    """events: (signal, t, gain_db, pan -1..1) -> stereo."""
    out = np.zeros((n_of(total), 2), dtype=np.float32)
    for s, t, g, pan in events:
        i = n_of(t)
        j = min(len(out), i + len(s))
        a = (pan + 1) * np.pi / 4
        out[i:j, 0] += s[: j - i] * dsp.db(g) * np.cos(a)
        out[i:j, 1] += s[: j - i] * dsp.db(g) * np.sin(a)
    return out


@snd("amb_map.h", "amb", loop=True, kbps=96,
     note="Human map bed (36 s loop): distant wind, faint radio static, the odd far-off thud, clank and radio chirp. Very quiet.")
def _():
    L, XF = 36.0, 3.0
    T = L + XF
    w = raw(WIND, do_trim=False)
    w = hp(lp(w, 2400, 2), 55, 2)
    w2 = np.concatenate([np.zeros(n_of(0.017)), lp(w, 1900, 2)])[: len(w)] * 0.92  # haas-delayed, a touch duller
    # static: a faint hiss bed that drifts, with now-and-then crackle
    st = bp(noise(T, "white"), 1800, 5200, 2) * _lfo(T, 0.07, 0.8) * dsp.db(-44)
    st2 = bp(noise(T, "white"), 1800, 5200, 2) * _lfo(T, 0.05, 0.8, 1.3) * dsp.db(-44)
    crk = dsp.crackle(T, 6, 2000, 7000, 0.002) * dsp.db(-30)
    static = np.stack([st + crk, st2 + crk * 0.6], 1)
    far = []
    door = lp(raw(RPG + "world/door.wav"), 800, 2)
    far.append((reverb(door, 1.8, 0.7, 1800), 7.5, -34, -0.6))
    clank = lp(pitch(raw(RPG + "inventory/metal-small2.wav"), -5), 1500, 2)
    far.append((reverb(clank, 2.2, 0.8, 1800), 14.5, -36, 0.7))
    thud = lp(thump(70, 0.3, 1.5, 0.08, 0.1), 300)
    far.append((reverb(thud, 2.0, 0.6, 1200), 20.5, -32, -0.3))
    chirp_ = np.concatenate([radio_beep(), np.zeros(n_of(0.09)), radio_beep()])
    far.append((reverb(dsp.radio(chirp_, 600, 2400), 1.2, 0.5, 2500), 26.5, -40, 0.5))
    far.append((reverb(lp(pitch(raw(R50 + "creak2.ogg"), -3), 1200, 2), 2.0, 0.6, 1500), 31.5, -36, 0.4))
    rest = static + _place(T, far)
    best = None
    for off in np.arange(0.0, len(w) / SR - T - 0.2, 0.05):
        wl, wr = w[n_of(off): n_of(off + T)], w2[n_of(off): n_of(off + T)]
        wd = np.stack([wl, wr], 1)
        wd = wd / (np.sqrt((wd ** 2).mean()) + 1e-9) * dsp.db(-24)
        seg = dsp.loop_crossfade(wd + rest, L, XF).mean(axis=1)
        a_, b_ = seg[: n_of(0.05)], seg[-n_of(0.05):]
        d = abs(20 * np.log10(np.sqrt((a_ ** 2).mean()) / np.sqrt((b_ ** 2).mean())))
        if best is None or d < best[0]:
            best = (d, wd)
    return dsp.loop_crossfade(best[1] + rest, L, XF)


@snd("amb_map.z", "amb", loop=True, kbps=96,
     note="Zombie map bed (40 s loop): sub drone, thermal hum, slow wet breathing and a faint heartbeat. Dark and very quiet.")
def _():
    L = 40.0
    t = tline(L)
    # every frequency here is a whole number of Hz, so the bed is exactly periodic in 40 s
    def tone(f, g, lf, ph=0.0):
        return np.sin(2 * np.pi * f * t + ph) * _lfo(L, lf, 0.6, ph) * dsp.db(g)
    dl = tone(38, -14, 0.05) + tone(57, -20, 0.075, 1) + tone(76, -26, 0.025, 2)
    dr = tone(38, -14, 0.05, 0.5) + tone(57, -20, 0.075, 2) + tone(76, -26, 0.025, 3)
    hum_l = tone(100, -30, 0.05) + tone(200, -34, 0.1, 1) + tone(300, -40, 0.125)
    hum_r = tone(101, -30, 0.05, 1) + tone(200, -34, 0.1, 2) + tone(299, -40, 0.125, 1)
    XF = 3.0
    rumble = dsp.loop_crossfade(lp(noise(L + XF, "brown"), 120, 2), L, XF) * dsp.db(-16)
    rumble = rumble * _lfo(L, 0.025, 0.5)
    # thermal shimmer: hot air, high and thin
    sh = dsp.loop_crossfade(bp(noise(L + XF), 2800, 6500, 2), L, XF) * _lfo(L, 0.05, 0.9) * dsp.db(-50)
    bed = np.stack([dl + hum_l + rumble + sh, dr + hum_r + rumble * 0.9 + sh[::-1]], 1)
    br = raw(BREATH, do_trim=True)
    br = lp(pitch(br, -3), 700, 2)
    br = br / (np.abs(br).max() + 1e-9)
    ev = []
    for k, tt in enumerate((1.0, 9.0, 17.5, 25.0, 32.5)):
        ev.append((br * (0.8 + 0.2 * (k % 2)), tt, -27 - 2 * (k % 3), -0.5 if k % 2 else 0.5))
    # a heartbeat every 1.25 s (48 bpm), far down
    hb = lp(beat(1.0), 180, 2)
    for k in range(32):
        ev.append((hb, k * 1.25, -33, 0.0))
    placed = _place(L + 2.0, ev)
    x = bed + placed[: n_of(L)]
    tail = placed[n_of(L):]
    x[: len(tail)] += tail  # wrap breath tails back over the start
    return x


# ---------- menu / onboarding theme ----------

BPM = 60
BAR = 4.0


def _chord_pad(freqs, dur, cents_l, cents_r, tone=1250.0):
    l = sum(dsp.supersaw(f, dur, cents_l) for f in freqs) / len(freqs)
    r = sum(dsp.supersaw(f, dur, cents_r) for f in freqs) / len(freqs)
    env = dsp.adsr(dur, 1.8, 0.2, 0.85, 2.4)
    return lp(l, tone, 2) * env, lp(r, tone, 2) * env


@snd("theme", "music", loop=True, kbps=128,
     note="Main-menu / onboarding theme (96 s loop, A minor, 60 bpm): slow dark pad, sub, a heartbeat that enters in the second third, sparse bells with long echo, wind and radio hiss.")
def _():
    dsp.reseed(4242)
    L = 96.0
    TAIL = 6.0
    chords = [
        dict(pad=[110.0, 164.8, 220.0, 261.6, 329.6], root=110.0, mel=[(1.0, 659.3), (3.0, 523.3), (5.5, 440.0)]),   # Am
        dict(pad=[87.3, 130.8, 174.6, 220.0, 329.6], root=87.3, mel=[(1.0, 523.3), (3.5, 659.3), (6.0, 440.0)]),     # Fmaj7
        dict(pad=[73.4, 110.0, 146.8, 174.6, 220.0], root=73.4, mel=[(1.0, 587.3), (3.0, 698.5), (5.5, 440.0)]),     # Dm
        dict(pad=[82.4, 123.5, 164.8, 196.0, 293.7], root=82.4, mel=[(1.0, 784.0), (3.0, 659.3), (5.5, 493.9)]),      # Em7
    ]
    n = n_of(L + TAIL)
    left = np.zeros(n, dtype=np.float32)
    right = np.zeros(n, dtype=np.float32)
    mono_mel = np.zeros(n, dtype=np.float32)
    sub = np.zeros(n, dtype=np.float32)
    k = 0
    for phrase in range(3):
        for ch in chords:
            t0 = k * 8.0
            pl, pr = _chord_pad(ch["pad"], 10.5, (-12, -5, 3, 10), (-10, -2, 6, 13), 1100 + 250 * phrase)
            i = n_of(t0)
            left[i:i + len(pl)] += pl * dsp.db(-9 + 2 * phrase)
            right[i:i + len(pr)] += pr * dsp.db(-9 + 2 * phrase)
            s = osc("sine", ch["root"], 9.5) * dsp.adsr(9.5, 1.0, 0.1, 0.9, 1.8) * dsp.db(-13)
            sub[i:i + len(s)] += s
            if phrase >= 1 or k % 4 >= 2:
                for tm, f in ch["mel"]:
                    b = bell(f, 3.0, 0.5, 1.0) * dsp.db(-10 + (3 if phrase == 2 else 0))
                    j = n_of(t0 + tm)
                    mono_mel[j:j + len(b)] += b
                if phrase == 2:
                    for tm, f in ch["mel"][:2]:
                        b = bell(f / 2, 3.5, 0.3, 0.8) * dsp.db(-12)
                        j = n_of(t0 + tm + 0.5)
                        mono_mel[j:j + len(b)] += b
            k += 1
    # long dotted echo on the bells, then a big dark room
    mel = dsp.echo(mono_mel, 0.75, 0.5, 5, 2800)[:n]
    mel = reverb(mel, 3.0, 0.5, 3500)[:n]
    # heartbeat enters at 32 s, every bar, then every two beats from 64 s
    hb = np.zeros(n, dtype=np.float32)
    h = lp(beat(1.0), 200, 2) * dsp.db(-17)
    t = 32.0
    while t < L:
        j = n_of(t)
        hb[j:j + len(h)] += h * (1.0 if t < 64 else 1.15)
        t += 4.0 if t < 64 else 2.0
    # wind / radio hiss texture
    wind = bp(noise(L + TAIL, "pink"), 150, 900, 2) * _lfo(L + TAIL, 1 / 24.0, 0.9) * dsp.db(-26)
    hiss = bp(noise(L + TAIL), 2200, 6000, 2) * _lfo(L + TAIL, 1 / 16.0, 0.9, 1.0) * dsp.db(-52)
    L_ch = left + sub + hb + wind + hiss
    R_ch = right + sub + hb + wind[::-1] + hiss[::-1]
    stereo = np.stack([L_ch, R_ch], 1)
    # pad room (separate short convolution per side keeps width)
    irs = dsp.make_ir(3.0, 3000.0, stereo=True)
    from scipy import signal
    wl = signal.fftconvolve(stereo[:, 0], irs[:, 0])[:n]
    wr = signal.fftconvolve(stereo[:, 1], irs[:, 1])[:n]
    sc = np.sqrt((stereo ** 2).mean()) / np.sqrt(((wl ** 2).mean() + (wr ** 2).mean()) / 2)
    stereo = stereo + np.stack([wl, wr], 1) * sc * 0.45
    stereo[:, 0] += mel * 0.8
    stereo[:, 1] += mel * 0.8
    return dsp.loop_wrap(stereo, L).astype(np.float32)
