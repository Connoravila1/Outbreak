import type { JSX } from 'preact';
import { type Half, type Paint, line, mix, symShape } from './paint';
import type { AvatarSpec } from './spec';

/* Layers of the portrait, drawn in a 100 x 120 box with the face centred on x = 50.
   Every layer takes the shared Ctx: Survey ignores heat values and uses true colours (ink on paper);
   Heat ignores colours and maps each layer's heat value through the thermal gradient. */

export interface Ctx {
  P: Paint;
  s: AvatarSpec;
  id: string;
  zombie: boolean;
  stage: number; // zombie decay, 0..4
  tier: number; // human gear tier (level / 5)
  /** Skin as drawn: tone and thermal value after decay. */
  skin: string;
  skinH: number;
  hair: string;
  hairH: number;
  g: Geo;
  nk: number; // neck half width
  sw: number; // shoulder half width
}

interface Geo { w: number; jw: number; cy: number; cw: number }
export const FACES: Geo[] = [
  { w: 19, jw: 15, cy: 83, cw: 5 }, // oval
  { w: 21.5, jw: 18, cy: 80.5, cw: 8.5 }, // round
  { w: 20, jw: 18, cy: 82, cw: 11.5 }, // square
  { w: 17, jw: 14, cy: 88, cw: 5.5 }, // long
  { w: 20.5, jw: 11, cy: 85, cw: 2.8 }, // heart
  { w: 16.5, jw: 12.5, cy: 85, cw: 4.2 }, // gaunt
];
export const BODIES = [{ nk: 6.8, sw: 30 }, { nk: 8.6, sw: 38 }, { nk: 10.6, sw: 46 }];

type El = JSX.Element;
const ex = (g: Geo) => g.w * 0.5;
const EY = 51;

function facePath(g: Geo): string {
  const { w, jw, cy, cw } = g;
  const outer: Half = {
    start: [0, 22],
    segs: [
      [w * 0.62, 22, w, 30, w, 46],
      [w, 57, jw + 1.5, 62, jw, 69],
      [jw - 1.2, 69 + (cy - 69) * 0.5, cw + (jw - cw) * 0.35, cy, cw, cy],
    ],
  };
  return symShape(outer, cw > 0.1 ? { start: [cw, cy], segs: [line([cw, cy], [0, cy])] } : null);
}

const rot = (x: number, y: number, a: number) => `rotate(${a} ${x} ${y})`;

/* ---------------------------------------------------------------- background */
export function Background({ c }: { c: Ctx }) {
  const { P, id, zombie } = c;
  if (P.heat) {
    return (
      <g>
        <rect x="-10" y="-10" width="120" height="140" fill={`url(#${id}-bg)`} />
        <rect x="-10" y="-10" width="120" height="140" fill={`url(#${id}-scan)`} />
      </g>
    );
  }
  return (
    <g>
      <rect x="-10" y="-10" width="120" height="140" fill={P.paper2} />
      <rect x="-10" y="-10" width="120" height="140" fill={`url(#${id}-hatch)`} />
      <circle cx="50" cy="52" r="37" fill={P.accent} fill-opacity={zombie ? 0.78 : 0.95} />
      <circle cx="50" cy="52" r="37" fill="none" stroke={P.ink} stroke-width={P.lw * 0.8} />
    </g>
  );
}

export function Defs({ c }: { c: Ctx }) {
  const { P, id } = c;
  const fp = facePath(c.g);
  const shiftedFace = <path d={fp} transform="translate(8 -2)" fill="#000" />;
  return (
    <defs>
      <clipPath id={`${id}-face`}><path d={fp} /></clipPath>
      <mask id={`${id}-crescent`}>
        <path d={fp} fill="#fff" />
        {shiftedFace}
      </mask>
      <clipPath id={`${id}-neck`}><rect x={50 - c.nk} y="68" width={c.nk * 2} height="34" /></clipPath>
      <filter id={`${id}-blur`} x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="2.2" /></filter>
      {P.heat ? (
        <>
          <radialGradient id={`${id}-bg`} cx="50%" cy="42%" r="62%">
            <stop offset="0" stop-color={P.fill(0.34)} />
            <stop offset="0.55" stop-color={P.fill(0.16)} />
            <stop offset="1" stop-color={P.fill(0.04)} />
          </radialGradient>
          <pattern id={`${id}-scan`} width="4" height="3" patternUnits="userSpaceOnUse"><rect width="4" height="0.8" fill="#000" fill-opacity="0.16" /></pattern>
          <radialGradient id={`${id}-skin`} cx="50%" cy="46%" r="60%">
            <stop offset="0" stop-color={P.fill(c.skinH + 0.1)} />
            <stop offset="0.6" stop-color={P.fill(c.skinH)} />
            <stop offset="1" stop-color={P.fill(c.skinH - 0.17)} />
          </radialGradient>
        </>
      ) : (
        <>
          <pattern id={`${id}-hatch`} width="4" height="4" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="4" height="0.7" fill={P.ink} fill-opacity="0.1" /></pattern>
          <pattern id={`${id}-shade`} width="2.2" height="2.2" patternUnits="userSpaceOnUse" patternTransform="rotate(-45)"><rect width="2.2" height={P.lw * 0.4} fill={P.ink} fill-opacity="0.55" /></pattern>
        </>
      )}
      <pattern id={`${id}-dots`} width="2.4" height="2.4" patternUnits="userSpaceOnUse"><circle cx="1" cy="1" r="0.38" fill={c.P.heat ? c.P.fill(c.hairH) : c.hair} /></pattern>
    </defs>
  );
}

