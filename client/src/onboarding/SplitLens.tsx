import { useEffect, useRef, useState } from 'preact/hooks';
import { signal } from '@preact/signals';
import type { Map as MlMap } from 'maplibre-gl';
import { api, type Faction, type Factions } from '../api';
import { createMap, maplibregl } from '../map/factory';
import { haptic, flatline, heartbeatLoop, heartbeatOnce, rumble, unlockAudio, type Heart } from '../audio/fx';
import { reducedMotion } from '../state/store';
import type { LatLon } from '../location';

const HOLD_MS = 3000;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, reducedMotion.value ? Math.min(ms, 120) : ms));

const COPY: Record<Faction, { head: string; lines: string[]; btn: string; name: string }> = {
  human: {
    head: 'Fight it. Stay human.',
    lines: [
      'Scavenge, fortify, hold the line.',
      'Resolve: +10% defense, and healing items work 25% better.',
      'You hunt the infected and open supply crates.',
    ],
    btn: 'Hold to stay human',
    name: 'Survivors',
  },
  zombie: {
    head: 'let it in.',
    lines: [
      'mutate, hunt, spread.',
      'hunger: +10% attack. you heal from what you bite.',
      'you hunt the living and feed on fresh remains.',
    ],
    btn: 'hold to let it in',
    name: 'the infected',
  },
};

type Stage = 'choose' | 'flatline' | 'averted' | 'burn' | 'rot' | 'eyes' | 'done';

const seam = signal(0.5);
let seamAnim = 0;
function moveSeam(to: number, ms = 520) {
  cancelAnimationFrame(seamAnim);
  if (reducedMotion.value || ms <= 0) { seam.value = to; return Promise.resolve(); }
  const from = seam.value;
  const t0 = performance.now();
  return new Promise<void>((resolve) => {
    const step = (t: number) => {
      const k = Math.min(1, (t - t0) / ms);
      const e = 1 - Math.pow(1 - k, 3);
      seam.value = from + (to - from) * e;
      if (k < 1) seamAnim = requestAnimationFrame(step); else resolve();
    };
    seamAnim = requestAnimationFrame(step);
  });
}

function ShareLine({ f, data }: { f: Faction; data: Factions | null }) {
  if (!data) return <p class="share">{f === 'human' ? 'Counting survivors…' : 'counting the infected…'}</p>;
  const s = data[f];
  const pct = Math.round(s.share * 100);
  const under = data.underdog === f ? Math.round(data.underdog_bonus * 100) : 0;
  return (
    <div class="share">
      <div class="share-bar" aria-hidden="true"><i style={{ width: `${pct}%` }} /></div>
      <p>
        {f === 'human' ? `${pct}% of players` : `${pct}% of players`}
        <span class="dim"> · {s.players.toLocaleString()}</span>
      </p>
      {under > 0 && <p class="underdog">{f === 'human' ? `Underdog: +${under}% XP this week` : `underdog: +${under}% xp this week`}</p>}
    </div>
  );
}

function Ecg({ stage }: { stage: Stage }) {
  if (stage === 'choose' || stage === 'done') return null;
  const spike = stage === 'averted' || stage === 'burn';
  return (
    <svg class={'ecg' + (spike ? ' spike' : '')} viewBox="0 0 400 80" preserveAspectRatio="none" aria-hidden="true">
      <path key={spike ? 's' : 'f'} pathLength={1} d={spike ? 'M0 40H150L158 36L166 40H190L198 48L208 6L218 70L226 40H400' : 'M0 40H400'} />
    </svg>
  );
}

interface Props { center: LatLon; onChosen: (f: Faction) => void }

