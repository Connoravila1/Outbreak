// The sound engine: decode each asset once, play it through per-category buses.
//
//   source -> voice gain -> bus (ui | sfx | music | ambience) -> [duck] -> master -> limiter -> out
//
// Nothing here knows about the game. fx.ts names the sounds; director.ts decides when they play.
import { effect } from '@preact/signals';
import { soundOn, lens } from '../state/store';
import { effectsVol, musicVol } from './prefs';

export type Bus = 'ui' | 'sfx' | 'music' | 'ambience';
export type Variant = 'h' | 'z';

interface Entry { file: string; frames: number; rate: number; ch: number; bus: Bus; loop: boolean; dur: number; cat: string }

/** LAME writes about 1105 samples of decoder delay; some decoders strip it, some do not. */
const MP3_DELAY_S = 1105 / 44100;
const BASE = import.meta.env.BASE_URL ?? '/';
const MAX_VOICES: Record<Bus, number> = { ui: 6, sfx: 12, music: 2, ambience: 2 };
/** Per-bus level trims on top of the (already loudness-matched) files. */
const BUS_TRIM: Record<Bus, number> = { ui: 0.8, sfx: 1, music: 0.6, ambience: 0.9 };

let ctx: AudioContext | null = null;
let master: GainNode | null = null;
const buses = {} as Record<Bus, GainNode>;
let duckNode: GainNode | null = null; // music + ambience pass through this
let manifest: Record<string, Entry> | null = null;
let manifestP: Promise<void> | null = null;
const buffers = new Map<string, AudioBuffer | Promise<AudioBuffer | null>>();
const lastPlayed = new Map<string, number>();

interface Voice { key: string; bus: Bus; src: AudioBufferSourceNode; gain: GainNode; t0: number; prio: number }
let voices: Voice[] = [];

/** Timestamps other modules can read (e.g. when the emergency broadcast started). */
export const marks = { broadcastAt: 0 };

export function variant(): Variant { return lens.peek() === 'heat' ? 'z' : 'h'; }

function ensureCtx(): AudioContext | null {
  if (ctx) return ctx;
  try {
    const Ctor = window.AudioContext || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    ctx = new Ctor();
    master = ctx.createGain();
    const lim = ctx.createDynamicsCompressor();
    lim.threshold.value = -4; lim.knee.value = 3; lim.ratio.value = 12; lim.attack.value = 0.002; lim.release.value = 0.12;
    master.connect(lim).connect(ctx.destination);
    duckNode = ctx.createGain();
    duckNode.connect(master);
    for (const b of ['ui', 'sfx', 'music', 'ambience'] as Bus[]) {
      const g = ctx.createGain();
      g.connect(b === 'music' || b === 'ambience' ? duckNode : master);
      buses[b] = g;
    }
    applyVolumes();
    return ctx;
  } catch {
    return null;
  }
}

function applyVolumes() {
  if (!ctx) return;
  const t = ctx.currentTime;
  const set = (b: Bus, v: number) => buses[b].gain.setTargetAtTime(v * BUS_TRIM[b], t, 0.03);
  // a slider is perceptual, so square it
  const fx = effectsVol.peek() ** 2, mu = musicVol.peek() ** 2;
  set('ui', fx); set('sfx', fx); set('music', mu); set('ambience', mu);
}

/** Resume the context. Call from any user gesture; harmless if called often. */
export function unlock(): AudioContext | null {
  if (!soundOn.peek()) return null;
  const c = ensureCtx();
  if (c && c.state !== 'running' && !document.hidden) void c.resume().catch(() => undefined);
  void loadManifest();
  return c;
}

export function suspend() { if (ctx && ctx.state === 'running') void ctx.suspend().catch(() => undefined); }
export function resume() { if (ctx && soundOn.peek() && !document.hidden) void ctx.resume().catch(() => undefined); }

function loadManifest(): Promise<void> {
  manifestP ??= fetch(`${BASE}audio/manifest.json`)
    .then((r) => r.json())
    .then((j) => { manifest = j as Record<string, Entry>; })
    .catch(() => { manifestP = null; });
  return manifestP;
}

function decode(c: AudioContext, data: ArrayBuffer): Promise<AudioBuffer> {
  return new Promise((res, rej) => {
    // Safari older than 14.1 only knows the callback form.
    const p = c.decodeAudioData(data, res, rej);
    if (p && typeof p.then === 'function') p.then(res, rej);
  });
}

