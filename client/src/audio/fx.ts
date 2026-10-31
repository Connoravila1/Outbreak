import { soundOn } from '../state/store';
import * as haptics from '../native/haptics';

let ctx: AudioContext | null = null;

function ac(): AudioContext | null {
  if (!soundOn.peek()) return null;
  try {
    ctx ??= new (window.AudioContext || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext)();
    if (ctx.state === 'suspended') void ctx.resume();
    return ctx;
  } catch {
    return null;
  }
}

/** Call from a user gesture so later audio is allowed to play. */
export function unlockAudio() { ac(); }

export function haptic(pattern: number | number[]) {
  haptics.vibrate(pattern);
}

function thumpAt(c: AudioContext, t: number, freq: number, gain: number) {
  const o = c.createOscillator();
  const g = c.createGain();
  o.type = 'sine';
  o.frequency.setValueAtTime(freq * 1.8, t);
  o.frequency.exponentialRampToValueAtTime(freq, t + 0.06);
  g.gain.setValueAtTime(0.0001, t);
  g.gain.exponentialRampToValueAtTime(gain, t + 0.015);
  g.gain.exponentialRampToValueAtTime(0.0001, t + 0.22);
  o.connect(g).connect(c.destination);
  o.start(t);
  o.stop(t + 0.25);
}

/** One lub-dub. */
export function heartbeatOnce(strength = 1) {
  const c = ac();
  if (c) {
    const t = c.currentTime;
    thumpAt(c, t, 52, 0.55 * strength);
    thumpAt(c, t + 0.18, 44, 0.38 * strength);
  }
  haptic([30 * strength + 10, 90, 20 * strength + 8]);
}

export interface Heart { setBpm(b: number): void; setStrength(s: number): void; stop(): void }

/** A heartbeat loop whose rate and strength can change while it runs. */
export function heartbeatLoop(bpm = 60, strength = 1, onBeat?: () => void): Heart {
  let b = bpm, s = strength, alive = true;
  let t: number | null = null;
  const beat = () => {
    if (!alive) return;
    heartbeatOnce(s);
    onBeat?.();
    t = window.setTimeout(beat, 60000 / b);
  };
  beat();
  return {
    setBpm(v) { b = v; },
    setStrength(v) { s = v; },
    stop() { alive = false; if (t != null) clearTimeout(t); },
  };
}

/** The long flat tone. Returns a stop function that fades it out. */
export function flatline(): () => void {
  const c = ac();
  haptic(1200);
  if (!c) return () => undefined;
  const o = c.createOscillator();
  const g = c.createGain();
  o.type = 'sine';
  o.frequency.value = 880;
  g.gain.setValueAtTime(0.0001, c.currentTime);
  g.gain.exponentialRampToValueAtTime(0.09, c.currentTime + 0.05);
  o.connect(g).connect(c.destination);
  o.start();
  return () => {
    g.gain.cancelScheduledValues(c.currentTime);
    g.gain.setValueAtTime(g.gain.value, c.currentTime);
    g.gain.exponentialRampToValueAtTime(0.0001, c.currentTime + 0.25);
    o.stop(c.currentTime + 0.3);
  };
}

/** Typewriter tick for the broadcast. */
export function tick() {
  const c = ac();
  if (!c) return;
  const t = c.currentTime;
  const o = c.createOscillator();
  const g = c.createGain();
  o.type = 'square';
  o.frequency.value = 1500 + Math.random() * 400;
  g.gain.setValueAtTime(0.015, t);
  g.gain.exponentialRampToValueAtTime(0.0001, t + 0.03);
  o.connect(g).connect(c.destination);
  o.start(t);
  o.stop(t + 0.04);
}

/** Short low rumble used for the burn / rot. */
export function rumble(seconds = 1.6) {
  const c = ac();
  if (!c) return;
  const len = Math.floor(c.sampleRate * seconds);
  const buf = c.createBuffer(1, len, c.sampleRate);
  const d = buf.getChannelData(0);
  for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * (1 - i / len);
  const src = c.createBufferSource();
  src.buffer = buf;
  const f = c.createBiquadFilter();
  f.type = 'lowpass';
  f.frequency.value = 280;
  const g = c.createGain();
  g.gain.value = 0.35;
  src.connect(f).connect(g).connect(c.destination);
  src.start();
}

