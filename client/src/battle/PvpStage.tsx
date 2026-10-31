import { useEffect, useLayoutEffect, useMemo, useState } from 'preact/hooks';
import type { ComponentChildren } from 'preact';
import type { Battle, Combatant } from '../api';
import { say } from '../ui/voice';
import { stanceName } from '../state/stance';
import { foeLabel, stampOf } from './names';
import type { Impact } from './Emblem';
import { Silhouette } from './Silhouette';

/** Small deterministic PRNG so the tear and the veins look the same all fight. */
function rng(seed: string) {
  let h = 2166136261;
  for (let i = 0; i < seed.length; i++) { h ^= seed.charCodeAt(i); h = Math.imul(h, 16777619); }
  return () => { h = Math.imul(h ^ (h >>> 15), 2246822507); h = Math.imul(h ^ (h >>> 13), 3266489909); h ^= h >>> 16; return (h >>> 0) / 4294967296; };
}

/** A ragged bottom edge for a sheet of paper, as a clip-path polygon. `drop` pushes it lower (the paper's thickness). */
function tornEdge(seed: string, drop: number): string {
  const r = rng(seed);
  const n = 26;
  const pts: string[] = ['0% 0%', '100% 0%'];
  for (let i = n; i >= 0; i--) {
    const tooth = r() < 0.3 ? 4 + r() * 5 : r() * 2.5;
    pts.push(`${((i / n) * 100).toFixed(1)}% ${(96 - tooth + drop).toFixed(1)}%`);
  }
  return `polygon(${pts.join(',')})`;
}

/** Veins that creep down out of the heat lens: wiggling paths from the top edge, drawn on one by one. */
function Veins({ seed }: { seed: string }) {
  const r = rng(seed);
  const paths = Array.from({ length: 11 }, (_, i) => {
    let x = 6 + (i / 10) * 88 + (r() - 0.5) * 6;
    let y = 0;
    const len = 38 + r() * 54;
    let d = `M${x.toFixed(1)} 0`;
    while (y < len) {
      y += 6 + r() * 8;
      x += (r() - 0.5) * 9;
      d += `L${x.toFixed(1)} ${y.toFixed(1)}`;
    }
    return { d, w: 0.5 + r() * 1.1, delay: 0.2 + r() * 0.9 };
  });
  return (
    <svg class="pv-veins" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
      {paths.map((p, i) => <path key={i} d={p.d} pathLength={1} style={{ strokeWidth: p.w, animationDelay: `${p.delay}s` }} vector-effect="non-scaling-stroke" />)}
    </svg>
  );
}

function Hud({ side, who, label, hp, tag }: { side: 'a' | 'b'; who: Combatant; label: string; hp: number; tag: string | null }) {
  const pct = Math.max(0, Math.min(100, (hp / who.max_hp) * 100));
  const low = pct < 30;
  return (
    <div class={`pv-hud pv-hud-${side}${low ? ' low' : ''}`} data-scope={who.faction === 'human' ? 'survey' : 'heat'}>
      <div class="pv-hud-top">
        <h2 class="display pv-name voice">{label}</h2>
        {tag && <span class="label-tape pv-tag">{tag}</span>}
        <span class="pv-lvl num">{say('Lv', 'lv')} {who.level}</span>
      </div>
      <div class="bar pv-bar" role="progressbar" aria-label={`${label} health`} aria-valuemin={0} aria-valuemax={who.max_hp} aria-valuenow={Math.round(hp)}>
        <i class="trail" style={{ width: `${pct}%` }} />
        <i class="fill" style={{ width: `${pct}%` }} />
      </div>
      <p class="pv-hp num">{Math.round(hp)}<small> / {who.max_hp}</small></p>
    </div>
  );
}

export interface Flash { n: number; crit: boolean; side: 'a' | 'b' }

