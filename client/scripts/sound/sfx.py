"""Every one-shot: UI, combat, rewards, stingers, alarms and the shared onboarding set.

Naming: key.h is the Human (survey) variant, key.z the Zombie (heat) variant, no suffix is shared.
Human sounds are practical and analog: clicks, latches, brass, field radio. Zombie sounds are low,
wet and organic: heartbeats, growls, slime, breath, dark bells.
"""
from __future__ import annotations

import numpy as np

import dsp
from dsp import SR, mix, db, lp, hp, bp, tline, n_of, pitch, noise, osc, thump, bell, reverb, sat, svf_lp, svf_bp
from lib import snd, raw, rawn, KI, RPG, R50, SCIFI, G16, STATIC, BREATH


# ---------- shared voices ----------

def brass(freq: float, dur: float, vel: float = 1.0, atk: float = 0.03, open_: float = 3000.0) -> np.ndarray:
    """Radio-stinger brass: detuned saws through a filter that blooms then settles."""
    s = dsp.supersaw(freq, dur, cents=(-8, 0, 7), vib=0.0035)
    t = tline(dur)
    fc = 600 + open_ * np.exp(-t / 0.16) * vel + 700 * vel
    y = svf_lp(s, fc, q=1.1) * dsp.adsr(dur, atk, 0.12, 0.78, min(0.18, dur * 0.4))
    return y * 0.55


def squelch(dur: float = 0.09, lo: float = 700, hi: float = 3600) -> np.ndarray:
    """The 'kssh' of a radio key-up."""
    n = noise(dur)
    return dsp.fade(sat(bp(n, lo, hi, 2), 3.0) * dsp.env_ad(dur, 0.002, dur * 0.45), 0.002, 0.02)


def chirp(f0: float, f1: float, dur: float, kind: str = "square", cutoff: float = 3500.0) -> np.ndarray:
    y = osc(kind, dsp.sweep(f0, f1, dur), dur)
    return dsp.fade(lp(y, cutoff, 2) * dsp.env_ad(dur, 0.004, dur * 0.5), 0.003, 0.012)


def whoosh(dur: float, f0: float, f1: float, q: float = 1.6, tone="white") -> np.ndarray:
    n = noise(dur, tone)
    e = np.sin(np.linspace(0, np.pi, len(n))) ** 1.5
    return svf_bp(n, dsp.sweep(f0, f1, dur), q) * e * 3.0


def hiss(dur: float, lo=3500, hi=9500, trem: float = 0.0, swell: bool = True) -> np.ndarray:
    n = bp(noise(dur), lo, hi, 2)
    e = np.linspace(0.05, 1, len(n)) ** 1.6 if swell else np.ones(len(n))
    if trem:
        e = e * (0.65 + 0.35 * np.sin(2 * np.pi * trem * tline(dur)))
    return dsp.fade(n * e.astype(np.float32), 0.01, 0.03)


def pad(freqs, dur, tone=900.0, atk=0.4, rel=0.5, kind="saw"):
    y = sum(dsp.supersaw(f, dur, cents=(-11, -4, 3, 9), kind=kind, vib=0.002) for f in freqs) / len(freqs)
    y = svf_lp(y, tone, 0.9)
    return y * dsp.adsr(dur, atk, 0.1, 0.9, rel)


def growl(rel: str, semis: float, dur: float | None = None, cutoff: float = 2500.0, start: float = 0.0) -> np.ndarray:
    y = pitch(rawn(rel, start=start), semis)
    if dur:
        y = dsp.fade(y[: n_of(dur)], 0.004, 0.03)
    return lp(y, cutoff, 2)


def wet(rel: str, semis: float = -4, cutoff: float = 2600, dur: float | None = None) -> np.ndarray:
    y = pitch(rawn(rel), semis)
    y = lp(y, cutoff, 2)
    return dsp.fade(y[: n_of(dur)], 0.004, 0.03) if dur else y


def beat(strength: float = 1.0, gap: float = 0.17) -> np.ndarray:
    return dsp.heart_beat(strength, gap)


def beats(times, strengths=None, gap=0.17, total=None):
    strengths = strengths or [1.0] * len(times)
    return mix([(beat(s, gap), t, 0) for t, s in zip(times, strengths)], total)


def chime_arp(freqs, step, dur, bright=1.0, inharm=1.0, gain_step=0.0):
    return mix([(bell(f, dur, bright, inharm), i * step, -gain_step * i) for i, f in enumerate(freqs)])


# ====================================================================
# UI  (quiet)
# ====================================================================

@snd("tap.h", "ui", note="Marker-tip tap: a dry paper-and-plastic click with a small high tick.")
def _():
    a = rawn(KI + "select_002.ogg")
    tick = osc("sine", 2100, 0.04) * dsp.env_ad(0.04, 0.001, 0.009)
    return mix([(a, 0, -3), (tick, 0, -9), (thump(170, 0.05, 1.4, 0.015, 0) * 0.5, 0, -8)])