/** A soft click used when an item is handed over. */
export function clunk() {
  const c = ac();
  if (c) thumpAt(c, c.currentTime, 120, 0.3);
  haptic(18);
}

// ---- fight and reward vocabulary ----

function blip(c: AudioContext, t: number, type: OscillatorType, f0: number, f1: number, dur: number, gain: number) {
  const o = c.createOscillator();
  const g = c.createGain();
  o.type = type;
  o.frequency.setValueAtTime(f0, t);
  o.frequency.exponentialRampToValueAtTime(Math.max(20, f1), t + dur);
  g.gain.setValueAtTime(0.0001, t);
  g.gain.exponentialRampToValueAtTime(gain, t + 0.01);
  g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
  o.connect(g).connect(c.destination);
  o.start(t);
  o.stop(t + dur + 0.02);
}

function noiseBurst(c: AudioContext, t: number, dur: number, cutoff: number, gain: number) {
  const len = Math.max(1, Math.floor(c.sampleRate * dur));
  const buf = c.createBuffer(1, len, c.sampleRate);
  const d = buf.getChannelData(0);
  for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * (1 - i / len);
  const src = c.createBufferSource();
  src.buffer = buf;
  const f = c.createBiquadFilter();
  f.type = 'lowpass';
  f.frequency.value = cutoff;
  const g = c.createGain();
  g.gain.value = gain;
  src.connect(f).connect(g).connect(c.destination);
  src.start(t);
}

export function hit() {
  const c = ac();
  if (!c) return;
  noiseBurst(c, c.currentTime, 0.12, 1400, 0.3);
  thumpAt(c, c.currentTime, 90, 0.35);
  haptics.hit();
}

export function crit() {
  const c = ac();
  if (c) {
    const t = c.currentTime;
    noiseBurst(c, t, 0.22, 2600, 0.45);
    thumpAt(c, t, 60, 0.6);
    blip(c, t, 'sawtooth', 420, 110, 0.2, 0.12);
  }
  haptics.crit();
}

export function dodge() {
  const c = ac();
  if (c) blip(c, c.currentTime, 'sine', 300, 1200, 0.16, 0.08);
}

export function abilityCue() {
  const c = ac();
  if (!c) return;
  const t = c.currentTime;
  blip(c, t, 'square', 520, 780, 0.1, 0.05);
  blip(c, t + 0.08, 'square', 780, 1040, 0.14, 0.05);
}

/** A card turning over. Rarer cards ring higher. */
export function lootFlip(rarity: 'common' | 'uncommon' | 'rare' | 'legendary' = 'common') {
  const c = ac();
  if (!c) return;
  const t = c.currentTime;
  noiseBurst(c, t, 0.06, 3000, 0.12);
  const base = { common: 440, uncommon: 523, rare: 660, legendary: 784 }[rarity];
  blip(c, t + 0.03, 'triangle', base, base * 1.5, 0.22, 0.09);
  haptic(rarity === 'common' ? 8 : 16);
}

export function legendary() {
  const c = ac();
  if (c) {
    const t = c.currentTime;
    [523, 659, 784, 1047].forEach((f, i) => blip(c, t + i * 0.11, 'triangle', f, f * 1.01, 0.55, 0.1));
    thumpAt(c, t, 55, 0.5);
  }
  haptic([30, 40, 30, 40, 120]);
}

export function levelUp() {
  const c = ac();
  if (c) {
    const t = c.currentTime;
    [392, 494, 587, 784, 988].forEach((f, i) => blip(c, t + i * 0.09, 'square', f, f, 0.3, 0.05));
    thumpAt(c, t, 48, 0.55);
  }
  haptics.levelUp();
}

/** Two-tone alarm for CONTACT, plus the strong vibration pattern. */
export function contactAlarm() {
  const c = ac();
  if (c) {
    const t = c.currentTime;
    for (let i = 0; i < 4; i++) {
      blip(c, t + i * 0.34, 'sawtooth', 880, 880, 0.15, 0.1);
      blip(c, t + i * 0.34 + 0.17, 'sawtooth', 620, 620, 0.15, 0.1);
    }
  }
  haptics.contact();
}