/** Where the seam between the two halves sits in the stage, so tape and numbers stay on their own side of it. */
function useSeam(ref: { current: HTMLDivElement | null }) {
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => {
      const half = el.querySelector<HTMLElement>('.h-b');
      if (!half) return;
      el.style.setProperty('--seam', `${Math.round(half.getBoundingClientRect().bottom - el.getBoundingClientRect().top)}px`);
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
}

/**
 * The stage for a fight against a person. The opponent's lens comes in from the top and covers
 * their half, yours holds the rest; each side is a full-height silhouette wearing its gear.
 */
export function PvpArena({ battle, hpA, hpB, impact, floatsA, floatsB, over, ready, reveal, flash, slow, stageRef, onSkipIntro, children }: {
  battle: Battle; hpA: number; hpB: number;
  impact: Record<'a' | 'b', Impact | null>;
  floatsA: ComponentChildren; floatsB: ComponentChildren;
  over: boolean;
  /** The intro is done and blows are being traded. */
  ready: boolean;
  /** Foe items revealed so far (they appear one by one during the intro). */
  reveal: number;
  flash: Flash | null;
  /** Which side a crit or the final blow is slowing the view onto. */
  slow: 'a' | 'b' | null;
  stageRef: { current: HTMLDivElement | null };
  onSkipIntro: () => void;
  children: ComponentChildren;
}) {
  const mineScope = battle.a.faction === 'human' ? 'survey' : 'heat';
  const foeScope = battle.b.faction === 'human' ? 'survey' : 'heat';
  const stamp = stampOf(battle);
  useSeam(stageRef);
  const [entered, setEntered] = useState(false);
  useEffect(() => { const id = requestAnimationFrame(() => requestAnimationFrame(() => setEntered(true))); return () => cancelAnimationFrame(id); }, []);
  const edge = useMemo(() => ({ paper: tornEdge(battle.id + 'p', 0), under: tornEdge(battle.id + 'u', 2.2) }), [battle.id]);
  const foeTag = battle.b.stance ? stanceName(battle.b.stance, battle.b.faction) : null;
  const myTag = battle.a.stance ? stanceName(battle.a.stance, battle.a.faction) : null;
  const foeName = foeLabel(battle);
  const cls = ['arena', 'pvp-arena', entered ? 'on' : '', ready ? 'ready' : 'intro', stamp ? 'ghost' : '', over ? 'over' : '', slow ? `slow slow-${slow}` : '']
    .filter(Boolean).join(' ');
  return (
    <div class={cls} ref={stageRef} data-mine={mineScope} data-foe={foeScope} onClick={() => { if (!ready) onSkipIntro(); }}>
      <div class="pv-world pv-mine" data-scope={mineScope} aria-hidden="true" />
      <div class="pv-foe-sheet" data-scope={foeScope} aria-hidden="true">
        {foeScope === 'survey' ? (
          <>
            <div class="pv-foe-under" data-scope="survey" style={{ clipPath: edge.under }} />
            <div class="pv-world pv-foe pv-paper" data-scope="survey" style={{ clipPath: edge.paper }} />
          </>
        ) : (
          <div class="pv-world pv-foe pv-bleed" data-scope="heat"><Veins seed={battle.id} /></div>
        )}
      </div>
      <Hud side="b" who={battle.b} label={`${foeName}`} hp={hpB} tag={foeTag} />
      <div class="arena-half h-b">
        <Silhouette side="b" who={battle.b} hp={hpB} impact={impact.b} dying={over && hpB <= 0} shown={reveal} />
        {floatsB}
        {stamp && <div class="pv-stamp" aria-label={stamp}>{stamp}</div>}
      </div>
      <div class="arena-half h-a">
        <Silhouette side="a" who={battle.a} hp={hpA} impact={impact.a} dying={over && hpA <= 0} shown={9} />
        {floatsA}
      </div>
      <Hud side="a" who={battle.a} label={say('you', 'you')} hp={hpA} tag={myTag} />
      {!ready && (
        <div class="pv-intro-word" aria-hidden="true">
          <b class="display">{stamp ?? foeName}</b>
          <span class="voice">{stamp ? foeName : say('Contact', 'contact')} · {say('Level', 'level')} {battle.b.level}</span>
        </div>
      )}
      <div class="pv-vignette" aria-hidden="true" />
      {flash && <i key={flash.n} class={`pv-flash s-${flash.side === 'a' ? mineScope : foeScope}${flash.crit ? ' crit' : ''} to-${flash.side}`} aria-hidden="true" />}
      {children}
    </div>
  );
}