@snd("tap.z", "ui", note="Soft wet pop with a low body, like pressing on something warm.")
def _():
    b = wet(RPG + "inventory/bubble.wav", -9, 1500, 0.16) * dsp.env_ad(0.16, 0.003, 0.05)
    return mix([(b, 0, 0), (thump(78, 0.13, 1.5, 0.04, 0.0), 0, -3)])


@snd("tab.h", "ui", note="A rocker switch: slightly longer than a tap, clicks over.")
def _():
    a = rawn(KI + "toggle_001.ogg")
    return mix([(a, 0, -2), (squelch(0.04, 1200, 3000), 0, -16)])


@snd("tab.z", "ui", note="Low double-pulse under a soft click; the heat lens changes channel.")
def _():
    a = pitch(rawn(KI + "toggle_001.ogg"), -10)
    a = lp(a, 1800, 2)
    return mix([(a, 0, -3), (thump(66, 0.16, 1.7, 0.05, 0.1), 0, -2), (thump(58, 0.12, 1.5, 0.04, 0.0), 0.075, -6)])


@snd("sheet_open.h", "ui", note="Paper sliding up and a latch: a clipboard being lifted.")
def _():
    s = rawn(KI + "maximize_007.ogg")
    p = bp(noise(0.18), 1800, 6500) * np.sin(np.linspace(0, np.pi, n_of(0.18))) ** 2
    return mix([(p, 0, -6), (s, 0.02, -2)])


@snd("sheet_close.h", "ui", note="The same latch going back down.")
def _():
    s = rawn(KI + "minimize_007.ogg")
    p = bp(noise(0.16), 1500, 5500) * np.sin(np.linspace(0, np.pi, n_of(0.16))) ** 2
    return mix([(p, 0, -7), (s, 0.0, -2)])


@snd("sheet_open.z", "ui", note="A low swell rising through flesh-coloured light.")
def _():
    w = whoosh(0.26, 220, 1300, 1.0, "pink")
    return mix([(w, 0, 0), (thump(62, 0.2, 1.6, 0.06, 0.05), 0.12, -6)])


@snd("sheet_close.z", "ui", note="The swell sinking back away.")
def _():
    w = whoosh(0.24, 1200, 200, 1.0, "pink")
    return mix([(w, 0, 0), (thump(54, 0.16, 1.4, 0.05, 0.0), 0.0, -8)])


@snd("equip.h", "sfx", note="Metal latch snapping home with a leather strap rustle.")
def _():
    a = rawn(R50 + "metalLatch.ogg")
    b = rawn(R50 + "handleSmallLeather.ogg")
    return mix([(b, 0, -4), (a, 0.05, -1), (thump(120, 0.12, 1.5, 0.03, 0), 0.05, -8)])


@snd("equip.z", "sfx", note="Something heavy settling onto wet muscle.")
def _():
    a = wet(R50 + "dropLeather.ogg", -5, 2200)
    s = wet(RPG + "NPC/slime/slime5.wav", -5, 2200)
    return mix([(a, 0, -1), (s, 0.04, -6), (thump(58, 0.22, 1.8, 0.07, 0.05), 0.0, -2)])


@snd("scrap.h", "sfx", note="A hard chop and a rattle of loose metal.")
def _():
    c = rawn(R50 + "chop.ogg")
    m = rawn(RPG + "inventory/chainmail2.wav")
    return mix([(c, 0, -1), (m, 0.08, -8), (thump(90, 0.15, 1.8, 0.04, 0), 0, -6)])


@snd("scrap.z", "sfx", note="A wet tearing squelch and crunch.")
def _():
    s = wet(RPG + "NPC/slime/slime8.wav", -7, 2400)
    c = wet(R50 + "chop.ogg", -8, 1800)
    return mix([(c, 0, -2), (s, 0.05, -2), (thump(52, 0.25, 1.8, 0.08, 0.1), 0, -3)])


@snd("upgrade.h", "reward", note="Latch, then two rising bell strikes: a part machined into place.")
def _():
    l = rawn(R50 + "metalLatch.ogg")
    b1, b2 = bell(784, 1.0, 1.0), bell(1175, 1.2, 1.0)
    return reverb(mix([(l, 0, -2), (b1, 0.1, -2), (b2, 0.21, 0), (thump(100, 0.12, 1.6, 0.03, 0), 0, -6)]), 0.6, 0.18)


@snd("upgrade.z", "reward", note="A dull thud and a low organic swell with a dark bell.")
def _():
    sw = svf_lp(dsp.supersaw(110, 0.9, kind="saw"), dsp.sweep(180, 900, 0.9), 1.0) * dsp.adsr(0.9, 0.3, 0.1, 0.8, 0.4)
    b = bell(196, 1.4, 0.4, 0.7)
    return reverb(mix([(thump(46, 0.4, 2.0, 0.12, 0.15), 0, 0), (sw, 0.05, -8), (b, 0.3, -6)]), 0.8, 0.2, 2500)