/* ---------------------------------------------------------------- body */
function garmentPath(nk: number, sw: number): string {
  const outer: Half = {
    start: [0, 99],
    segs: [[nk * 0.6, 99.4, nk + 4, 95, nk + 4, 86], [nk + 12, 88, sw - 8, 90, sw, 98], [sw + 4, 104, sw + 5, 112, sw + 5, 120]],
  };
  return symShape(outer, { start: [sw + 5, 120], segs: [line([sw + 5, 120], [0, 120])] });
}

export function Body({ c }: { c: Ctx }) {
  const { P, nk, sw, zombie } = c;
  const gh = zombie ? 0.14 : 0.2;
  const gTint = zombie ? '#4A4F44' : c.s.body === 1 ? '#4B5240' : c.s.body === 2 ? '#3F4A55' : '#5A4A3C';
  const gp = garmentPath(nk, sw);
  return (
    <g>
      {/* neck */}
      <rect x={50 - nk} y="68" width={nk * 2} height="34" fill={P.heat ? P.fill(c.skinH - 0.06) : c.skin} />
      <g clip-path={`url(#${c.id}-neck)`}>
        <ellipse cx="50" cy="84" rx={nk + 3} ry="9" fill={P.heat ? P.fill(c.skinH - 0.26) : P.ink} fill-opacity={P.heat ? 0.9 : 0.35} />
      </g>
      <path d={`M${50 - nk} 68V96M${50 + nk} 68V96`} stroke={P.line(c.skinH)} stroke-width={P.lw * 0.8} fill="none" />
      {/* garment */}
      <path d={gp} fill={P.fill(gh, gTint, 0.88)} stroke={P.line(gh)} stroke-width={P.lw} stroke-linejoin="round" />
      <path d={`M${50 - nk - 4} 86C${50 - nk - 4} 95 ${50 - nk * 0.6} 99.4 50 99C${50 + nk * 0.6} 99.4 ${50 + nk + 4} 95 ${50 + nk + 4} 86`} fill="none" stroke={P.line(0.05)} stroke-width={P.lw * 1.9} stroke-linecap="round" />
      <path d={`M50 100V120${c.s.body === 2 ? '' : `M${50 - sw * 0.55} 112l7 8M${50 + sw * 0.55} 112l-7 8`}`} stroke={P.line(gh)} stroke-width={P.lw * 0.8} fill="none" />
      {c.s.body === 1 && <path d={`M${50 - nk - 1} 98l-3 12M${50 + nk + 1} 98l3 12`} stroke={P.heat ? P.fill(0.5) : P.paper} stroke-width={P.lw * 0.9} stroke-linecap="round" />}
    </g>
  );
}

/* ---------------------------------------------------------------- head */
export function Ears({ c }: { c: Ctx }) {
  const { P, g } = c;
  return (
    <g fill={P.heat ? P.fill(c.skinH - 0.04) : c.skin} stroke={P.line(c.skinH)} stroke-width={P.lw * 0.9}>
      <ellipse cx={50 - g.w - 0.6} cy="52" rx="3" ry="5" />
      <ellipse cx={50 + g.w + 0.6} cy="52" rx="3" ry="5" />
    </g>
  );
}

export function Face({ c }: { c: Ctx }) {
  const { P, id, g } = c;
  const fp = facePath(g);
  return (
    <g>
      <path d={fp} fill={P.heat ? `url(#${id}-skin)` : c.skin} />
      {/* shadow side: a crescent down the left */}
      <g mask={`url(#${id}-crescent)`}>
        {P.heat ? <rect width="100" height="100" fill={P.fill(c.skinH - 0.2)} fill-opacity="0.7" /> : <rect width="100" height="100" fill={`url(#${id}-shade)`} />}
      </g>
      {/* nose, cheek and brow modelling */}
      <path d={`M${49} 52C48.4 58 47.6 61 46 63.5Q50 66.2 54 63.5`} fill="none" stroke={P.line(c.skinH)} stroke-width={P.lw * 0.85} stroke-linecap="round" stroke-linejoin="round" opacity={P.heat ? 0.7 : 1} />
      {c.s.face === 5 && <path d={`M${50 - g.w * 0.62} 60Q${50 - g.w * 0.5} 68 ${50 - g.w * 0.35} 74M${50 + g.w * 0.62} 60Q${50 + g.w * 0.5} 68 ${50 + g.w * 0.35} 74`} fill="none" stroke={P.line(c.skinH)} stroke-width={P.lw * 0.8} opacity="0.55" stroke-linecap="round" />}
      <path d={fp} fill="none" stroke={P.line(c.skinH)} stroke-width={P.lw * 1.15} stroke-linejoin="round" />
    </g>
  );
}

