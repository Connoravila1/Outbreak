import { useEffect, useState } from 'preact/hooks';
import { tick, unlockAudio } from '../audio/fx';
import { reducedMotion } from '../state/store';

const LINES = [
  'EMERGENCY BROADCAST. ALL STATIONS.',
  '',
  'Containment has failed in every district.',
  'If you can read this, it is already in your city.',
  'Stay off the main roads. Do not trust anyone who is calm.',
  'The infected do not tire. They follow heat, and sound, and',
];

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Black screen. A typed emergency broadcast that stops mid-sentence. */
export function Broadcast({ onDone, onSignIn }: { onDone: () => void; onSignIn: () => void }) {
  const [started, setStarted] = useState(false);
  const [shown, setShown] = useState<string[]>([]);
  const [cut, setCut] = useState(false);

  useEffect(() => {
    if (!started) return;
    let alive = true;
    (async () => {
      const fast = reducedMotion.value;
      for (let i = 0; i < LINES.length && alive; i++) {
        const line = LINES[i];
        for (let c = 1; c <= line.length && alive; c++) {
          setShown((s) => { const n = s.slice(); n[i] = line.slice(0, c); return n; });
          if (c % 2 === 0) tick();
          await sleep(fast ? 3 : 26 + Math.random() * 30);
        }
        if (!line) setShown((s) => { const n = s.slice(); n[i] = ''; return n; });
        await sleep(fast ? 60 : 380);
      }
      if (!alive) return;
      await sleep(fast ? 100 : 900);
      setCut(true);
      await sleep(fast ? 200 : 1300);
      if (alive) onDone();
    })();
    return () => { alive = false; };
  }, [started]);

  return (
    <div class={'ob-screen broadcast' + (cut ? ' cut' : '')}>
      {!started ? (
        <div class="bc-start">
          <button class="bc-tap" onClick={() => { unlockAudio(); setStarted(true); }} autoFocus>
            <span class="bc-dot" aria-hidden="true" />
            Tap to listen
          </button>
          <button class="bc-link quiet" onClick={onSignIn}>Already playing? Sign in</button>
        </div>
      ) : (
        <div class="bc-text" aria-live="polite">
          {shown.map((l, i) => <p key={i}>{l || ' '}{i === shown.length - 1 && !cut && <span class="caret" />}</p>)}
        </div>
      )}
      {cut && <div class="bc-static" aria-hidden="true" />}
    </div>
  );
}