@snd("heal.h", "sfx", note="A cap twisting off, then a gentle rising chime: relief.")
def _():
    b = rawn(RPG + "inventory/bottle.wav")
    c = mix([(bell(988, 0.8, 0.6), 0.12, -4), (bell(1319, 0.9, 0.6), 0.22, -2)])
    return mix([(b, 0, -2), (c, 0, -3)])


@snd("heal.z", "sfx", note="A thick swallow and a warm pulse spreading.")
def _():
    g = wet(RPG + "inventory/bubble3.wav", -6, 1800)
    w = lp(osc("tri", dsp.sweep(110, 165, 0.7), 0.7), 700, 2) * dsp.adsr(0.7, 0.2, 0.1, 0.8, 0.3)
    return mix([(g, 0, -1), (w, 0.2, -6), (beat(0.8), 0.4, -4)])


@snd("purchase.h", "sfx", note="Coins counted into a hand.")
def _():
    a = rawn(RPG + "inventory/coin3.wav")
    b = rawn(R50 + "handleCoins.ogg")
    return mix([(b, 0, -3), (a, 0.12, 0)])


@snd("purchase.z", "sfx", note="The same coins, dropped into something wet and deep.")
def _():
    a = wet(RPG + "inventory/coin3.wav", -7, 2800)
    s = wet(RPG + "NPC/slime/slime2.wav", -5, 2200, 0.25)
    return mix([(s, 0, -3), (a, 0.08, 0), (thump(70, 0.18, 1.6, 0.05, 0), 0.0, -6)])


@snd("claim.h", "reward", note="Rubber stamp, coin, and a confirming ding: paperwork done.")
def _():
    st = rawn(R50 + "bookPlace2.ogg")
    co = rawn(RPG + "inventory/coin2.wav")
    ok = rawn(KI + "confirmation_003.ogg")
    return mix([(st, 0, -1), (co, 0.14, -5), (ok, 0.18, -3)])


@snd("claim.z", "reward", note="A low pulse and a swallowed tone: taken.")
def _():
    ok = pitch(rawn(KI + "confirmation_001.ogg"), -9)
    co = wet(RPG + "inventory/coin2.wav", -8, 2600)
    return mix([(beat(0.9), 0, -1), (ok, 0.15, -3), (co, 0.2, -8)])


@snd("error.h", "ui", note="Two soft falling radio beeps: not available.")
def _():
    a = chirp(520, 480, 0.09, "square", 1800) * 1.0
    b = chirp(400, 340, 0.12, "square", 1600)
    return mix([(a, 0, 0), (b, 0.11, 0)])


@snd("error.z", "ui", note="A short, low, dull grunt: no.")
def _():
    g = growl(RPG + "NPC/giant/giant1.wav", -4, 0.22, 900)
    return mix([(g, 0, 0), (thump(64, 0.15, 1.4, 0.05, 0), 0, -4)])


# ====================================================================
# COMBAT
# ====================================================================

@snd("engage.h", "sfx", note="Key-up squelch, a rising two-tone chirp and a low thud: you commit.")
def _():
    c = mix([(chirp(700, 1000, 0.1), 0, 0), (chirp(1000, 1500, 0.14), 0.1, 0)])
    return reverb(mix([(squelch(0.1), 0, -3), (c, 0.08, -3), (thump(70, 0.35, 2.0, 0.09, 0.2), 0.22, 0), (rawn(R50 + "metalLatch.ogg"), 0.02, -6)]), 0.5, 0.15)


@snd("engage.z", "sfx", note="A growl, two fast heartbeats and a hiss: it has locked on.")
def _():
    g = growl(G16 + "monster.3.ogg", -5, 0.7, 2600)
    h = beats([0.3, 0.62], [1.0, 1.2])
    return mix([(g, 0, -1), (h, 0, -2), (hiss(0.55, 3500, 9000, 0, True), 0.15, -14)])


@snd("hit.h", "sfx", note="A solid thwack: blunt, dry, a little bright.")
def _():
    b = bp(noise(0.08), 700, 4500) * dsp.env_ad(0.08, 0.001, 0.02)
    c = rawn(R50 + "bookPlace1.ogg", end=0.14)
    return mix([(thump(105, 0.2, 2.0, 0.05, 0.3), 0, 0), (b, 0, -2), (c, 0, -7)])


@snd("hit.z", "sfx", note="A wet smack with a deep thump under it.")
def _():
    s = wet(RPG + "NPC/slime/slime5.wav", -5, 2600, 0.24)
    return mix([(thump(72, 0.26, 2.0, 0.07, 0.2), 0, 0), (s, 0, -3)])


@snd("crit.h", "sfx", note="Hit plus a metal ring and a crack: the big one.")
def _():
    ring = bell(1480, 0.5, 1.0) * 0.9
    crack = bp(noise(0.12), 1500, 8000) * dsp.env_ad(0.12, 0.001, 0.03)
    return reverb(mix([(thump(80, 0.35, 2.3, 0.09, 0.4), 0, 0), (crack, 0, -1), (ring, 0.01, -9), (rawn(R50 + "chop.ogg"), 0, -4), (thump(40, 0.4, 1.5, 0.15, 0), 0.02, -3)]), 0.5, 0.12)