function load(key: string): Promise<AudioBuffer | null> {
  const have = buffers.get(key);
  if (have) return Promise.resolve(have);
  const c = ctx;
  if (!c) return Promise.resolve(null);
  const p = (async () => {
    await loadManifest();
    const e = manifest?.[key];
    if (!e) return null;
    try {
      const r = await fetch(`${BASE}audio/${e.file}`);
      const b = await decode(c, await r.arrayBuffer());
      buffers.set(key, b);
      return b;
    } catch {
      buffers.delete(key);
      return null;
    }
  })();
  buffers.set(key, p);
  return p;
}

/** Decode a set of sounds ahead of time (short effects are small; beds are loaded on demand). */
export function preload(keys: string[]) {
  if (!ensureCtx()) return;
  void loadManifest().then(() => { for (const k of keys) void load(k); });
}

export function preloadAllShort(v: Variant) {
  if (!ensureCtx()) return;
  void loadManifest().then(() => {
    if (!manifest) return;
    for (const [k, e] of Object.entries(manifest)) {
      if (e.cat === 'amb' || e.cat === 'music') continue;
      if (k.endsWith('.h') && v !== 'h') continue;
      if (k.endsWith('.z') && v !== 'z') continue;
      void load(k);
    }
  });
}

/** The variant of a sound for the current lens, if it has one. */
export function keyFor(base: string): string {
  const k = `${base}.${variant()}`;
  return manifest && !manifest[k] ? base : k;
}

export interface PlayOpts {
  gain?: number;
  /** playback speed; 1 = as recorded */
  rate?: number;
  /** random pitch spread in cents (repeated hits should not sound identical) */
  pitchVar?: number;
  /** random level spread in dB */
  gainVar?: number;
  /** seconds from now */
  delay?: number;
  prio?: number;
  /** ignore a repeat of the same sound sooner than this many ms */
  minGapMs?: number;
}

export interface Handle { stop(fade?: number): void }
const NOOP: Handle = { stop() { /* nothing playing */ } };

function trimOffset(buf: AudioBuffer, e: Entry): number {
  const expected = e.frames * buf.sampleRate / e.rate;
  return buf.length - expected > 0.006 * buf.sampleRate ? MP3_DELAY_S : 0;
}

function steal(bus: Bus, prio: number): boolean {
  const mine = voices.filter((v) => v.bus === bus);
  if (mine.length < MAX_VOICES[bus]) return true;
  const victim = mine.filter((v) => v.prio <= prio).sort((a, b) => a.prio - b.prio || a.t0 - b.t0)[0];
  if (!victim) return false;
  fadeOutVoice(victim, 0.04);
  return true;
}

function fadeOutVoice(v: Voice, fade: number) {
  if (!ctx) return;
  const t = ctx.currentTime;
  v.gain.gain.cancelScheduledValues(t);
  v.gain.gain.setValueAtTime(v.gain.gain.value, t);
  v.gain.gain.linearRampToValueAtTime(0, t + fade);
  try { v.src.stop(t + fade + 0.01); } catch { /* already stopped */ }
}

/** Play a one-shot by manifest key. Silent if sound is off, locked, or the asset has not decoded yet. */
export function play(key: string, o: PlayOpts = {}): Handle {
  if (!soundOn.peek()) return NOOP;
  const c = ensureCtx();
  if (!c || c.state === 'closed') return NOOP;
  const now = performance.now();
  if (o.minGapMs && now - (lastPlayed.get(key) ?? -1e9) < o.minGapMs) return NOOP;
  lastPlayed.set(key, now);
  const b = buffers.get(key);
  if (!b || b instanceof Promise) {
    // First use: decode, then play late rather than never (only if it is still fresh enough to matter).
    void load(key).then((ok) => {
      if (ok && performance.now() - now < 600) { lastPlayed.delete(key); play(key, o); }
    });
    return NOOP;
  }
  const e = manifest?.[key];
  if (!e) return NOOP;
  const bus = e.bus;
  const prio = o.prio ?? 0;
  if (!steal(bus, prio)) return NOOP;
  const src = c.createBufferSource();
  src.buffer = b;
  const cents = (o.pitchVar ?? 0) * (Math.random() * 2 - 1);
  src.playbackRate.value = (o.rate ?? 1) * 2 ** (cents / 1200);
  const g = c.createGain();
  const dv = (o.gainVar ?? 0) * (Math.random() * 2 - 1);
  g.gain.value = (o.gain ?? 1) * 10 ** (dv / 20);
  src.connect(g).connect(buses[bus]);
  const t0 = c.currentTime + (o.delay ?? 0);
  const off = trimOffset(b, e);
  src.start(t0, off, e.frames / e.rate);
  const v: Voice = { key, bus, src, gain: g, t0: now, prio };
  voices.push(v);
  src.onended = () => { voices = voices.filter((x) => x !== v); src.disconnect(); g.disconnect(); };
  return { stop: (fade = 0.05) => fadeOutVoice(v, fade) };
}

