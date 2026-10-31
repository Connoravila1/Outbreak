import type { Combatant, GearDetail, Slot } from '../api';
import { Scratches, type Impact } from './Emblem';

/**
 * A full-height anonymous figure: a survivor with a pack, or a hunched infected. It is the same
 * for every player of that faction; only the worn gear differs, drawn by slot and tinted by rarity.
 * Nothing here comes from a person's avatar or callsign.
 */

/** A body part: a filled shape (no `w`) or a stroked limb (`w` = stroke width). */
interface Part { d: string; w?: number }

const ell = (cx: number, cy: number, rx: number, ry: number) =>
  `M${cx - rx} ${cy}a${rx} ${ry} 0 1 0 ${2 * rx} 0a${rx} ${ry} 0 1 0 ${-2 * rx} 0`;

const HUMAN: Part[] = [
  { d: ell(104, 50, 19, 22) },
  { d: 'M104 64L104 86', w: 16 },
  { d: 'M58 90Q104 74 150 92L138 214Q104 226 70 214Z' },
  { d: 'M46 92Q32 94 32 112L32 194Q32 208 48 208L74 208L74 96Z' },
  { d: 'M30 82H80Q86 82 86 92V100H26V92Q26 82 30 82Z' },
  { d: 'M66 100Q48 140 56 172L62 208', w: 19 },
  { d: 'M146 100Q168 130 154 160L150 176', w: 19 },
  { d: ell(150, 180, 9, 9) },
  { d: 'M88 214L82 306L72 392', w: 27 },
  { d: 'M120 214L128 306L138 392', w: 27 },
  { d: ell(68, 402, 17, 8) },
  { d: ell(142, 402, 17, 8) },
];

const ZOMBIE: Part[] = [
  { d: ell(60, 118, 21, 25) },
  { d: 'M44 134L54 158L74 140Z' },
  { d: 'M70 132L92 146', w: 22 },
  { d: 'M40 138Q92 86 150 126L134 242Q106 258 78 244Z' },
  { d: 'M56 146Q22 200 36 268L36 330', w: 19 },
  { d: 'M36 330L26 354M36 330L38 358M36 330L48 354', w: 5 },
  { d: 'M140 134Q176 196 160 268L170 330', w: 19 },
  { d: 'M170 330L162 356M170 330L174 360M170 330L184 352', w: 5 },
  { d: 'M96 240Q76 300 90 340L80 400', w: 27 },
  { d: 'M122 238Q148 300 132 340L140 398', w: 27 },
  { d: ell(76, 408, 16, 7) },
  { d: ell(144, 406, 16, 7) },
  { d: 'M82 236L74 296L90 266L98 308L108 246Z' },
  { d: 'M112 240L120 300L130 262L134 232Z' },
];

/** Fine lines drawn on the body in the lens's paper/void tone (straps, belt, ribs). */
const HUMAN_DETAIL = 'M74 102L84 176M74 98L98 112M76 202H134M60 100L50 192';
const ZOMBIE_DETAIL = 'M70 150Q96 140 124 152M72 176Q98 168 124 180M76 202Q98 196 118 206M60 100Q40 98 34 110';

function Parts({ parts, pad }: { parts: Part[]; pad: number }) {
  return (
    <>
      {parts.map((p, i) => p.w
        ? <path key={i} class="limb" d={p.d} fill="none" stroke-width={p.w + pad * 2} stroke-linecap="round" stroke-linejoin="round" />
        : <path key={i} d={p.d} stroke-width={pad * 2} stroke-linejoin="round" />)}
    </>
  );
}