@snd("crit.z", "sfx", note="A crunch, a roar and a sub boom: something broke.")
def _():
    g = growl(RPG + "NPC/ogre/ogre2.wav", -4, 0.5, 3000)
    c = wet(R50 + "chop.ogg", -7, 2200)
    return reverb(mix([(thump(48, 0.5, 2.2, 0.14, 0.3), 0, 0), (c, 0, -1), (g, 0.02, -2), (wet(RPG + "NPC/slime/slime8.wav", -7, 2200), 0.05, -5)]), 0.6, 0.12, 2500)


@snd("dodge.h", "sfx", note="Air and cloth: you slipped it.")
def _():
    w = whoosh(0.24, 500, 3500, 1.4)
    cl = rawn(R50 + "cloth1.ogg", end=0.25)
    return mix([(w, 0, 0), (cl, 0.02, -8)])


@snd("dodge.z", "sfx", note="A low slither past: it slid away.")
def _():
    w = whoosh(0.3, 260, 1100, 1.2, "pink")
    s = wet(RPG + "NPC/slime/slime1.wav", -6, 2000)
    return mix([(w, 0, 0), (s, 0.04, -7)])


@snd("ability.h", "sfx", note="Radio chirp climbing with a bright bell shimmer.")
def _():
    c = chirp(600, 2300, 0.2, "square", 4000)
    return reverb(mix([(squelch(0.06), 0, -8), (c, 0.02, -2), (bell(1760, 0.6, 1.0), 0.18, -6), (bell(2349, 0.5, 1.0), 0.24, -10)]), 0.5, 0.15)


@snd("ability.z", "sfx", note="A rising wail with a hiss: something hungry woke up.")
def _():
    w = growl(RPG + "NPC/shade/shade1.wav", -3, 0.55, 3500)
    return mix([(w, 0, 0), (hiss(0.5, 4000, 9500, 0, True), 0.1, -12), (thump(60, 0.2, 1.6, 0.06, 0), 0.0, -6)])


@snd("dot.h", "sfx", note="A small sizzle: burning or bleeding, ticking down.")
def _():
    return mix([(dsp.crackle(0.16, 220, 2500, 9000, 0.0025), 0, 0), (osc("sine", 900, 0.03) * dsp.env_ad(0.03, 0.001, 0.008), 0, -10)])


@snd("dot.z", "sfx", note="A single heavy drip: venom, ticking down.")
def _():
    d = osc("sine", dsp.sweep(520, 160, 0.1), 0.1) * dsp.env_ad(0.1, 0.002, 0.03)
    return mix([(d, 0, 0), (wet(RPG + "NPC/slime/slime3.wav", -6, 1800, 0.14), 0, -9)])


@snd("healtick.h", "sfx", note="One soft high 'tink': a point of health returning.")
def _():
    return bell(1320, 0.35, 0.5) * 0.9


@snd("healtick.z", "sfx", note="A warm low pulse: blood moving.")
def _():
    return mix([(thump(118, 0.3, 1.25, 0.1, 0), 0, 0), (lp(osc("tri", 220, 0.25), 500) * dsp.env_ad(0.25, 0.04, 0.08), 0, -10)])


@snd("fell.h", "stinger", note="A thud and a radio carrier falling away to nothing: you're down.")
def _():
    sig = lp(osc("square", dsp.sweep(720, 140, 1.4), 1.4), 2200) * dsp.env_ad(1.4, 0.01, 0.55)
    st = bp(noise(1.5), 900, 4000) * np.linspace(0.8, 0, n_of(1.5)) ** 2
    return reverb(mix([(thump(52, 0.5, 2.0, 0.14, 0.3), 0, 0), (sig, 0.05, -9), (st, 0.05, -10), (squelch(0.14), 1.3, -8)]), 0.9, 0.16)


@snd("fell.z", "stinger", note="A guttural groan sinking, a heartbeat slowing to a stop.")
def _():
    g = growl(RPG + "NPC/gutteral beast/mnstr14.wav", -9, 2.0, 900)
    h = beats([0.2, 0.75, 1.5], [1.0, 0.75, 0.5])
    return reverb(mix([(g, 0, -1), (h, 0, -3)]), 1.0, 0.2, 2200)


@snd("held.h", "stinger", maxdur=2.2, note="Short brass-and-radio stinger, resolving upward: you held the line.")
def _():
    n = [(196, 0.0, 0.2), (262, 0.16, 0.2), (330, 0.32, 0.22), (392, 0.5, 1.2)]
    y = mix([(brass(f, d + 0.1, 1.0), t, 0) for f, t, d in n] + [(brass(f, 1.1, 0.6), 0.5, -6) for f in (262, 330, 523)])
    return reverb(mix([(squelch(0.1), 0, -9), (y, 0.0, -3), (rawn(R50 + "metalLatch.ogg"), 0, -10)]), 0.9, 0.2)