/** The signature moment: your real streets, split between the two ways of seeing them. */
export function SplitLens({ center, onChosen }: Props) {
  const root = useRef<HTMLDivElement>(null);
  const hostL = useRef<HTMLDivElement>(null);
  const hostR = useRef<HTMLDivElement>(null);
  const [lean, setLean] = useState<Faction | null>(null);
  const [stage, setStage] = useState<Stage>('choose');
  const [data, setData] = useState<Factions | null>(null);
  const [hold, setHold] = useState(0);
  /** The no-hold way to commit: a button, then a second "are you sure" button (for screen readers, switches, tremor). */
  const [confirming, setConfirming] = useState(false);
  // The tap-to-confirm path stays out of sight until someone taps instead of holding (screen readers send a tap).
  const [altShown, setAltShown] = useState(false);
  const altRef = useRef<HTMLButtonElement>(null);
  useEffect(() => { if (altShown) altRef.current?.focus(); }, [altShown]);
  const drag = useRef(false);
  const holdRaf = useRef(0);
  const heart = useRef<Heart | null>(null);

  useEffect(() => {
    seam.value = 0.5;
    api.factions().then(setData).catch(() => undefined);
    const maps: MlMap[] = [];
    const mk = (host: HTMLElement, lens: 'survey' | 'heat', attribution: boolean) => {
      const m = createMap(host, { lens, center, zoom: 16.6, interactive: false, attribution });
      const dot = document.createElement('div');
      dot.className = `you you-${lens}`;
      dot.innerHTML = '<div class="you-ring" style="width:70px;height:70px"></div><div class="you-dot"></div>';
      new maplibregl.Marker({ element: dot }).setLngLat([center.lon, center.lat]).addTo(m);
      maps.push(m);
    };
    mk(hostL.current!, 'survey', false);
    mk(hostR.current!, 'heat', false);
    const ro = new ResizeObserver(() => maps.forEach((m) => m.resize()));
    ro.observe(root.current!);
    return () => { ro.disconnect(); maps.forEach((m) => m.remove()); cancelAnimationFrame(seamAnim); cancelAnimationFrame(holdRaf.current); heart.current?.stop(); };
  }, []);

  // ----- leaning -----
  const leanTo = (f: Faction | null) => {
    if (stage !== 'choose') return;
    setLean(f);
    setConfirming(false);
    void moveSeam(f === 'human' ? 0.86 : f === 'zombie' ? 0.14 : 0.5);
    haptic(12);
  };

  const keyLean = (e: KeyboardEvent, f: Faction) => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); leanTo(f); }
  };

  const onSeamDown = (e: PointerEvent) => {
    if (stage !== 'choose') return;
    drag.current = true;
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
    cancelAnimationFrame(seamAnim);
    e.preventDefault();
  };
  const onSeamMove = (e: PointerEvent) => {
    if (!drag.current || !root.current) return;
    const r = root.current.getBoundingClientRect();
    seam.value = Math.min(0.95, Math.max(0.05, (e.clientX - r.left) / r.width));
  };
  const onSeamUp = () => {
    if (!drag.current) return;
    drag.current = false;
    const s = seam.value;
    leanTo(s > 0.62 ? 'human' : s < 0.38 ? 'zombie' : null);
  };
  const onSeamKey = (e: KeyboardEvent) => {
    if (e.key === 'ArrowLeft') { seam.value = Math.max(0.05, seam.value - 0.06); e.preventDefault(); }
    else if (e.key === 'ArrowRight') { seam.value = Math.min(0.95, seam.value + 0.06); e.preventDefault(); }
    else return;
    const s = seam.value;
    setLean(s > 0.62 ? 'human' : s < 0.38 ? 'zombie' : null);
    setConfirming(false);
  };

  // ----- hold to commit -----
  const startHold = () => {
    if (!lean || stage !== 'choose' || holdRaf.current) return;
    unlockAudio();
    const t0 = performance.now();
    heart.current = heartbeatLoop(64, 0.8, undefined, { riser: true });
    const step = (t: number) => {
      const k = Math.min(1, (t - t0) / HOLD_MS);
      setHold(k);
      heart.current?.setBpm(64 + k * 96);
      heart.current?.setStrength(0.8 + k * 1.6);
      if (k >= 1) { holdRaf.current = 0; heart.current?.stop(); void commit(lean); return; }
      holdRaf.current = requestAnimationFrame(step);
    };
    holdRaf.current = requestAnimationFrame(step);
  };
  const cancelHold = () => {
    if (stage !== 'choose') return;
    cancelAnimationFrame(holdRaf.current);
    holdRaf.current = 0;
    heart.current?.stop();
    heart.current = null;
    setHold(0);
  };

  // ----- the commit sequences -----
  const commit = async (f: Faction) => {
    setHold(1);
    setStage('flatline');
    haptic([60, 40, 160]);
    const stopTone = flatline();
    if (f === 'human') {
      await sleep(1700);
      stopTone();
      setStage('averted');
      heartbeatOnce(2.4);
      await sleep(900);
      setStage('burn');
      rumble(2.2);
      haptic([40, 30, 40, 30, 120]);
      await moveSeam(1.02, 2400);
      await sleep(400);
    } else {
      await sleep(2300);
      stopTone();
      setStage('rot');
      rumble(2.4);
      haptic([30, 20, 30, 20, 30, 20, 200]);
      await moveSeam(-0.02, 2600);
      await sleep(300);
      setStage('eyes');
      heartbeatOnce(2.6);
      await sleep(1700);
    }
    setStage('done');
    onChosen(f);
  };

  const s = seam.value;
  const sharp = stage === 'choose';
  const rootCls = ['split', `lean-${lean ?? 'none'}`, `stage-${stage}`].join(' ');

  return (
    <div class={rootCls} ref={root} style={{ '--seam': `${s * 100}%`, '--hold': hold } as never}>
      {/* Survey, left */}
      <div class="half half-l" data-scope="survey" style={{ clipPath: `inset(0 ${100 - s * 100}% 0 0)` }}>
        <div class="half-map" ref={hostL} />
        <div class="half-shade" />
        <div class="side-copy side-l" role="button" aria-label={`${COPY.human.name}. ${COPY.human.head} ${COPY.human.lines.join(' ')}`} tabIndex={sharp ? 0 : -1} onClick={() => leanTo('human')} onKeyDown={(e) => keyLean(e, 'human')} aria-pressed={lean === 'human'} aria-disabled={!sharp}>
          <span class="display side-head">{COPY.human.head}</span>
          <ul>{COPY.human.lines.map((l) => <li key={l}>{l}</li>)}</ul>
          <ShareLine f="human" data={data} />
        </div>
      </div>
      {/* Heat, right */}
      <div class="half half-r" data-scope="heat" style={{ clipPath: `inset(0 0 0 ${s * 100}%)` }}>
        <div class="half-map" ref={hostR} />
        <div class="half-shade" />
        <div class="side-copy side-r" role="button" aria-label={`${COPY.zombie.name}. ${COPY.zombie.head} ${COPY.zombie.lines.join(' ')}`} tabIndex={sharp ? 0 : -1} onClick={() => leanTo('zombie')} onKeyDown={(e) => keyLean(e, 'zombie')} aria-pressed={lean === 'zombie'} aria-disabled={!sharp}>
          <span class="display side-head breathe">{COPY.zombie.head}</span>
          <ul>{COPY.zombie.lines.map((l) => <li key={l}>{l}</li>)}</ul>
          <ShareLine f="zombie" data={data} />
        </div>
      </div>

      {/* The seam */}
      {stage !== 'done' && (
        <div
          class={'seam' + (stage === 'burn' ? ' burning' : stage === 'rot' ? ' rotting' : '')}
          style={{ left: `${s * 100}%` }}
          role="slider" tabIndex={sharp ? 0 : -1}
          aria-label="Seam between the two ways of seeing. Left is Survey, right is Heat."
          aria-valuemin={5} aria-valuemax={95} aria-valuenow={Math.round(s * 100)}
          onPointerDown={onSeamDown} onPointerMove={onSeamMove} onPointerUp={onSeamUp} onPointerCancel={onSeamUp}
          onKeyDown={onSeamKey}
        >
          <span class="seam-line" />
          {sharp && <span class="seam-knob" aria-hidden="true">‹ ›</span>}
        </div>
      )}

      <p class="split-attrib">© OpenStreetMap contributors · OpenFreeMap</p>

      {/* Commit controls */}
      {sharp && (
        <div class="commit" data-scope={lean === 'human' ? 'survey' : lean === 'zombie' ? 'heat' : undefined}>
          {lean ? (
            <>
              <p class="perm"><b>This is permanent.</b> There is no cure later.</p>
              <button
                class="hold-btn"
                onPointerDown={(e) => { (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId); startHold(); }}
                onPointerUp={cancelHold} onPointerCancel={cancelHold} onPointerLeave={cancelHold}
                onKeyDown={(e) => { if ((e.key === ' ' || e.key === 'Enter') && !e.repeat) { e.preventDefault(); startHold(); } }}
                onKeyUp={(e) => { if (e.key === ' ' || e.key === 'Enter') cancelHold(); }}
                onContextMenu={(e) => e.preventDefault()}
                onClick={() => setAltShown(true)}
                aria-label={`${COPY[lean].btn}. Hold for three seconds. Release to cancel.`}
              >
                <i class="hold-fill" style={{ width: `${hold * 100}%` }} />
                <span>{COPY[lean].btn}</span>
              </button>
              <p class="hold-hint">{lean === 'human' ? 'Hold for three seconds. Let go to change your mind.' : 'hold for three seconds. let go to change your mind.'}</p>
              {!confirming ? altShown && (
                <button class="alt-commit" ref={altRef} onClick={() => setConfirming(true)}>{lean === 'human' ? 'Cannot hold? Confirm another way' : 'cannot hold? confirm another way'}</button>
              ) : (
                <div class="alt-confirm" role="group" aria-label="Confirm your choice">
                  <p class="perm" role="alert">{lean === 'human' ? 'Are you sure? You will stay human for good.' : 'are you sure? you will be one of the infected for good.'}</p>
                  <div class="alt-row">
                    <button class="btn primary" autofocus ref={(el) => el?.focus()} onClick={() => { unlockAudio(); void commit(lean); }}>{lean === 'human' ? 'Yes, stay human' : 'yes. let it in'}</button>
                    <button class="btn" onClick={() => setConfirming(false)}>{lean === 'human' ? 'Go back' : 'go back'}</button>
                  </div>
                </div>
              )}
            </>
          ) : (
            <p class="perm choose-hint">Drag the seam, or tap a side. You will see your city this way forever.</p>
          )}
        </div>
      )}

      <p class="sr-only" role="status" aria-live="polite">{stage === 'choose' ? (lean ? `${COPY[lean].name} selected.` : '') : 'Choice made.'}</p>
      <Ecg stage={stage} />
      {stage === 'burn' && <div class="ember-wash" aria-hidden="true" />}
      {(stage === 'eyes') && <div class="eyes" aria-hidden="true"><i class="lid top" /><i class="lid bot" /><i class="flash" /></div>}
      {(stage === 'flatline' || stage === 'rot') && <div class={'dim-wash ' + (lean ?? '')} aria-hidden="true" />}
    </div>
  );
}
