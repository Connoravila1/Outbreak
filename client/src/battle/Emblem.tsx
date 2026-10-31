import type { Battle, Combatant } from '../api';
import { ARCH_ICON } from '../state/objects';
import { Icon, type IconName } from '../ui/Icon';

export type Side = 'a' | 'b';
/** One landed blow, replayed as a one-shot effect on the target's emblem. */
export interface Impact { n: number; crit: boolean }

export function emblemIcon(c: Combatant): IconName {
  switch (c.kind) {
    case 'enemy': return (c.archetype && ARCH_ICON[c.archetype]) || 'target-dummy';
    case 'boss': return 'skull-crack';
    case 'echo': case 'rogue': return 'ghost';
    default: return c.faction === 'zombie' ? 'fangs' : 'person';
  }
}

/** Small deterministic PRNG so a combatant's pencil circle looks the same all fight. */
function rng(seed: string) {
  let h = 2166136261;
  for (let i = 0; i < seed.length; i++) { h ^= seed.charCodeAt(i); h = Math.imul(h, 16777619); }
  return () => { h = Math.imul(h ^ (h >>> 15), 2246822507); h = Math.imul(h ^ (h >>> 13), 3266489909); h ^= h >>> 16; return (h >>> 0) / 4294967296; };
}

/** A rough, slightly open grease-pencil loop that overshoots where it started. */
function pencilCircle(seed: string, r0: number, turns = 1.12): string {
  const r = rng(seed);
  const n = 16;
  const start = r() * Math.PI * 2;
  const pts: [number, number][] = [];
  for (let i = 0; i <= n * turns; i++) {
    const a = start + (i / n) * Math.PI * 2;
    const rad = r0 + (i / n) * 2.4 + (r() - 0.5) * 5.5;
    pts.push([60 + Math.cos(a) * rad, 60 + Math.sin(a) * rad * 0.97]);
  }
  let d = `M${pts[0][0].toFixed(1)} ${pts[0][1].toFixed(1)}`;
  for (let i = 1; i < pts.length; i++) {
    const [px, py] = pts[i - 1];
    const [x, y] = pts[i];
    d += `Q${px.toFixed(1)} ${py.toFixed(1)} ${((px + x) / 2).toFixed(1)} ${((py + y) / 2).toFixed(1)}`;
  }
  return d;
}

/** Red pencil slashes across the target: Survey's impact flash. */
export function Scratches({ crit, n, style }: { crit: boolean; n: number; style?: Record<string, string> }) {
  const r = rng('scratch' + n);
  const small = !!style; // on a figure: modest scratches at the point of impact
  const count = small ? (crit ? 4 : 2) : crit ? 6 : 3;
  const lines = Array.from({ length: count }, (_, i) => {
    const flip = i % 2 ? -1 : 1;
    const cx = 60 + (r() - 0.5) * 30;
    const cy = 60 + (r() - 0.5) * 30;
    const len = small ? 16 + r() * 10 : 30 + r() * 18;
    const tilt = flip * (0.5 + r() * 0.5);
    return `M${(cx - len * tilt).toFixed(1)} ${(cy - len).toFixed(1)}L${(cx + len * tilt).toFixed(1)} ${(cy + len).toFixed(1)}`;
  });
  return (
    <svg class={'impact scratches' + (crit ? ' crit' : '')} viewBox="0 0 120 120" aria-hidden="true" style={style}>
      {lines.map((d, i) => <path key={i} d={d} pathLength={1} style={{ animationDelay: `${i * 35}ms` }} />)}
    </svg>
  );
}

export function Emblem({ side, who, label, hp, battle, heat, impact, dying }: {
  side: Side; who: Combatant; label: string; hp: number; battle: Battle; heat: boolean; impact: Impact | null; dying: boolean;
}) {
  const k = Math.max(0, Math.min(1, hp / who.max_hp));
  const seed = battle.id + side;
  return (
    <div class={`emb emb-${side}${dying ? ' dying' : ''}`} style={{ '--k': k }}>
      <div class="emb-body">
        {heat ? (
          <>
            <i class="b-out" /><i class="b-mid" /><i class="b-core" />
          </>
        ) : (
          <svg class="emb-ring" viewBox="0 0 120 120" aria-hidden="true">
            <path class="ring-2" d={pencilCircle(seed + 'x', 49, 1.05)} pathLength={1} />
            <path class="ring-1" d={pencilCircle(seed, 51)} pathLength={1} />
          </svg>
        )}
        <Icon name={emblemIcon(who)} size={64} class="emb-icon" />
        {!heat && dying && (
          <svg class="emb-x" viewBox="0 0 120 120" aria-hidden="true">
            <path d="M22 20L98 100" pathLength={1} /><path d="M98 22L24 98" pathLength={1} />
          </svg>
        )}
        {impact && (heat
          ? <i key={impact.n} class={'impact flare' + (impact.crit ? ' crit' : '')} />
          : <Scratches key={impact.n} n={impact.n} crit={impact.crit} />)}
      </div>
      <span class={'emb-label ' + (heat ? 'voice' : 'hand')}>{label}</span>
    </div>
  );
}
