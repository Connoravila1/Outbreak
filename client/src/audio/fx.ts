import { hapticsOn, soundOn } from '../state/store';

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
  if (!hapticsOn.peek()) return;
  try { navigator.vibrate?.(pattern); } catch { /* unsupported */ }
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