function Eye({ c, sgn }: { c: Ctx; sgn: 1 | -1 }) {
  const { P, g, zombie, stage } = c;
  const x = 50 + sgn * ex(g);
  const glow = zombie && stage >= 4;
  const scl = zombie ? 0.4 : 0.9;
  return (
    <g transform={`translate(${x} ${EY})`}>
      {zombie && <ellipse cx="0" cy="4" rx="5.6" ry="2.6" fill={P.heat ? P.fill(c.skinH - 0.3) : P.ink} fill-opacity={P.heat ? 0.8 : 0.34} />}
      {glow ? (
        <>
          <circle r="7" fill={P.heat ? P.fill(0.92) : P.accent} opacity={P.heat ? 0.9 : 0.5} filter={`url(#${c.id}-blur)`} />
          <path d="M-5.4 0Q0 -4.4 5.4 0Q0 4 -5.4 0Z" fill={P.heat ? P.fill(1) : P.accent} stroke={P.line(0.8)} stroke-width={P.lw * 0.7} />
          {!P.heat && <path d="M0 -7.5V-5.5M5.5 -5.6l-1.4 1.6M-5.5 -5.6l1.4 1.6M0 7.5V5.5" stroke={P.ink} stroke-width={P.lw * 0.8} stroke-linecap="round" />}
        </>
      ) : (
        <>
          <path d="M-5.4 0Q0 -4.4 5.4 0Q0 3.8 -5.4 0Z" fill={P.fill(scl, zombie ? '#C8C9A8' : '#F4F1E6', 0.95)} />
          <circle cx="0" cy="-0.1" r={zombie ? 2.4 : 2.6} fill={P.fill(zombie ? 0.34 : 0.14, zombie ? '#7B8570' : '#2A241E', 0.95)} />
          <circle cx="0" cy="-0.1" r="1.1" fill={P.fill(0.05)} />
          <circle cx="0.9" cy="-1" r="0.55" fill={P.heat ? P.fill(0.95) : P.paper} />
        </>
      )}
      <path d="M-5.9 0.4Q0 -5 5.9 0.4" fill="none" stroke={P.line(c.skinH)} stroke-width={P.lw * 1.15} stroke-linecap="round" />
    </g>
  );
}

export function Features({ c }: { c: Ctx }) {
  const { P, g, zombie } = c;
  const browH = c.hairH * 0.8;
  const brow = (sgn: 1 | -1) => {
    const x = 50 + sgn * ex(g);
    const dy = zombie ? 0.8 : 0;
    return <path d={`M${x - sgn * 6} ${44.6 + dy}Q${x + sgn * 0.5} ${41.2 + dy} ${x + sgn * 6.4} ${43.2 + dy * 2}`} fill="none" stroke={P.heat ? P.fill(browH) : mix(c.hair, P.ink, 0.35)} stroke-width={P.lw * 1.9} stroke-linecap="round" />;
  };
  const open = zombie && c.stage >= 2;
  return (
    <g>
      <Eye c={c} sgn={-1} />
      <Eye c={c} sgn={1} />
      {brow(-1)}
      {brow(1)}
      {/* mouth */}
      {open ? (
        <g>
          <path d="M43 71.5Q50 70.5 57 71.5Q56 77 50 77.4Q44 77 43 71.5Z" fill={P.fill(0.04)} stroke={P.line(0.3)} stroke-width={P.lw * 0.9} />
          <path d="M44.5 72h11" stroke={P.heat ? P.fill(0.62) : P.paper} stroke-width="1.7" stroke-dasharray="1.5 0.5" />
        </g>
      ) : (
        <g>
          <path d="M43.5 72Q50 74.4 56.5 72" fill="none" stroke={P.line(c.skinH)} stroke-width={P.lw * 1.2} stroke-linecap="round" />
          <path d="M45.5 72.2Q50 76 54.5 72.2Q50 74 45.5 72.2Z" fill={P.fill(c.skinH - 0.1, mix(c.skin, '#9A4A44', 0.45), 0.9)} opacity="0.9" />
        </g>
      )}
    </g>
  );
}