@snd("held.z", "stinger", maxdur=2.2, note="A low swell and a satisfied exhale over two strong beats: fed.")
def _():
    p = pad([55, 82.4, 110, 130.8], 2.0, 700, 0.5, 0.8)
    g = growl(RPG + "NPC/giant/giant4.wav", -7, 0.8, 1200)
    return reverb(mix([(p, 0, -4), (g, 0.25, -2), (beats([0.15, 0.7], [1.2, 1.0]), 0, -2)]), 1.0, 0.2, 2200)


# ====================================================================
# LOOT & REWARDS
# ====================================================================

@snd("flip.h", "sfx", note="A card turning over on a table.")
def _():
    return mix([(rawn(R50 + "bookFlip1.ogg", end=0.3), 0, 0), (rawn(R50 + "bookPlace3.ogg"), 0.16, -9)])


@snd("flip.z", "sfx", note="A slick, damp flip.")
def _():
    f = wet(R50 + "bookFlip1.ogg", -6, 3000)[: n_of(0.32)]
    return mix([(f, 0, 0), (wet(RPG + "NPC/slime/slime4.wav", -6, 2200, 0.16), 0.1, -8)])


@snd("rar_common.h", "reward", note="Rarity 1: one soft bell.")
def _():
    return reverb(mix([(bell(659, 0.7, 0.6), 0, 0), (rawn(R50 + "bookPlace1.ogg", end=0.1), 0, -12)]), 0.4, 0.12)


@snd("rar_uncommon.h", "reward", note="Rarity 2: two rising bells and a glint.")
def _():
    return reverb(mix([(bell(659, 0.9, 0.8), 0, 0), (bell(988, 1.0, 0.8), 0.1, -1), (dsp.crackle(0.2, 60, 5000, 11000, 0.001), 0.1, -16)]), 0.6, 0.15)


@snd("rar_rare.h", "reward", note="Rarity 3: a bright four-note arpeggio over a swelling pad.")
def _():
    a = chime_arp([523, 659, 784, 1047], 0.09, 1.2, 1.0, 1.0, 0)
    p = pad([262, 330, 392], 1.4, 2200, 0.2, 0.7)
    return reverb(mix([(a, 0, 0), (p, 0.05, -12), (thump(90, 0.15, 1.5, 0.04, 0), 0, -10)]), 1.0, 0.22)


@snd("rar_legendary.h", "reward", maxdur=3.2, note="LEGENDARY: brass chord swell, bell cascade, sub boom, radio glitter. Longest, fullest.")
def _():
    ch = mix([(brass(f, 2.4, 1.0, atk=0.12), 0.1, -4) for f in (196, 262, 330, 392, 523)])
    cas = chime_arp([1047, 1319, 1568, 2093, 2637], 0.1, 1.5, 1.0, 1.0, 1.0)
    boom = thump(42, 0.9, 2.5, 0.28, 0.1)
    return reverb(mix([(boom, 0, 0), (ch, 0, 0), (cas, 0.35, -5), (dsp.crackle(1.0, 120, 4000, 12000, 0.001), 0.3, -16), (squelch(0.12), 0, -9)]), 1.6, 0.22)


@snd("rar_common.z", "reward", note="Rarity 1: one beat and a low bell.")
def _():
    return reverb(mix([(beat(0.8), 0, 0), (bell(220, 0.9, 0.3, 0.7), 0.12, -4)]), 0.6, 0.14, 2500)


@snd("rar_uncommon.z", "reward", note="Rarity 2: two beats over a minor third of dark bells.")
def _():
    return reverb(mix([(beats([0, 0.45], [0.9, 1.1]), 0, -2), (bell(247, 1.1, 0.35, 0.7), 0.1, -3), (bell(294, 1.1, 0.35, 0.7), 0.3, -4)]), 0.8, 0.16, 2500)


@snd("rar_rare.z", "reward", note="Rarity 3: three beats, a growl swell, a falling minor arpeggio of dark bells.")
def _():
    a = chime_arp([440, 392, 330, 262], 0.12, 1.3, 0.4, 0.8, 0.5)
    g = growl(RPG + "NPC/giant/giant3.wav", -6, 0.7, 1500)
    return reverb(mix([(beats([0, 0.4, 0.8], [0.9, 1.0, 1.2]), 0, -1), (a, 0.1, -3), (g, 0.55, -5), (pad([110, 131, 165], 1.4, 900, 0.5, 0.6), 0, -10)]), 1.0, 0.2, 2400)


@snd("rar_legendary.z", "reward", maxdur=3.2, note="LEGENDARY: triple heartbeat, dark choir pad, guttural roar, hiss glitter, sub boom.")
def _():
    choir = pad([110, 165, 220, 262, 330], 2.6, 1400, 0.9, 1.0)
    # vowel colour: two resonant peaks
    choir = (svf_bp(choir, 520, 3.0) + 0.7 * svf_bp(choir, 1150, 3.0)) * 2.2
    g = growl(RPG + "NPC/ogre/ogre3.wav", -8, 1.0, 1800)
    return reverb(mix([(thump(38, 1.0, 2.4, 0.3, 0.1), 0, 0), (beats([0.05, 0.5, 0.95], [1.1, 1.2, 1.4]), 0, -2), (choir, 0.1, -6), (g, 0.9, -3),
                       (hiss(1.6, 4500, 11000, 9.0, True), 0.6, -16), (bell(330, 2, 0.4, 0.7), 0.2, -8)]), 1.8, 0.24, 2500)


