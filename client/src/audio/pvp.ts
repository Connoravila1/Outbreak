// The sound of a fight against a real person. These are made in code (engine.synth) rather than
// recorded: a low impact, a dissonant stab and a sweep, built to be heavier than anything in a PvE fight.
// The heartbeat bed that follows the fight uses the recorded heart in fx.ts.
import { duck, synth } from './engine';
import * as haptics from '../native/haptics';

type Who = 'h' | 'z';

function noise(c: AudioContext, seconds: number): AudioBufferSourceNode {
  const buf = c.createBuffer(1, Math.ceil(c.sampleRate * seconds), c.sampleRate);
  const d = buf.getChannelData(0);
  for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
  const src = c.createBufferSource();
  src.buffer = buf;
  return src;
}

/** Sine that falls in pitch: the weight under every sting. */
function thump(c: AudioContext, out: AudioNode, t: number, from: number, to: number, len: number, peak: number) {
  const o = c.createOscillator();
  const g = c.createGain();
  o.type = 'sine';
  o.frequency.setValueAtTime(from, t);
  o.frequency.exponentialRampToValueAtTime(to, t + len * 0.8);
  g.gain.setValueAtTime(0.0001, t);
  g.gain.exponentialRampToValueAtTime(peak, t + 0.012);
  g.gain.exponentialRampToValueAtTime(0.0001, t + len);
  o.connect(g).connect(out);
  o.start(t);
  o.stop(t + len + 0.05);
}

function burst(c: AudioContext, out: AudioNode, t: number, len: number, peak: number, hz: number, q = 0.7) {
  const n = noise(c, len);
  const f = c.createBiquadFilter();
  f.type = 'bandpass';
  f.frequency.setValueAtTime(hz * 2.5, t);
  f.frequency.exponentialRampToValueAtTime(hz, t + len);
  f.Q.value = q;
  const g = c.createGain();
  g.gain.setValueAtTime(peak, t);
  g.gain.exponentialRampToValueAtTime(0.0001, t + len);
  n.connect(f).connect(g).connect(out);
  n.start(t);
}

/** A held chord through a lowpass that opens and closes. */
function chord(c: AudioContext, out: AudioNode, t: number, hz: number[], type: OscillatorType, len: number, peak: number, cutoff: number) {
  const f = c.createBiquadFilter();
  f.type = 'lowpass';
  f.frequency.setValueAtTime(cutoff * 0.4, t);
  f.frequency.linearRampToValueAtTime(cutoff, t + len * 0.25);
  f.frequency.exponentialRampToValueAtTime(cutoff * 0.35, t + len);
  const g = c.createGain();
  g.gain.setValueAtTime(0.0001, t);
  g.gain.exponentialRampToValueAtTime(peak, t + 0.03);
  g.gain.exponentialRampToValueAtTime(0.0001, t + len);
  f.connect(g).connect(out);
  for (const h of hz) {
    for (const det of [-6, 6]) {
      const o = c.createOscillator();
      o.type = type;
      o.frequency.value = h;
      o.detune.value = det;
      o.connect(f);
      o.start(t);
      o.stop(t + len + 0.05);
    }
  }
}

/** Two worlds meet: the stab that lands as the opposing lens tears in. `me` is the listener's own side. */
export function contactSting(me: Who) {
  synth('sfx', (c, out, t) => {
    thump(c, out, t, 120, 34, 1.1, 0.9);
    burst(c, out, t, 0.5, 0.35, 900);
    if (me === 'h') {
      // survey: a brass-like minor second over a low fifth, clipped short
      chord(c, out, t + 0.04, [110, 116.5, 165], 'sawtooth', 0.9, 0.16, 1800);
    } else {
      // heat: a low dissonance that drifts flat, like something large breathing out
      chord(c, out, t + 0.04, [55, 58.3, 82.4], 'sawtooth', 1.3, 0.2, 700);
      const o = c.createOscillator();
      const g = c.createGain();
      o.type = 'triangle';
      o.frequency.setValueAtTime(420, t + 0.1);
      o.frequency.exponentialRampToValueAtTime(70, t + 1.2);
      g.gain.setValueAtTime(0.0001, t + 0.1);
      g.gain.exponentialRampToValueAtTime(0.08, t + 0.2);
      g.gain.exponentialRampToValueAtTime(0.0001, t + 1.2);
      o.connect(g).connect(out);
      o.start(t + 0.1);
      o.stop(t + 1.3);
    }
  });
  duck(-14, 1.6);
  haptics.vibrate([60, 40, 140]);
}

/** The last blow: a big hit, then a resolution that is bright if you held and falls away if you did not. */
export function finalBlow(won: boolean, me: Who) {
  synth('sfx', (c, out, t) => {
    thump(c, out, t, 150, 30, 1.3, 1.0);
    burst(c, out, t, 0.7, 0.45, 600);
    burst(c, out, t, 0.12, 0.5, 3200, 1.5);
    const root = me === 'h' ? 98 : 65.4;
    // a fifth stacked on the root: lifts to a major third if you won, sinks to a minor second if not
    const chordHz = won ? [root, root * 1.5, root * 2 * 1.26] : [root, root * 1.5 * 0.94, root * 2 * 1.06];
    chord(c, out, t + 0.18, chordHz, me === 'h' ? 'sawtooth' : 'square', 1.7, won ? 0.14 : 0.12, won ? 2400 : 900);
    if (!won) {
      const o = c.createOscillator();
      const g = c.createGain();
      o.type = 'sine';
      o.frequency.setValueAtTime(260, t + 0.2);
      o.frequency.exponentialRampToValueAtTime(40, t + 1.6);
      g.gain.setValueAtTime(0.2, t + 0.2);
      g.gain.exponentialRampToValueAtTime(0.0001, t + 1.6);
      o.connect(g).connect(out);
      o.start(t + 0.2);
      o.stop(t + 1.7);
    }
  });
  duck(-12, 1.2);
  haptics.vibrate([90, 40, 220]);
}

/** The beat on a crit: the world drops a gear. A downward sweep with a low thud. */
export function slowMo() {
  synth('sfx', (c, out, t) => {
    const n = noise(c, 0.7);
    const f = c.createBiquadFilter();
    f.type = 'lowpass';
    f.frequency.setValueAtTime(5000, t);
    f.frequency.exponentialRampToValueAtTime(140, t + 0.65);
    const g = c.createGain();
    g.gain.setValueAtTime(0.28, t);
    g.gain.exponentialRampToValueAtTime(0.0001, t + 0.7);
    n.connect(f).connect(g).connect(out);
    n.start(t);
    thump(c, out, t + 0.02, 90, 28, 0.7, 0.6);
  });
}