export function Facial({ c }: { c: Ctx }) {
  const { P, g, id } = c;
  const f = c.s.facial;
  if (f === 0) return null;
  const col = P.heat ? P.fill(c.hairH) : c.hair;
  const stroke = P.heat ? P.fill(c.hairH - 0.1) : P.ink;
  const { w, jw, cy, cw } = g;
  if (f === 1) {
    return (
      <g clip-path={`url(#${id}-face)`} opacity={P.heat ? 0.55 : 0.9}>
        <path d={`M${50 - w} 58Q${50 - jw} 70 ${50 - cw} ${cy + 1}H${50 + cw}Q${50 + jw} 70 ${50 + w} 58L${50 + 9} 66Q50 62.5 ${50 - 9} 66Z`} fill={`url(#${id}-dots)`} />
      </g>
    );
  }
  const mous: Half = { start: [0, 66.8], segs: [[3, 65.4, 7, 66, 9.6, 70]] };
  const mousIn: Half = { start: [9.6, 70], segs: [[6.6, 68.2, 3, 69.6, 0, 68.6]] };
  if (f === 2) return <path d={symShape(mous, mousIn)} fill={col} stroke={stroke} stroke-width={P.lw * 0.7} stroke-linejoin="round" />;
  const beard: Half = {
    start: [0, cy + 2.5],
    segs: [[cw + 2, cy + 2.5, jw + 2, 76, jw + 1.5, 69], [jw + 1.5, 62, w + 0.6, 58, w + 0.2, 52]],
  };
  const beardIn: Half = { start: [w + 0.2, 52], segs: [[w - 2, 58, jw - 3, 62, 11, 66], [8.5, 67.4, 4, 66.4, 0, 66.6]] };
  return (
    <g>
      <path d={symShape(beard, beardIn)} fill={col} stroke={stroke} stroke-width={P.lw * 0.8} stroke-linejoin="round" />
      {c.zombie && c.stage >= 2 ? null : <path d="M44 72Q50 70.6 56 72" fill="none" stroke={P.heat ? P.fill(0.08) : P.paper} stroke-width={P.lw * 1.2} stroke-linecap="round" />}
    </g>
  );
}

export function Scar({ c }: { c: Ctx }) {
  const { P, g } = c;
  const k = c.s.scar;
  if (k === 0) return null;
  const sc = P.heat ? P.fill(c.skinH + 0.22) : mix(c.skin, '#8E3A36', 0.6);
  if (k === 1) {
    return (
      <g stroke={P.heat ? P.fill(c.skinH + 0.24) : P.ink} fill="none" stroke-linecap="round">
        <path d="M58 55L64 71" stroke-width={P.lw * 1.4} stroke={sc} />
        <path d="M58 55L64 71" stroke-width={P.lw * 0.7} />
        <path d="M56.6 59.4l4 -1.4M57.8 63l4.2 -1.2M59.4 67l3.8 -1" stroke-width={P.lw * 0.6} />
      </g>
    );
  }
  if (k === 2) {
    const x = 50 - ex(g);
    return (
      <g fill="none" stroke-linecap="round">
        <path d={`M${x + 1} 39.6L${x - 2.4} 49.4`} stroke={sc} stroke-width={P.lw * 1.7} />
        <path d={`M${x + 1} 39.6L${x - 2.4} 49.4`} stroke={P.heat ? P.fill(0.1) : P.ink} stroke-width={P.lw * 0.7} />
        <path d={`M${x - 1.6} 42l3 .6M${x - 2.6} 46l3 .5`} stroke={P.heat ? P.fill(0.1) : P.ink} stroke-width={P.lw * 0.6} />
      </g>
    );
  }
  return (
    <g>
      <path d="M62 49Q66.4 51 66 56.4Q64.6 61.4 60.2 60Q57 56.6 59 52.4Q60 50 62 49Z" fill={sc} opacity={P.heat ? 0.95 : 0.8} />
      <path d="M62.4 52Q64.6 54 63.2 57.4M60.6 54.4Q61.6 57 60.6 58" fill="none" stroke={P.heat ? P.fill(c.skinH - 0.2) : P.ink} stroke-width={P.lw * 0.6} opacity="0.7" />
    </g>
  );
}

/* ---------------------------------------------------------------- hair */
function cap(hw: number, top: number, sideY: number, hairY: number, drop = 0): { outer: Half; inner: Half } {
  return {
    outer: { start: [0, top], segs: [[hw * 0.55, top, hw + 1.2, top + 8, hw + 0.8, 33], [hw + 0.5, 39, hw + drop * 0.3, sideY - 5 + drop, hw + drop * 0.4, sideY + drop]] },
    inner: { start: [hw + drop * 0.4, sideY + drop], segs: [[hw - 1.5 + drop * 0.2, sideY - 5, hw - 3, hairY + 6, hw - 7, hairY + 2], [hw * 0.5, hairY - 2.4, 7, hairY - 0.4, 0, hairY]] },
  };
}

