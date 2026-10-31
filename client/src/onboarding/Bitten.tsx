import { useEffect, useMemo, useState } from 'preact/hooks';
import { bitten, heartbeatLoop, unlockAudio } from '../audio/fx';
import { reducedMotion } from '../state/store';

function rnd(seed: number) {
  let s = seed;
  return () => { s = (s * 16807) % 2147483647; return s / 2147483647; };
}

/** Wobbling vein paths that grow from the screen edges toward the centre. */
function makeVeins(): { d: string; delay: number; w: number }[] {
  const r = rnd(42);
  const out: { d: string; delay: number; w: number }[] = [];
  for (let k = 0; k < 16; k++) {
    // start on one of the four edges of a 100x200 box
    const side = k % 4;
    let x = side === 0 ? 0 : side === 3 ? 100 : r() * 100;
    let y = side === 1 ? 200 : side === 2 ? 0 : r() * 200;
    let d = `M${x.toFixed(1)} ${y.toFixed(1)}`;
    const steps = 6 + Math.floor(r() * 4);
    for (let i = 0; i < steps; i++) {
      const tx = (50 - x) * 0.16 + (r() - 0.5) * 18;
      const ty = (100 - y) * 0.16 + (r() - 0.5) * 18;
      const nx = x + tx, ny = y + ty;
      d += ` Q${(x + (r() - 0.5) * 14 + tx / 2).toFixed(1)} ${(y + (r() - 0.5) * 14 + ty / 2).toFixed(1)} ${nx.toFixed(1)} ${ny.toFixed(1)}`;
      x = nx; y = ny;
    }
    out.push({ d, delay: r() * 2.4, w: 0.5 + r() * 1.1 });
  }
  return out;
}

/** "You've been bitten." Veins creep in, the heart beats, the screen pulses. */
export function Bitten({ onDone }: { onDone: () => void }) {
  const veins = useMemo(makeVeins, []);
  const [beat, setBeat] = useState(0);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    unlockAudio();
    bitten();
    const h = heartbeatLoop(58, 1, () => setBeat((b) => b + 1));
    const t1 = setTimeout(() => h.setBpm(78), 2500);
    const t2 = setTimeout(() => setReady(true), reducedMotion.value ? 800 : 4200);
    return () => { h.stop(); clearTimeout(t1); clearTimeout(t2); };
  }, []);

  return (
    <div class="ob-screen bitten">
      <div class="vignette" key={beat} />
      <svg class="veins" viewBox="0 0 100 200" preserveAspectRatio="none" aria-hidden="true">
        {veins.map((v, i) => (
          <path key={i} d={v.d} pathLength={1} style={{ animationDelay: `${v.delay}s`, strokeWidth: v.w }} />
        ))}
      </svg>
      <div class="bitten-copy">
        <h1 class="bitten-h">You've been bitten.</h1>
        <p class="bitten-sub">It is already in your blood. You can feel it deciding.</p>
        {ready && <button class="btn primary" onClick={onDone} autoFocus>Look around</button>}
      </div>
    </div>
  );
}