@snd("xp.h", "ui", note="A tiny bright pluck, played repeatedly as the XP bar fills (pitch climbs in code).")
def _():
    return bell(1760, 0.1, 0.4) * 0.9


@snd("xp.z", "ui", note="A tiny low blip for the same job.")
def _():
    return thump(150, 0.09, 1.3, 0.03, 0)


@snd("levelup.h", "stinger", maxdur=3.0, note="LEVEL UP: radio squelch, brass fanfare (rising fourth, held major chord), bell sparkle. About 2.6 s.")
def _():
    run = [(196, 0.0, 0.17), (262, 0.19, 0.17), (330, 0.38, 0.17), (392, 0.57, 0.17)]
    y = mix([(brass(f, d + 0.12, 1.0), t, 0) for f, t, d in run])
    held = mix([(brass(f, 1.9, 1.0, atk=0.04), 0.78, -2 if f < 400 else -5) for f in (262, 330, 392, 523)])
    spark = chime_arp([1568, 2093, 2637, 3136], 0.07, 1.0, 1.0, 1.0, 1.5)
    return reverb(mix([(squelch(0.1), 0, -8), (y, 0.06, 0), (held, 0.06, 0), (spark, 0.85, -9), (rawn(R50 + "metalLatch.ogg"), 0.0, -9), (thump(65, 0.4, 2.0, 0.1, 0.2), 0.78, -3)]), 1.0, 0.22)


@snd("levelup.z", "stinger", maxdur=3.0, note="LEVEL UP: guttural swell: sub drone climbing, dark chord opening, a roar, heartbeats. About 2.6 s.")
def _():
    t = 2.6
    rise = pad([55, 82.4, 98, 130.8], t, 500, 1.4, 0.9)
    open_ = svf_lp(dsp.supersaw(110, t, cents=(-14, -5, 6, 15)) + dsp.supersaw(165, t, cents=(-10, 8)) * 0.6, dsp.sweep(300, 2600, t), 1.2) * dsp.adsr(t, 1.2, 0.1, 0.9, 0.9)
    g = growl(RPG + "NPC/giant/giant2.wav", -8, 1.1, 1500)
    sub = osc("sine", dsp.sweep(34, 60, t), t) * dsp.adsr(t, 0.8, 0.1, 0.9, 0.8)
    return reverb(mix([(sub, 0, -3), (rise, 0, -4), (open_, 0.1, -8), (g, 1.2, -1), (beats([0.2, 0.55, 0.85, 1.1], [0.8, 0.9, 1.0, 1.2]), 0, -3),
                       (hiss(1.0, 4500, 10000, 7.0, True), 1.4, -15)]), 1.4, 0.2, 2500)


# ====================================================================
# SIGNALS
# ====================================================================

@snd("contact.h", "alarm", maxdur=3.0, kbps=128, note="CONTACT: emergency klaxon. Radio key-up, three alert chirps, then a hi-lo two-tone siren (4 cycles) with static. Bright, dense, ~2.6 s.")
def _():
    total = 2.7
    out = [(squelch(0.12, 800, 4200), 0, -3)]
    # three urgent chirps
    for i in range(3):
        out.append((chirp(2200, 2200, 0.07, "square", 6500), 0.13 + i * 0.1, -3))
    # hi-lo siren, two harmonics each so it cuts through speaker roll-off
    for i in range(4):
        t0 = 0.5 + i * 0.5
        hi_ = osc("saw", 960, 0.25) * dsp.adsr(0.25, 0.008, 0.02, 1.0, 0.02)
        lo_ = osc("saw", 770, 0.25) * dsp.adsr(0.25, 0.008, 0.02, 1.0, 0.02)
        out.append((lp(hi_, 6000), t0, 0))
        out.append((lp(lo_, 6000), t0 + 0.25, 0))
    sirens = mix(out, total)
    stat = bp(noise(total), 1500, 7000) * (0.5 + 0.5 * np.sin(2 * np.pi * 9 * tline(total))) * 0.35
    stat = stat * np.concatenate([np.ones(n_of(0.45)), np.linspace(1, 0.4, len(stat) - n_of(0.45))])
    y = sat(mix([(sirens, 0, 0), (stat, 0, -7), (thump(80, 0.3, 2.0, 0.08, 0.2), 0, -3)]), 1.6)
    return reverb(y, 0.7, 0.16)