function strands(c: Ctx, d: string, o = 0.45): El {
  const { P } = c;
  return <path d={d} fill="none" stroke={P.heat ? P.fill(c.hairH + 0.16) : P.ink} stroke-width={P.lw * 0.6} opacity={o} stroke-linecap="round" />;
}

/** Hair that sits behind the head and shoulders. */
export function HairBack({ c }: { c: Ctx }) {
  const { P, g, s } = c;
  const hw = g.w + 1.5;
  const fill = P.heat ? P.fill(c.hairH) : c.hair;
  const st = { fill, stroke: P.line(c.hairH), 'stroke-width': P.lw, 'stroke-linejoin': 'round' as const };
  if (s.hair === 5) {
    const o: Half = { start: [0, 13], segs: [[hw * 0.7, 13, hw + 4, 20, hw + 4, 40], [hw + 4, 56, hw + 2, 66, hw + 1, 74]] };
    return <path d={symShape(o, { start: [hw + 1, 74], segs: [line([hw + 1, 74], [0, 74])] })} {...st} />;
  }
  if (s.hair === 6) {
    const o: Half = { start: [0, 13], segs: [[hw * 0.7, 13, hw + 6, 20, hw + 6, 44], [hw + 6, 70, hw + 9, 92, hw + 12, 112]] };
    return <path d={symShape(o, { start: [hw + 12, 112], segs: [line([hw + 12, 112], [0, 112])] })} {...st} />;
  }
  if (s.hair === 7) {
    const r = hw + 11;
    const o: Half = { start: [0, 2.5], segs: [[r * 0.5, 1, r * 0.95, 6, r * 0.96, 22], [r + 3, 30, r + 1, 48, hw + 3, 55]] };
    return <path d={symShape(o, { start: [hw + 3, 55], segs: [line([hw + 3, 55], [0, 50])] })} {...st} />;
  }
  if (s.hair === 9) {
    return (
      <g>
        <circle cx="50" cy="13" r="7.4" {...st} />
        {strands(c, 'M45 8Q50 5 55 8M44.5 12Q50 9 55.5 12', 0.5)}
      </g>
    );
  }
  return null;
}

/** Hair that sits over the forehead and face edges. */
export function HairFront({ c }: { c: Ctx }) {
  const { P, g, s } = c;
  const hw = g.w + 1.5;
  const fill = P.heat ? P.fill(c.hairH) : c.hair;
  const st = { fill, stroke: P.line(c.hairH), 'stroke-width': P.lw, 'stroke-linejoin': 'round' as const };
  const faint = { fill, stroke: 'none', 'fill-opacity': 0.8 };
  const mk = (top: number, sideY: number, hairY: number, drop = 0) => { const k = cap(hw, top, sideY, hairY, drop); return symShape(k.outer, k.inner); };
  switch (s.hair) {
    case 0: return <path d={mk(21.6, 41, 32)} {...faint} fill-opacity={P.heat ? 0.35 : 0.22} />;
    case 1: return <g><path d={mk(19.4, 43, 30.5)} {...faint} fill-opacity={P.heat ? 0.8 : 0.62} /><g clip-path={`url(#${c.id}-face)`} opacity="0.5"><path d={mk(19.4, 43, 30.5)} fill={`url(#${c.id}-dots)`} /></g></g>;
    case 2: return <g><path d={mk(14.4, 46, 31.4)} {...st} />{strands(c, 'M33 24Q38 19 44 17M50 15.6V22M58 17.6Q62 19.6 66 25')}</g>;
    case 3: return (
      <g>
        <path d={mk(13.6, 46, 30)} {...st} />
        <path d={`M40 15C48 19 58 20 ${50 + hw - 0.6} 29C${50 + hw - 0.2} 36 ${50 + hw - 1.4} 40 ${50 + hw - 1.4} 44C${50 + hw - 4} 38 62 35 51 33C46 32 42 33 38 34C38 27 38.6 20 40 15Z`} {...st} />
        {strands(c, 'M42 19C50 23 58 25 64 31M41 24C47 27 55 29 61 34M38 18V26')}
      </g>
    );
    case 4: return <g><path d={mk(12.4, 41, 27)} {...st} />{strands(c, 'M36 27Q50 14 64 27M38 32Q50 20 62 32M32 38Q38 24 46 15M68 38Q62 24 54 15')}</g>;
    case 5: return (
      <g>
        <path d={mk(13.6, 50, 29.6)} {...st} />
        <path d={`M${50 - hw} 50C${50 - hw + 4} 38 ${50 - 4} 32 ${50 + hw * 0.5} 30`} fill="none" stroke={P.line(c.hairH)} stroke-width={P.lw * 0.7} />
        {strands(c, 'M34 30Q41 24 48 22')}
      </g>
    );
    case 6: return (
      <g>
        <path d={mk(13.6, 46, 29.4)} {...st} />
        <path d={`M${50 - hw + 0.6} 40C${50 - hw - 2} 62 ${50 - hw - 4} 82 ${50 - hw - 8} 100L${50 - hw + 3} 102C${50 - hw + 1} 84 ${50 - hw + 2} 62 ${50 - hw + 3} 46Z`} {...st} />
        <path d={`M${50 + hw - 0.6} 40C${50 + hw + 2} 62 ${50 + hw + 4} 82 ${50 + hw + 8} 100L${50 + hw - 3} 102C${50 + hw - 1} 84 ${50 + hw - 2} 62 ${50 + hw - 3} 46Z`} {...st} />
        <path d="M50 14.6V29.4" stroke={P.line(c.hairH)} stroke-width={P.lw * 0.7} />
        {strands(c, 'M36 28Q34 40 33 52M64 28Q66 40 67 52')}
      </g>
    );
    case 7: return <path d={mk(6.5, 42, 27.5)} {...st} />;
    case 8: {
      const crest = `M45.4 31L43.8 17.6L47 13L47.2 4.5L50 9L52.8 3.6L53 13L56.2 16.8L54.6 31Z`;
      return (
        <g>
          <path d={mk(20, 43, 30)} {...faint} fill-opacity={P.heat ? 0.4 : 0.3} />
          <path d={crest} {...st} />
          {strands(c, 'M48 29V10M52 29V9M50 28V14', 0.55)}
        </g>
      );
    }
    default: return <g><path d={mk(14.4, 46, 31.4)} {...st} />{strands(c, 'M36 24Q43 19 48 17M52 17.4Q58 19 64 24')}</g>;
  }
}

