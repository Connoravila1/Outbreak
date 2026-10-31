// The game's sound vocabulary. Names are stable; call sites say what happened, this file says what it sounds like.
// Each event has a Human (survey) and a Zombie (heat) recording, chosen from the current lens.
// Asset-based playback lives in engine.ts; when to play beds and ambient events lives in director.ts.
import * as haptics from '../native/haptics';
import { duck, keyFor, loop, marks, play, preloadAllShort, unlock, variant, type Handle } from './engine';

/** Call from a user gesture so later audio is allowed to play. */
let preloaded: string | null = null;
export function unlockAudio() {
  const c = unlock();
  const v = variant();
  if (c && preloaded !== v) { preloaded = v; preloadAllShort(v); }
}

export function haptic(pattern: number | number[]) {
  haptics.vibrate(pattern);
}

const faction = (base: string) => keyFor(base);

// ---- interface ----

export function tap() { play(faction('tap'), { pitchVar: 60, gainVar: 1.5, minGapMs: 40 }); }
export function tabSwitch() { play(faction('tab'), { pitchVar: 40, minGapMs: 60 }); }
export function sheetOpen() { play(faction('sheet_open'), { minGapMs: 120 }); }
export function sheetClose() { play(faction('sheet_close'), { minGapMs: 120 }); }
export function equip() { play(faction('equip'), { pitchVar: 50 }); haptic(18); }
export function scrap() { play(faction('scrap'), { pitchVar: 50 }); haptic(24); }
export function upgrade() { play(faction('upgrade')); haptic([16, 40, 24]); }
export function heal() { play(faction('heal')); haptic(14); }
export function purchase() { play(faction('purchase'), { pitchVar: 40 }); haptic(12); }
export function claim() { play(faction('claim')); haptic([14, 40, 20]); }
/** A soft refusal. */
export function error() { play(faction('error'), { minGapMs: 250 }); }
/** Hostile signal nearby: subtle on purpose. */
export function ping() { play(faction('ping'), { minGapMs: 2000 }); }
export function echoReport() { play(faction('echo'), { minGapMs: 500 }); }
export function downed() { play(faction('downed'), { prio: 5 }); haptic([60, 40, 160]); }
export function revived() { play(faction('revived'), { prio: 5 }); haptic([30, 40, 80]); }

/** Generic hand-over click; older call sites use this. Prefer the specific names above. */
export function clunk() {
  equip();
}

// ---- onboarding ----

/** Emergency broadcast: static and the attention tone. */
export function broadcast() { marks.broadcastAt = performance.now(); play('broadcast', { prio: 5 }); }

/** Typewriter tick for the broadcast and CONTACT gear list. */
export function tick() {
  play(`type${Math.floor(Math.random() * 3)}`, { pitchVar: 80, gainVar: 2, minGapMs: 20 });
}

/** The bite. */
export function bitten() { play('bitten', { prio: 5 }); haptic([50, 40, 120]); }

function beatGain(strength: number) { return Math.min(1.25, 0.3 + 0.32 * strength); }

/** One lub-dub. */
export function heartbeatOnce(strength = 1) {
  play('heart', { gain: beatGain(strength), rate: 0.96 + Math.min(0.2, strength * 0.05), gainVar: 1, minGapMs: 80 });
  haptic([30 * strength + 10, 90, 20 * strength + 8]);
}

export interface Heart { setBpm(b: number): void; setStrength(s: number): void; stop(): void }

/**
 * A heartbeat loop whose rate and strength can change while it runs.
 * `riser` adds the hold-to-commit swell (3 s) underneath; stop() fades it.
 */
export function heartbeatLoop(bpm = 60, strength = 1, onBeat?: () => void, opts: { riser?: boolean } = {}): Heart {
  let b = bpm, s = strength, alive = true;
  let t: number | null = null;
  const rise: Handle | null = opts.riser ? play('riser', { prio: 6, gain: 0.9 }) : null;
  if (opts.riser) duck(-9, 2.4, 0.3, 0.6);
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
    stop() { alive = false; if (t != null) clearTimeout(t); rise?.stop(0.12); },
  };
}

/** The commit impact, then the long flat tone. Returns a stop function that fades the tone out. */
export function flatline(): () => void {
  haptic(1200);
  play('commit', { prio: 8 });
  duck(-10, 2.5);
  const h = loop('flatline', { gain: 0.35, fadeIn: 0.06 });
  return () => h.stop(0.3);
}

/** The burn / dissolve whoosh. `seconds` stretches it slightly to fit the animation. */
export function rumble(seconds = 2.4) {
  play('burn', { rate: Math.min(1.3, Math.max(0.8, 2.4 / seconds)), prio: 6 });
}

// ---- fight and reward vocabulary ----

export function engage() { play(faction('engage'), { prio: 3 }); }

export function hit() {
  play(faction('hit'), { pitchVar: 120, gainVar: 1.5, minGapMs: 30 });
  haptics.hit();
}

export function crit() {
  play(faction('crit'), { pitchVar: 60, prio: 2 });
  haptics.crit();
}

export function dodge() { play(faction('dodge'), { pitchVar: 100, gainVar: 1.5, minGapMs: 30 }); }

export function abilityCue() { play(faction('ability'), { pitchVar: 50, prio: 2 }); }

export function dotTick() { play(faction('dot'), { pitchVar: 150, gainVar: 2, minGapMs: 60 }); }
export function healTick() { play(faction('healtick'), { pitchVar: 100, gainVar: 1.5, minGapMs: 60 }); }

/** You fell. */
export function fell() { play(faction('fell'), { prio: 5 }); haptic([80, 50, 200]); }
/** You held. */
export function held() { play(faction('held'), { prio: 5 }); haptic([30, 40, 30]); }

/** The XP bar filling: a run of ticks that climbs in pitch. */
export function xpFill(ms = 1300, n = 9) {
  const k = faction('xp');
  for (let i = 0; i < n; i++) {
    window.setTimeout(() => play(k, { rate: 0.85 + (i / (n - 1)) * 0.75, gain: 0.8, minGapMs: 0 }), (ms * i) / n);
  }
}

/** A card turning over. Rarer cards ring higher and last longer. */
export function lootFlip(rarity: 'common' | 'uncommon' | 'rare' | 'legendary' = 'common') {
  if (rarity === 'legendary') { legendary(); return; }
  play(faction('flip'), { pitchVar: 80, gainVar: 1, minGapMs: 0 });
  play(faction(`rar_${rarity}`), { delay: 0.07, prio: 3 });
  haptic(rarity === 'common' ? 8 : 16);
}

export function legendary() {
  play(faction('flip'), { minGapMs: 0 });
  play(faction('rar_legendary'), { delay: 0.07, prio: 6 });
  duck(-9, 2.4);
  haptic([30, 40, 30, 40, 120]);
}

export function levelUp() {
  play(faction('levelup'), { prio: 8 });
  duck(-12, 2.6);
  haptics.levelUp();
}

/** CONTACT: the signature alarm. Everything else gets quieter under it. */
export function contactAlarm() {
  play(faction('contact'), { prio: 9 });
  duck(-16, 2.8);
  haptics.contact();
}