/** Worn gear as plain shapes, by slot, for each body. */
function Gear({ faction, item }: { faction: Combatant['faction']; item: GearDetail }) {
  const cls = `g g-${item.slot} g-${item.rarity}${item.unique ? ' g-unique' : ''}`;
  const spark = item.unique ? <Spark slot={item.slot} faction={faction} /> : null;
  if (faction === 'human') {
    switch (item.slot) {
      case 'weapon': return (
        <g class={cls}>
          <path class="g-line" d="M150 182L188 60" stroke-width="10" stroke-linecap="round" fill="none" />
          <path class="g-edge" d="M150 182L158 156" stroke-width="12" stroke-linecap="round" fill="none" />
          {spark}
        </g>
      );
      case 'armor': return (
        <g class={cls}>
          <path d="M78 94Q104 84 134 96L130 168Q104 178 80 168Z" />
          <circle cx="72" cy="98" r="12" /><circle cx="140" cy="100" r="12" />
          <path class="g-etch" d="M104 90L104 172" stroke-width="2.5" fill="none" />
          {spark}
        </g>
      );
      default: return (
        <g class={cls}>
          <path d="M120 200h14v32h-14z" /><path d="M116 198h22l-4 -12h-14z" />
          <path class="g-beam" d="M126 186L160 120L196 150Z" />
          {spark}
        </g>
      );
    }
  }
  switch (item.slot) {
    case 'weapon': return (
      <g class={cls}>
        <path class="g-line" d="M170 334Q206 292 184 218" stroke-width="10" stroke-linecap="round" fill="none" />
        <path class="g-line" d="M184 218L174 238M184 218L196 236" stroke-width="5" stroke-linecap="round" fill="none" />
        {spark}
      </g>
    );
    case 'armor': return (
      <g class={cls}>
        <path d="M52 126Q96 94 144 128Q120 118 98 120Q74 118 52 126Z" />
        <path d={ell(96, 172, 30, 12)} /><path d={ell(98, 206, 24, 10)} />
        {spark}
      </g>
    );
    default: return (
      <g class={cls}>
        <path d={ell(118, 252, 14, 16)} />
        <path class="g-etch" d="M118 236L124 218" stroke-width="5" stroke-linecap="round" fill="none" />
        <path class="g-beam" d={ell(118, 252, 28, 30)} />
        {spark}
      </g>
    );
  }
}

/** A unique item: a four-point glint where it sits. */
function Spark({ slot, faction }: { slot: Slot; faction: Combatant['faction'] }) {
  const at: Record<Slot, [number, number]> = faction === 'human'
    ? { weapon: [184, 70], armor: [106, 128], utility: [127, 214] }
    : { weapon: [186, 226], armor: [96, 120], utility: [126, 242] };
  const [x, y] = at[slot];
  return <path class="g-spark" d={`M${x} ${y - 14}L${x + 3} ${y - 3}L${x + 14} ${y}L${x + 3} ${y + 3}L${x} ${y + 14}L${x - 3} ${y + 3}L${x - 14} ${y}L${x - 3} ${y - 3}Z`} />;
}


export function Silhouette({ side, who, hp, impact, dying, heat, shown }: {
  side: 'a' | 'b'; who: Combatant; hp: number; impact: Impact | null; dying: boolean;
  /** Draw the impact as a heat flare instead of pencil scratches (the viewer's lens). */
  heat: boolean;
  /** How many of the worn items have been revealed (the intro adds them one by one). */
  shown: number;
}) {
  const k = Math.max(0, Math.min(1, hp / who.max_hp));
  const scope = who.faction === 'human' ? 'survey' : 'heat';
  const parts = who.faction === 'human' ? HUMAN : ZOMBIE;
  const detail = who.faction === 'human' ? HUMAN_DETAIL : ZOMBIE_DETAIL;
  const gear = (who.gear_detail ?? []).slice(0, Math.max(0, shown));
  const style: Record<string, string | number> = { '--k': k };
  return (
    <div class={`emb sil emb-${side}${dying ? ' dying' : ''}`} data-scope={scope} style={style}>
      <div class="emb-body">
        <div class="sil-bloom" aria-hidden="true" />
        <svg class="sil-svg" viewBox="0 0 200 420" aria-hidden="true" preserveAspectRatio="xMidYMax meet">
          <g class="sil-rim"><Parts parts={parts} pad={4} /></g>
          <g class="sil-fill"><Parts parts={parts} pad={0} /></g>
          <path class="sil-detail" d={detail} fill="none" stroke-width="2.5" stroke-linecap="round" />
          {gear.map((g) => <Gear key={g.slot} faction={who.faction} item={g} />)}
        </svg>
        {impact && (heat
          ? <i key={impact.n} class={'impact flare' + (impact.crit ? ' crit' : '')} />
          : <Scratches key={impact.n} n={impact.n} crit={impact.crit} />)}
      </div>
    </div>
  );
}