/* ---------------------------------------------------------------- faction: human */
export function HumanFace({ c }: { c: Ctx }) {
  const { P, tier } = c;
  const dirt = Math.min(4, 1 + Math.floor(tier / 2));
  const smudge = P.heat ? P.fill(c.skinH - 0.28) : P.ink;
  const op = P.heat ? 0.35 : 0.12;
  const sm: [number, number, number, number, number][] = [[41, 63, 5, 2.2, -20], [60, 41.6, 4.4, 1.8, 16], [53, 77, 4, 1.7, 8], [36.5, 49.6, 3.4, 1.5, -28], [63.5, 66, 3.6, 1.6, 30], [45, 30, 3.8, 1.4, 4]];
  return (
    <g clip-path={`url(#${c.id}-face)`}>
      {sm.slice(0, dirt + 2).map(([x, y, rx, ry, a], i) => <ellipse key={i} cx={x} cy={y} rx={rx} ry={ry} transform={rot(x, y, a)} fill={smudge} opacity={op * (1 + (i % 3) * 0.5)} />)}
      {/* cheek bandage */}
      {tier >= 1 && (
        <g transform={rot(40, 61, -24)}>
          <rect x="33.4" y="57.6" width="13" height="7.4" rx="1.6" fill={P.heat ? P.fill(c.skinH - 0.1) : P.paper} stroke={P.heat ? P.fill(c.skinH - 0.3) : P.ink} stroke-width={P.lw * 0.9} />
          <path d="M37 57.8V65M43 57.8V65" stroke={P.heat ? P.fill(c.skinH - 0.24) : P.ink} stroke-width={P.lw * 0.5} opacity="0.55" />
          <circle cx="42.4" cy="61.6" r="1.5" fill={P.heat ? P.fill(c.skinH + 0.2) : P.ink} opacity={P.heat ? 0.9 : 0.4} />
        </g>
      )}
      {/* brow wrap */}
      {tier >= 6 && (
        <g transform={rot(60, 38, 14)}>
          <rect x="53" y="35" width="14" height="5.4" rx="1.4" fill={P.heat ? P.fill(c.skinH - 0.1) : P.paper} stroke={P.heat ? P.fill(c.skinH - 0.3) : P.ink} stroke-width={P.lw * 0.9} />
          <path d="M57.4 35.2V40.2M62.6 35.2V40.2" stroke={P.heat ? P.fill(c.skinH - 0.24) : P.ink} stroke-width={P.lw * 0.5} opacity="0.55" />
        </g>
      )}
    </g>
  );
}