/** Start a looping sound (flatline tone, beds). Returns a handle that fades it out. */
export function loop(key: string, o: { gain?: number; fadeIn?: number } = {}): Handle {
  if (!soundOn.peek()) return NOOP;
  const c = ensureCtx();
  if (!c) return NOOP;
  const b = buffers.get(key);
  if (!b || b instanceof Promise) { if (!b) void load(key); return NOOP; }
  const e = manifest?.[key];
  if (!e) return NOOP;
  const src = c.createBufferSource();
  src.buffer = b;
  const off = trimOffset(b, e);
  src.loop = true;
  src.loopStart = off;
  src.loopEnd = off + e.frames / e.rate;
  const g = c.createGain();
  const t = c.currentTime;
  g.gain.setValueAtTime(0, t);
  g.gain.linearRampToValueAtTime(o.gain ?? 1, t + (o.fadeIn ?? 0.01));
  src.connect(g).connect(buses[e.bus]);
  src.start(t, off);
  const v: Voice = { key, bus: e.bus, src, gain: g, t0: performance.now(), prio: 9 };
  voices.push(v);
  src.onended = () => { voices = voices.filter((x) => x !== v); src.disconnect(); g.disconnect(); };
  return { stop: (fade = 0.25) => fadeOutVoice(v, fade) };
}

/** Make the music and ambience quieter for a moment (CONTACT, level up). */
export function duck(db: number, holdS: number, attackS = 0.08, releaseS = 0.9) {
  if (!ctx || !duckNode) return;
  const g = duckNode.gain;
  const t = ctx.currentTime;
  g.cancelScheduledValues(t);
  g.setValueAtTime(g.value, t);
  g.linearRampToValueAtTime(10 ** (db / 20), t + attackS);
  g.setValueAtTime(10 ** (db / 20), t + attackS + holdS);
  g.linearRampToValueAtTime(1, t + attackS + holdS + releaseS);
}

// ---- beds: at most one music track and one ambience at a time ----

const bed: Record<'music' | 'ambience', { key: string | null; h: Handle }> = {
  music: { key: null, h: NOOP },
  ambience: { key: null, h: NOOP },
};
const wanted: Record<'music' | 'ambience', string | null> = { music: null, ambience: null };
const BED_GAIN = { music: 1, ambience: 1 };

/** Ask for a bed (or null for none). Crossfades; waits for the decode; honours sound on/off and backgrounding. */
export function setBed(slot: 'music' | 'ambience', key: string | null) {
  wanted[slot] = key;
  syncBeds();
}

function syncBeds() {
  for (const slot of ['music', 'ambience'] as const) {
    const want = soundOn.peek() && !document.hidden ? wanted[slot] : null;
    const cur = bed[slot];
    if (cur.key === want) continue;
    cur.h.stop(want ? 1.2 : 0.6);
    cur.key = want;
    cur.h = NOOP;
    if (!want) continue;
    if (!unlock()) { cur.key = null; continue; }
    void load(want).then((b) => {
      // still wanted after the decode?
      if (!b || bed[slot].key !== want || wanted[slot] !== want) return;
      bed[slot].h = loop(want, { gain: BED_GAIN[slot], fadeIn: 2.0 });
    });
  }
}

export function refreshBeds() { syncBeds(); }

// ---- wiring that belongs to the engine itself ----

effect(() => {
  effectsVol.value; musicVol.value;
  applyVolumes();
});
effect(() => {
  if (!soundOn.value) { for (const s of ['music', 'ambience'] as const) { bed[s].h.stop(0.2); bed[s].key = null; } suspend(); }
  else { resume(); syncBeds(); }
});

document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    // sounds fade, then the whole context pauses so nothing plays (or burns battery) in the background
    for (const s of ['music', 'ambience'] as const) { bed[s].h.stop(0.3); bed[s].key = null; }
    window.setTimeout(() => { if (document.hidden) suspend(); }, 400);
  } else {
    resume();
    syncBeds();
  }
});