@snd("contact.z", "alarm", maxdur=3.0, kbps=128, note="CONTACT: predatory. A heartbeat spike that accelerates, a hiss swelling with a rattle, a roar, then a rising screech. ~2.6 s.")
def _():
    total = 2.7
    bt = [0.0, 0.52, 0.98, 1.38, 1.72, 2.02, 2.3]
    st = [1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6]
    h = mix([(beat(s * 1.2, 0.14), t, 0) for t, s in zip(bt, st)], total)
    hs = hiss(2.2, 3500, 10500, 15.0, True) * 1.0
    roar = growl(G16 + "monster.15.ogg", -3, 0.9, 5000)
    scr = sat(osc("saw", dsp.sweep(620, 1900, 0.9) * (1 + 0.02 * np.sin(2 * np.pi * 7 * tline(0.9))), 0.9), 1.5)
    scr = lp(scr, 5200) * dsp.adsr(0.9, 0.3, 0.1, 0.9, 0.12)
    drone = lp(osc("saw", 55, total) + osc("saw", 77.8, total), 400) * dsp.adsr(total, 0.1, 0.1, 1.0, 0.5) * 0.5
    y = mix([(h, 0, 0), (hs, 0.3, -6), (roar, 1.0, -2), (scr, 1.7, -8), (drone, 0, -6)], total)
    return sat(reverb(y, 0.9, 0.16, 3500)[: n_of(total)], 1.4)


@snd("ping.h", "sfx", note="Hostile signal, subtle: a faint sonar blip with two echoes.")
def _():
    b = osc("sine", 1180, 0.09) * dsp.env_ad(0.09, 0.006, 0.03)
    return dsp.echo(b, 0.22, 0.42, 2, 2500)


@snd("ping.z", "sfx", note="Hostile signal, subtle: two soft low throbs, like a pulse felt through the floor.")
def _():
    return mix([(thump(76, 0.28, 1.6, 0.09, 0), 0, 0), (thump(68, 0.24, 1.5, 0.08, 0), 0.26, -4)])


@snd("echo.h", "sfx", note="Echo report: a pager's three short beeps.")
def _():
    b = [(radio_beep(), i * 0.13, 0) for i in range(3)]
    return reverb(mix(b), 0.4, 0.12)


def radio_beep():
    return lp(osc("square", 1450, 0.07), 3500) * dsp.adsr(0.07, 0.004, 0.01, 1.0, 0.012)


@snd("echo.z", "sfx", note="Echo report: two wet pulses and a faint whisper of breath.")
def _():
    w = bp(noise(0.5), 2500, 7500) * np.sin(np.linspace(0, np.pi, n_of(0.5))) ** 2 * 0.5
    return mix([(beat(0.8, 0.2), 0, 0), (w, 0.1, -19)])


@snd("downed.h", "stinger", note="Signal lost: static swell, a falling carrier, a thud.")
def _():
    sig = lp(osc("saw", dsp.sweep(520, 120, 1.5), 1.5), 1800) * dsp.env_ad(1.5, 0.01, 0.6)
    st = bp(noise(1.6), 800, 4500) * np.linspace(0.2, 1, n_of(1.6)) ** 1.5 * np.linspace(1, 0, n_of(1.6)) ** 0.5
    return reverb(mix([(thump(44, 0.7, 2.0, 0.2, 0.2), 0, 0), (sig, 0.02, -8), (st, 0.1, -9)]), 1.0, 0.18)


@snd("downed.z", "stinger", note="Going under: two heavy beats slowing, a long exhale sinking.")
def _():
    ex = svf_lp(noise(1.8, "pink"), dsp.sweep(1400, 120, 1.8), 1.0) * np.sin(np.linspace(0, np.pi, n_of(1.8))) ** 1.2 * 2.0
    return reverb(mix([(beats([0.05, 0.8], [1.2, 0.8]), 0, 0), (ex, 0.2, -4), (thump(40, 0.8, 2.0, 0.25, 0.1), 0.0, -5)]), 1.0, 0.18, 2200)


@snd("revived.h", "stinger", note="Defibrillator charge climbing, a thump, then a clean bright chime: back up.")
def _():
    ch = lp(osc("sine", dsp.sweep(300, 1600, 0.7), 0.7), 5000) * dsp.adsr(0.7, 0.05, 0.1, 0.9, 0.04) * 0.6
    return reverb(mix([(ch, 0, 0), (thump(70, 0.35, 2.2, 0.1, 0.3), 0.72, 0), (bell(1047, 1.2, 0.9), 0.78, -3), (bell(1568, 1.2, 0.9), 0.9, -6)]), 0.9, 0.2)


@snd("revived.z", "stinger", note="A sharp inhale, then the heart restarts strong.")
def _():
    inh = svf_bp(noise(0.55, "pink"), dsp.sweep(300, 1800, 0.55), 1.4) * dsp.env_ad(0.55, 0.3, 0.2) * 2.5
    return reverb(mix([(inh, 0, -2), (beats([0.55, 1.05], [1.4, 1.3]), 0, 0), (pad([55, 82.4], 1.5, 500, 0.4, 0.8), 0.6, -8)]), 0.9, 0.18, 2500)


# ====================================================================
# SHARED / ONBOARDING (neutral)
# ====================================================================