/** Gear worn on the neck and shoulders (drawn over the garment). */
export function HumanGearBody({ c }: { c: Ctx }) {
  const { P, tier, nk, sw } = c;
  const acc = P.heat ? P.fill(0.72) : P.accent;
  const dark = P.heat ? P.fill(0.22) : P.ink;
  return (
    <g>
      {tier >= 2 && (
        <g>
          <path d={symShape({ start: [0, 103], segs: [[nk * 0.5, 100.4, nk + 3.6, 94, nk + 4.4, 87]] }, { start: [nk + 4.4, 87], segs: [[nk + 1, 91, 4, 90.6, 0, 91]] })} fill={acc} stroke={P.heat ? P.fill(0.4) : P.ink} stroke-width={P.lw} stroke-linejoin="round" />
          <g fill={dark} opacity={P.heat ? 0.5 : 0.8}><circle cx="44.6" cy="96" r="0.9" /><circle cx="55.4" cy="96" r="0.9" /><circle cx="50" cy="98.6" r="0.9" /><circle cx="48" cy="93.2" r="0.8" /><circle cx="52" cy="93.2" r="0.8" /></g>
          <circle cx={50 + nk + 3.4} cy="91.4" r="2" fill={acc} stroke={P.heat ? P.fill(0.4) : P.ink} stroke-width={P.lw * 0.8} />
        </g>
      )}
      {tier >= 4 && (
        <g>
          <path d={`M${50 - nk - 3} 88C${50 - nk - 3} 100 ${50 - 8} 106 ${50 - 7} 108M${50 + nk + 3} 88C${50 + nk + 3} 100 ${50 + 8} 106 ${50 + 7} 108`} fill="none" stroke={dark} stroke-width={P.lw * 1.3} />
          <path d="M39.4 107C39 114 44 119.6 50 119.6C56 119.6 61 114 60.6 107C58 105 42 105 39.4 107Z" fill={P.heat ? P.fill(0.26) : P.ink} stroke={P.line(0.2)} stroke-width={P.lw * 0.8} />
          <circle cx="45" cy="110.4" r="3.2" fill={P.heat ? P.fill(0.5) : P.paper} stroke={P.heat ? P.fill(0.12) : P.ink} stroke-width={P.lw * 0.8} />
          <circle cx="55" cy="110.4" r="3.2" fill={P.heat ? P.fill(0.5) : P.paper} stroke={P.heat ? P.fill(0.12) : P.ink} stroke-width={P.lw * 0.8} />
          <circle cx="50" cy="117" r="3.2" fill={P.heat ? P.fill(0.34) : P.paper2} stroke={P.heat ? P.fill(0.12) : P.ink} stroke-width={P.lw * 0.8} />
        </g>
      )}
      {tier >= 5 && (
        <g>
          <path d={`M${50 + sw - 9} 94C${50 + sw - 4} 90 ${50 + sw + 3} 92 ${50 + sw + 6} 98L${50 + sw + 7} 108C${50 + sw + 1} 106 ${50 + sw - 5} 104 ${50 + sw - 8} 100Z`} fill={P.heat ? P.fill(0.34) : P.paper2} stroke={P.line(0.3)} stroke-width={P.lw} stroke-linejoin="round" />
          <path d={`M${50 + sw - 3} 94.6L${50 + sw + 3} 105.4M${50 + sw + 1} 93.8L${50 + sw + 6.4} 103.4`} stroke={acc} stroke-width={P.lw * 1.6} />
          <circle cx={50 + sw - 6} cy="99" r="1" fill={dark} />
        </g>
      )}
    </g>
  );
}

/** Headgear (drawn over the hair). */
export function HumanGearHead({ c }: { c: Ctx }) {
  const { P, tier, g } = c;
  if (tier < 3) return null;
  const hw = g.w + 1.2;
  const dark = P.heat ? P.fill(0.18) : P.ink;
  return (
    <g>
      <path d={`M${50 - hw} 40.4Q50 23.6 ${50 + hw} 40.4`} fill="none" stroke={dark} stroke-width="3.2" stroke-linecap="round" />
      <path d={`M${50 - hw} 40.4Q50 23.6 ${50 + hw} 40.4`} fill="none" stroke={P.heat ? P.fill(0.34) : P.paper2} stroke-width="0.7" stroke-dasharray="2 2" />
      {P.heat && <circle cx="50" cy="29.2" r="9" fill={P.fill(1)} opacity="0.8" filter={`url(#${c.id}-blur)`} />}
      <rect x="44.4" y="24.2" width="11.2" height="9" rx="2.4" fill={dark} stroke={P.heat ? P.fill(0.4) : P.ink} stroke-width={P.lw * 0.8} />
      <circle cx="50" cy="28.8" r="3.1" fill={P.heat ? P.fill(1) : P.accent} stroke={P.heat ? P.fill(0.7) : P.ink} stroke-width={P.lw * 0.7} />
    </g>
  );
}

/* ---------------------------------------------------------------- faction: zombie */
const TEAR = 'M57 55.4L61.6 53L63.6 57L67 56.4L66.4 61L69.4 63.6L65.2 65.4L66 69.6L61.4 67.6L59.4 71L57.4 66.4L53.6 66.8L56 62.6L53.8 59.4L57.6 59.6Z';

export function ZombieFace({ c }: { c: Ctx }) {
  const { P, stage } = c;
  const vein = P.heat ? P.fill(0.2) : P.accent;
  const muscle = P.heat ? P.fill(0.66) : mix(P.paper, P.accent, 0.62);
  const deep = P.heat ? P.fill(0.28) : P.ink;
  const bone = P.heat ? P.fill(0.5) : P.paper;
  const boneLine = P.heat ? P.fill(0.12) : P.ink;
  return (
    <g>
      {/* pallor: cold blotches */}
      <g clip-path={`url(#${c.id}-face)`}>
        <ellipse cx="50" cy="38" rx="13" ry="6" fill={P.heat ? P.fill(c.skinH - 0.14) : P.paper} opacity={P.heat ? 0.4 : 0.22} />
        <ellipse cx="40" cy="66" rx="6" ry="3" fill={deep} opacity={P.heat ? 0.35 : 0.1} />
        {stage >= 1 && (
          <g fill="none" stroke={vein} stroke-width={P.lw * 0.7} stroke-linecap="round" stroke-linejoin="round" opacity={P.heat ? 0.9 : 0.85}>
            <path d="M43.4 53.4C41 56 40 59.6 37.6 62M40.6 56.6L36.4 57.4M41.6 59L40.6 63.6" />
            <path d="M57.6 52.4C60 55 61.6 57.6 63.4 62M60.4 56L65 55.6M44 46.6C41 43.6 38.6 41.4 36.6 36.4M38.8 42L34.4 41M62 44.4C64 41 65.4 38 66.6 34M49.6 33C50.4 30 51 28 50.6 25.6" />
          </g>
        )}
        {stage >= 2 && (
          <g>
            <path d={TEAR} fill={muscle} stroke={P.heat ? P.fill(0.4) : P.ink} stroke-width={P.lw} stroke-linejoin="round" />
            <path d="M58.6 58.4L63.4 60.4M58 63.4L62.6 63.8" stroke={deep} stroke-width={P.lw * 0.6} opacity="0.7" fill="none" />
            <path d="M40 31.4L43.6 33.6L41.6 35.6L45 37L40.6 37.4L38.8 34.6Z" fill={muscle} stroke={P.heat ? P.fill(0.4) : P.ink} stroke-width={P.lw * 0.9} stroke-linejoin="round" />
          </g>
        )}
        {stage >= 3 && (
          <g>
            <path d="M26 57L38 59.6L41 64L45 62.6L46.6 67.6L43.4 70.6L47 76L45.6 80.4L47.4 86L26 94Z" fill={muscle} stroke={P.heat ? P.fill(0.4) : P.ink} stroke-width={P.lw} stroke-linejoin="round" />
            <path d="M26 65L36.6 67.4L40 70.4L44 69.4L44.8 72L42 75L45 79L43 83L44.2 88L26 94Z" fill={bone} stroke={boneLine} stroke-width={P.lw * 0.9} stroke-linejoin="round" />
            <path d="M31 74L38 77M30 80L37 82.6" stroke={boneLine} stroke-width={P.lw * 0.5} opacity="0.6" fill="none" />
            <g fill={P.heat ? P.fill(0.72) : P.paper} stroke={boneLine} stroke-width={P.lw * 0.6} stroke-linejoin="round">
              <rect x="38" y="71" width="2.6" height="4.6" rx="0.8" /><rect x="40.8" y="71" width="2.6" height="4.6" rx="0.8" /><rect x="39" y="77.4" width="2.6" height="4.4" rx="0.8" /><rect x="41.8" y="77.4" width="2.6" height="4.4" rx="0.8" />
            </g>
          </g>
        )}
      </g>
      {stage >= 1 && (
        <path d="M44 82C44 86 43.4 90 42 93M56.4 82C56.4 86 57.4 90 59 94M50.4 83V90" fill="none" stroke={vein} stroke-width={P.lw * 0.7} stroke-linecap="round" opacity="0.85" />
      )}
    </g>
  );
}

/** Torn garment slits for the infected. */
export function ZombieGarment({ c }: { c: Ctx }) {
  const { P, stage, sw } = c;
  if (stage < 2) return null;
  const sk = P.heat ? P.fill(c.skinH - 0.1) : c.skin;
  return (
    <g stroke={P.line(0.1)} stroke-width={P.lw * 0.8} stroke-linejoin="round">
      <path d={`M${50 - sw * 0.5} 100L${50 - sw * 0.5 + 6} 103L${50 - sw * 0.5 + 3} 106L${50 - sw * 0.5 + 9} 109L${50 - sw * 0.5 - 2} 108Z`} fill={sk} />
      <path d={`M${50 + sw * 0.62} 108L${50 + sw * 0.62 - 5} 112L${50 + sw * 0.62 - 1} 114L${50 + sw * 0.62 - 6} 118L${50 + sw * 0.62 + 4} 114Z`} fill={sk} />
    </g>
  );
}