@snd("broadcast", "onboard", kbps=96, note="Emergency broadcast: static opens, the dual-tone attention signal sounds, static swallows it. ~3.4 s.")
def _():
    total = 3.4
    st = raw(STATIC, start=20.0, end=20.0 + total, do_trim=False)
    st = bp(st / (dsp.peak(st) + 1e-9), 300, 6500, 2)
    tone = (osc("sine", 853, 1.6) + osc("sine", 960, 1.6)) * 0.5
    tone = tone * dsp.adsr(1.6, 0.02, 0.0, 1.0, 0.03)
    env = np.concatenate([np.linspace(0.25, 1, n_of(0.35)) ** 2, np.ones(n_of(0.1)), np.full(n_of(1.6), 0.25), np.linspace(0.25, 0, len(st) - n_of(2.05)) ** 0.7])
    st = st[: len(env)] * env[: len(st)]
    return mix([(st, 0, -2), (tone, 0.45, -2), (squelch(0.1), 0.38, -10)], total)


for i in range(3):
    def _mk(i=i):
        @snd(f"type{i}", "ui", fin=0.001, fout=0.002, note="Typewriter / teletype tick (three variants, rotated).")
        def _():
            f = [2300, 1800, 2700][i]
            c = bp(noise(0.03), f * 0.7, f * 1.4) * dsp.env_ad(0.03, 0.0005, 0.005)
            return mix([(c, 0, 0), (thump([210, 170, 250][i], 0.04, 1.3, 0.01, 0) * 0.5, 0, -6)])
    _mk()


@snd("heart", "sfx", note="One lub-dub. The code repeats it, faster and harder as the hold builds.")
def _():
    return beat(1.0)


@snd("bitten", "onboard", note="The bite: a crunch, a wet tear, a low impact, two fast heartbeats and a thin whine.")
def _():
    crunch = wet(R50 + "chop.ogg", -4, 4500)
    tear = wet(RPG + "NPC/slime/slime6.wav", -3, 3500)
    whine = osc("sine", dsp.sweep(2400, 3300, 1.2), 1.2) * dsp.env_ad(1.2, 0.3, 0.5) * 0.1
    bite = rawn(RPG + "NPC/beetle/bite-small2.wav")
    return reverb(mix([(thump(46, 0.6, 2.2, 0.18, 0.3), 0, 0), (crunch, 0, -2), (bite, 0, -4), (tear, 0.06, -4), (beats([0.5, 0.95], [1.4, 1.5]), 0, -2), (whine, 0.2, -4)]), 1.0, 0.18, 3000)


@snd("riser", "onboard", note="Hold-to-commit riser, exactly 3.0 s: rising noise and tone, accelerating pulse. Ends at full intensity.")
def _():
    t = 3.0
    tt = tline(t)
    k = tt / t
    sweep_n = svf_bp(noise(t), 200 * (14 ** k), 1.8) * (0.15 + 0.85 * k ** 2) * 3.0
    tone = lp(osc("saw", 70 * (7 ** k), t), 3500) * (0.1 + 0.9 * k ** 2) * 0.55
    # pulse that accelerates from ~1 Hz to ~6 Hz
    ph = np.cumsum(1 + 5 * k ** 1.5) / SR
    pulse = (0.55 + 0.45 * np.maximum(0, np.sin(2 * np.pi * ph)) ** 2)
    low = osc("sine", 48 * (1.6 ** k), t) * (0.3 + 0.7 * k)
    y = (sweep_n * 0.7 + tone * 0.7) * pulse + low * 0.6
    return y.astype(np.float32)


@snd("commit", "onboard", kbps=128, note="Commit impact: a huge low boom with a crack and a long dark tail.")
def _():
    boom = thump(40, 1.4, 3.0, 0.35, 0.3)
    crack = bp(noise(0.25), 800, 9000) * dsp.env_ad(0.25, 0.001, 0.05)
    return reverb(mix([(boom, 0, 0), (crack, 0, -2), (rawn(R50 + "doorClose_3.ogg"), 0, -5), (thump(90, 0.4, 2, 0.1, 0), 0.0, -2)]), 2.0, 0.28, 3500)


@snd("burn", "onboard", note="The other half burns or dissolves away: a roaring sweep with crackle. ~2.4 s.")
def _():
    t = 2.4
    w = svf_bp(noise(t, "pink"), dsp.sweep(250, 3200, t), 1.2) * np.sin(np.linspace(0, np.pi, n_of(t))) ** 1.3 * 3.0
    cr = dsp.crackle(t, 90, 1800, 9000, 0.003) * np.sin(np.linspace(0, np.pi, n_of(t))) ** 0.6 * 1.2
    low = lp(noise(t, "brown"), 200) * np.sin(np.linspace(0, np.pi, n_of(t))) ** 2 * 4
    return mix([(w, 0, 0), (cr, 0, -4), (low, 0, -3)])


@snd("flatline", "onboard", loop=True, note="The long flat tone (looped by code, faded out on stop).")
def _():
    t = 1.0
    f = 880.0
    y = (osc("sine", f, t) + 0.25 * osc("sine", f * 2, t)) * 0.8
    return y.astype(np.float32)
