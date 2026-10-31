import type { Ctx } from './parts';
import { line, mix, symShape } from './paint';

/* Faction looks (spec.look): treatments a player opens with titles and picks in the avatar editor.
   Humans harden (scarf, riot visor, field paint, kit, command coat, sash); the infected advance
   (veins, torn skin, bare bone, fungal bloom, burning eyes, spore crown). The first three infected
   looks and the Hardened kit reuse the level-driven pieces in parts.tsx through the tiers and stage
   Avatar.tsx picks; everything here is what those pieces lack. Same rules as parts.tsx: Survey is ink on
   paper with true colours, Heat maps each layer's thermal value through the gradient. */

const star = (cx: number, cy: number, r: number) => {
  const p: string[] = [];
  for (let i = 0; i < 10; i++) {
    const a = (-90 + i * 36) * (Math.PI / 180), rr = i % 2 ? r * 0.42 : r;
    p.push(`${i ? 'L' : 'M'}${(cx + rr * Math.cos(a)).toFixed(1)} ${(cy + rr * Math.sin(a)).toFixed(1)}`);
  }
  return p.join('') + 'Z';
};

/* ---------------------------------------------------------------- human: body */
export function HumanSkinBody({ c }: { c: Ctx }) {
  if (c.zombie) return null;
  if (c.look === 1) return <Scarf c={c} />;
  if (c.look === 5) return <CommandCoat c={c} />;
  if (c.look === 6) return <Sash c={c} />;
  return null;
}

/** A chunky knitted scarf wound twice round the neck with the tail hanging over the chest. */
function Scarf({ c }: { c: Ctx }) {
  const { P, nk } = c;
  const w = nk + 6.5;
  const wool = P.fill(0.5, '#B5603A', 0.85);
  const band = P.fill(0.28, '#2C3236', 0.9);
  const edge = P.line(0.3);
  const lw = P.lw;
  return (
    <g stroke-linejoin="round" stroke-linecap="round">
      {/* the tail, under the wraps */}
      <path d={`M${50 + nk - 1} 97L${50 + nk + 10} 99.6L${50 + nk + 12} 117L${50 + nk + 0.5} 115.6Z`} fill={wool} stroke={edge} stroke-width={lw} />
      <path d={`M${50 + nk + 0.4} 108.2L${50 + nk + 11.4} 110.4M${50 + nk + 0.6} 112.2L${50 + nk + 11.8} 114.2`} stroke={band} stroke-width={lw * 2} fill="none" />
      <path d={`M${50 + nk + 1.5} 115.8l-0.6 3.4M${50 + nk + 4.5} 116.4l-0.2 3.4M${50 + nk + 7.5} 116.8l0.2 3.4M${50 + nk + 10.5} 117.2l0.6 3.2`} stroke={edge} stroke-width={lw * 0.8} fill="none" />
      {/* two wraps */}
      <path d={`M${50 - w} 89Q50 82 ${50 + w} 89L${50 + w + 1.4} 98.4Q50 106.4 ${50 - w - 1.4} 98.4Z`} fill={wool} stroke={edge} stroke-width={lw * 1.1} />
      <path d={`M${50 - w + 0.6} 93.6Q50 98.6 ${50 + w - 0.6} 93.6`} fill="none" stroke={band} stroke-width={lw * 2.1} />
      <path d={`M${50 - w - 0.4} 98.8Q50 106.8 ${50 + w + 0.4} 98.8`} fill="none" stroke={edge} stroke-width={lw * 0.9} />
      {/* knit ribs */}
      <path d={`M${50 - w + 4} 91.2l1.2 4.6M${50 - w + 9} 92.6l1 4.6M${50 - w + 14} 93.4l.8 4.6M${50 + w - 4} 91.2l-1.2 4.6M${50 + w - 9} 92.6l-1 4.6M${50 + w - 14} 93.4l-.8 4.6`} stroke={edge} stroke-width={lw * 0.55} opacity="0.55" fill="none" />
    </g>
  );
}

/** A long officer's coat: stiff collar, lapels over a shirt, a double row of buttons, epaulettes. */
function CommandCoat({ c }: { c: Ctx }) {
  const { P, nk, sw } = c;
  const cloth = P.fill(0.16, '#33403A', 0.92);
  const trim = P.heat ? P.fill(0.78) : P.accent;
  const shirt = P.heat ? P.fill(0.5) : P.paper;
  const edge = P.line(0.2);
  const lw = P.lw;
  const ep = (sgn: 1 | -1) => {
    const x = 50 + sgn * (sw - 10), y = 93;
    return (
      <g key={sgn} transform={`rotate(${sgn * 16} ${x} ${y})`}>
        <rect x={x - 6.5} y={y - 2.4} width="13" height="5.2" rx="1" fill={cloth} stroke={edge} stroke-width={lw} />
        <rect x={x - 5.6} y={y - 1.4} width="11.2" height="3.2" fill={trim} />
        <path d={`M${x - 5.6} ${y + 2.8}v2.6M${x - 3.2} ${y + 2.8}v3M${x - 0.8} ${y + 2.8}v2.6M${x + 1.6} ${y + 2.8}v3M${x + 4} ${y + 2.8}v2.6`} stroke={trim} stroke-width={lw * 0.7} />
      </g>
    );
  };
  return (
    <g stroke-linejoin="round" stroke-linecap="round">
      {/* shirt wedge, lapels and the coat's long front */}
      <path d={`M${50 - nk - 6} 95L50 121L${50 + nk + 6} 95Z`} fill={cloth} stroke={edge} stroke-width={lw} />
      <path d={`M${50 - nk} 94.6L50 119L${50 + nk} 94.6Z`} fill={shirt} stroke={edge} stroke-width={lw * 0.8} />
      <path d={`M${50 - nk - 3} 91L${50 - 1.5} 121L${50 - nk - 11} 121L${50 - nk - 13} 100Z`} fill={cloth} stroke={edge} stroke-width={lw} />
      <path d={`M${50 + nk + 3} 91L${50 + 1.5} 121L${50 + nk + 11} 121L${50 + nk + 13} 100Z`} fill={cloth} stroke={edge} stroke-width={lw} />
      <path d={`M${50 - nk - 3} 91L${50 - 1.5} 121M${50 + nk + 3} 91L${50 + 1.5} 121`} stroke={trim} stroke-width={lw * 1.3} fill="none" />
      {/* stand-up collar */}
      <path d={`M${50 - nk + 1} 84L${50 - nk - 10} 87.6L${50 - nk - 8} 99.4L${50 - nk + 2.4} 96Z`} fill={cloth} stroke={edge} stroke-width={lw} />
      <path d={`M${50 + nk - 1} 84L${50 + nk + 10} 87.6L${50 + nk + 8} 99.4L${50 + nk - 2.4} 96Z`} fill={cloth} stroke={edge} stroke-width={lw} />
      <path d={`M${50 - nk - 8.4} 91.4L${50 - nk + 1} 88.8M${50 + nk + 8.4} 91.4L${50 + nk - 1} 88.8`} stroke={trim} stroke-width={lw * 1.1} fill="none" />
      {/* buttons, two rows */}
      <g fill={trim} stroke={edge} stroke-width={lw * 0.6}>
        {[103, 109, 115].map((y) => <g key={y}><circle cx={50 - 6.4} cy={y} r="1.5" /><circle cx={50 + 6.4} cy={y} r="1.5" /></g>)}
      </g>
      {ep(-1)}
      {ep(1)}
    </g>
  );
}

/** A faded hazard sash across the chest with a medal pinned to it. */
function Sash({ c }: { c: Ctx }) {
  const { P, nk, sw } = c;
  const band = P.heat ? P.fill(0.78) : P.accent;
  const edge = P.line(0.3);
  const lw = P.lw;
  const x0 = 50 - nk - 7, x1 = 50 + sw - 12;
  return (
    <g stroke-linejoin="round" stroke-linecap="round">
      <path d={`M${x0} 91L${x0 + 9.5} 88.6L${x1 + 8} 113L${x1 - 4} 113Z`} fill={band} stroke={edge} stroke-width={lw} />
      <path d={`M${x0 + 3.4} 90.4L${x1 + 0.6} 113M${x0 + 6.4} 89.6L${x1 + 4} 113`} stroke={P.heat ? P.fill(0.42) : P.ink} stroke-width={lw * 0.55} opacity="0.5" fill="none" />
      {/* the medal, pinned on the chest */}
      <path d="M32.8 99.6L30.6 105.8M38.6 100.4L39.6 106" stroke={P.heat ? P.fill(0.3) : '#A8261F'} stroke-width={lw * 1.9} fill="none" />
      <path d={star(35.6, 108.4, 5.6)} fill={P.heat ? P.fill(0.95) : P.paper} stroke={edge} stroke-width={lw * 0.9} />
      <circle cx="35.6" cy="108.6" r="1.4" fill={P.heat ? P.fill(0.5) : P.accent} stroke={edge} stroke-width={lw * 0.5} />
    </g>
  );
}

/* ---------------------------------------------------------------- human: face paint */
export function FieldPaint({ c }: { c: Ctx }) {
  if (c.look !== 3) return null;
  const { P, g } = c;
  const dark = P.heat ? P.fill(c.skinH - 0.3) : P.ink;
  const olive = P.heat ? P.fill(c.skinH - 0.14) : '#566B34';
  const ochre = P.heat ? P.fill(c.skinH + 0.12) : '#C79A3C';
  const cx = (s: 1 | -1, dx: number) => 50 + s * dx;
  const cheek = (s: 1 | -1) => {
    const x = g.w;
    return (
      <g key={s} stroke-linecap="round" fill="none">
        <path d={`M${cx(s, x - 0.5)} 57.6L${cx(s, x - 11)} 66.4`} stroke={dark} stroke-width="3.6" />
        <path d={`M${cx(s, x - 1.5)} 63.6L${cx(s, x - 10)} 71`} stroke={olive} stroke-width="3.4" />
        <path d={`M${cx(s, x - 3.5)} 69L${cx(s, x - 8.5)} 74`} stroke={ochre} stroke-width="2.8" />
      </g>
    );
  };
  return (
    <g clip-path={`url(#${c.id}-face)`} opacity={P.heat ? 0.9 : 0.94}>
      {cheek(-1)}
      {cheek(1)}
      {/* forehead slashes and the line down the nose */}
      <g stroke-linecap="round" fill="none">
        <path d="M37 25L43 38" stroke={olive} stroke-width="3.2" />
        <path d="M46 23L49.4 37" stroke={dark} stroke-width="3.4" />
        <path d="M55 24L55.4 38" stroke={olive} stroke-width="3.2" />
        <path d="M64 28L60.6 38" stroke={dark} stroke-width="3" />
        <path d="M50 40.6V58.6" stroke={ochre} stroke-width="2" opacity="0.9" />
      </g>
    </g>
  );
}

/* ---------------------------------------------------------------- human: head */
export function HumanSkinHead({ c }: { c: Ctx }) {
  if (c.zombie) return null;
  if (c.look === 2) return <RiotHelmet c={c} />;
  if (c.look === 3) return <Bandana c={c} />;
  if (c.look === 4) return <Respirator c={c} />;
  if (c.look === 5) return <PeakedCap c={c} />;
  return null;
}

/** A hard shell with ear guards and a clear visor lowered over the face. */
function RiotHelmet({ c }: { c: Ctx }) {
  const { P, g } = c;
  const hw = g.w + 3;
  const shell = P.fill(0.2, '#2F3B36', 0.92);
  const edge = P.line(0.25);
  const lw = P.lw;
  const clear = P.heat ? P.fill(0.1) : P.paper;
  const dome = `M${50 - hw} 55L${50 - hw - 0.4} 35C${50 - hw} 12 ${50 + hw} 12 ${50 + hw + 0.4} 35L${50 + hw} 55L${50 + hw - 3.4} 55L${50 + hw - 3.8} 41C${50 + hw * 0.55} 37.4 ${50 - hw * 0.55} 37.4 ${50 - hw + 3.8} 41L${50 - hw + 3.4} 55Z`;
  const vw = hw - 2.6;
  return (
    <g stroke-linejoin="round" stroke-linecap="round">
      {/* the visor first, so the shell's brow edge sits over its hinge */}
      <path d={`M${50 - vw} 40.4C${50 - vw * 0.5} 43 ${50 + vw * 0.5} 43 ${50 + vw} 40.4L${50 + vw - 1} 62C${50 + vw - 3} 69.6 ${50 + 5} 71 50 71C${50 - 5} 71 ${50 - vw + 3} 69.6 ${50 - vw + 1} 62Z`} fill={clear} fill-opacity={P.heat ? 0.55 : 0.3} stroke={edge} stroke-width={lw * 1.1} />
      <path d={`M${50 - vw + 6} 47L${50 - vw + 12} 66M${50 - vw + 11} 45.6L${50 - vw + 14.6} 57`} stroke={P.heat ? P.fill(0.5) : '#fff'} stroke-width={lw * 1.2} opacity={P.heat ? 0.7 : 0.85} fill="none" />
      <path d={`M${50 - vw + 1} 62C${50 - vw + 4} 69.6 ${50 - 5} 71 50 71C${50 + 5} 71 ${50 + vw - 4} 69.6 ${50 + vw - 1} 62`} fill="none" stroke={edge} stroke-width={lw * 1.9} />
      <path d={dome} fill={shell} stroke={edge} stroke-width={lw * 1.1} />
      <path d={`M${50 - hw * 0.62} 22.4C${50 - hw * 0.3} 17 ${50 + hw * 0.3} 17 ${50 + hw * 0.62} 22.4`} fill="none" stroke={P.heat ? P.fill(0.5) : P.paper2} stroke-width={lw * 0.9} opacity="0.85" />
      <path d="M50 14.6V35" stroke={edge} stroke-width={lw * 0.8} opacity="0.7" fill="none" />
      <circle cx={50 - vw + 2.4} cy="41.4" r="1.5" fill={P.heat ? P.fill(0.6) : P.paper} stroke={edge} stroke-width={lw * 0.6} />
      <circle cx={50 + vw - 2.4} cy="41.4" r="1.5" fill={P.heat ? P.fill(0.6) : P.paper} stroke={edge} stroke-width={lw * 0.6} />
    </g>
  );
}

/** A rubber respirator over nose and mouth: two filter canisters and straps back to the ears. */
function Respirator({ c }: { c: Ctx }) {
  const { P, g } = c;
  const rubber = P.fill(0.15, '#2B3331', 0.94);
  const can = P.fill(0.5, '#8E9A7A', 0.9);
  const edge = P.line(0.2);
  const lw = P.lw;
  const w2 = g.w - 2.4, w3 = g.jw - 0.4, ch = g.cy + 3.6;
  return (
    <g stroke-linejoin="round" stroke-linecap="round">
      <path d={`M${50 - g.w - 0.4} 55L${50 - w2 + 1} 62M${50 + g.w + 0.4} 55L${50 + w2 - 1} 62`} stroke={edge} stroke-width={lw * 2.2} fill="none" />
      <path d={`M${50 - w2} 61.4Q50 54.4 ${50 + w2} 61.4L${50 + w3} 74.4Q${50 + g.cw + 5} ${ch} 50 ${ch + 1.6}Q${50 - g.cw - 5} ${ch} ${50 - w3} 74.4Z`} fill={rubber} stroke={edge} stroke-width={lw * 1.1} />
      <path d={`M${50 - w2 + 4} 63.6Q50 58.8 ${50 + w2 - 4} 63.6`} fill="none" stroke={P.heat ? P.fill(0.42) : P.paper2} stroke-width={lw * 0.8} opacity="0.7" />
      <g fill={can} stroke={edge} stroke-width={lw * 0.9}>
        <circle cx={50 - w2 + 4.4} cy="72" r="4.8" /><circle cx={50 + w2 - 4.4} cy="72" r="4.8" />
      </g>
      <g fill="none" stroke={edge} stroke-width={lw * 0.6}>
        <circle cx={50 - w2 + 4.4} cy="72" r="2.4" /><circle cx={50 + w2 - 4.4} cy="72" r="2.4" />
      </g>
      <path d={`M46.6 ${ch - 7.6}h6.8M46.6 ${ch - 5.2}h6.8M46.6 ${ch - 2.8}h6.8`} stroke={edge} stroke-width={lw * 0.7} opacity="0.8" />
    </g>
  );
}

/** A knotted cloth band round the head, camouflaged, with the tails trailing at one ear. */
function Bandana({ c }: { c: Ctx }) {
  const { P, g } = c;
  const hw = g.w + 1.4;
  const cloth = P.fill(0.36, '#5E6F36', 0.9);
  const spot = P.fill(0.2, '#2D361A', 0.9);
  const edge = P.line(0.25);
  const lw = P.lw;
  return (
    <g stroke-linejoin="round" stroke-linecap="round">
      <path d={`M${50 + hw - 1} 37L${50 + hw + 9} 40.6L${50 + hw + 12.4} 53L${50 + hw + 7} 51.6L${50 + hw + 5.4} 58.4L${50 + hw + 1.4} 44Z`} fill={cloth} stroke={edge} stroke-width={lw} />
      <path d={`M${50 - hw} 40Q50 26.4 ${50 + hw} 38.4L${50 + hw + 0.6} 45Q50 34 ${50 - hw - 0.4} 46.6Z`} fill={cloth} stroke={edge} stroke-width={lw * 1.1} />
      <g fill={spot} opacity="0.85">
        <ellipse cx="38" cy="38.4" rx="3.6" ry="1.9" transform="rotate(-18 38 38.4)" /><ellipse cx="50" cy="33.4" rx="3" ry="1.6" /><ellipse cx="61" cy="36.6" rx="3.4" ry="1.8" transform="rotate(14 61 36.6)" />
        <ellipse cx={50 + hw + 6} cy="48" rx="1.6" ry="2.4" transform={`rotate(-14 ${50 + hw + 6} 48)`} />
      </g>
      <circle cx={50 + hw + 0.6} cy="41.6" r="3" fill={cloth} stroke={edge} stroke-width={lw} />
    </g>
  );
}

/** A peaked officer's cap with a badge and a braided band. */
function PeakedCap({ c }: { c: Ctx }) {
  const { P, g } = c;
  const hw = g.w + 2.6;
  const cloth = P.fill(0.17, '#33403A', 0.93);
  const trim = P.heat ? P.fill(0.8) : P.accent;
  const edge = P.line(0.25);
  const lw = P.lw;
  return (
    <g stroke-linejoin="round" stroke-linecap="round">
      <path d={`M${50 - hw - 1.6} 40L${50 - hw + 2} 21C${50 - hw * 0.5} 15 ${50 + hw * 0.5} 15 ${50 + hw - 2} 21L${50 + hw + 1.6} 40Z`} fill={cloth} stroke={edge} stroke-width={lw * 1.1} />
      <path d={`M${50 - hw - 1.4} 35.4Q50 40.6 ${50 + hw + 1.4} 35.4L${50 + hw + 1.6} 40.6Q50 46 ${50 - hw - 1.6} 40.6Z`} fill={P.fill(0.1, '#1D2420', 0.95)} stroke={edge} stroke-width={lw} />
      <path d={`M${50 - hw - 1.4} 36.8Q50 42.2 ${50 + hw + 1.4} 36.8`} fill="none" stroke={trim} stroke-width={lw * 1.5} />
      <path d={`M${50 - hw + 2.4} 40.8Q50 50.4 ${50 + hw - 2.4} 40.8L${50 + hw - 5} 44.4Q50 53 ${50 - hw + 5} 44.4Z`} fill={P.fill(0.08, '#141A17', 0.95)} stroke={edge} stroke-width={lw} />
      <path d={star(50, 29.4, 5.2)} fill={trim} stroke={edge} stroke-width={lw * 0.8} />
      <path d={`M${50 - hw + 5} 22.6Q50 17.6 ${50 + hw - 5} 22.6`} fill="none" stroke={edge} stroke-width={lw * 0.7} opacity="0.6" />
    </g>
  );
}

/* ---------------------------------------------------------------- infected: growths */

/** One bracket of shelf fungus: a half-disc cap with gills under it, hanging from `(x, y)` at tilt `a`. */
function Bracket({ c, x, y, r, a }: { c: Ctx; x: number; y: number; r: number; a: number }) {
  const { P } = c;
  const cap = P.heat ? P.fill(0.68) : mix(P.paper, P.accent, 0.5);
  const under = P.heat ? P.fill(0.38) : mix(P.paper2, P.ink, 0.25);
  const edge = P.heat ? P.fill(0.42) : P.ink;
  const gills: string[] = [];
  for (let i = 1; i < 6; i++) gills.push(`M${(x - r + (2 * r * i) / 6).toFixed(1)} ${y}v${(r * 0.18).toFixed(1)}`);
  return (
    <g transform={`rotate(${a} ${x} ${y})`} stroke-linejoin="round" stroke-linecap="round">
      <path d={`M${x - r} ${y}Q${x} ${y + r * 0.34} ${x + r} ${y}Z`} fill={under} stroke={edge} stroke-width={P.lw * 0.8} />
      <path d={gills.join('')} stroke={edge} stroke-width={P.lw * 0.5} opacity="0.7" fill="none" />
      <path d={`M${x - r} ${y}A${r} ${r * 0.62} 0 0 1 ${x + r} ${y}Z`} fill={cap} stroke={edge} stroke-width={P.lw} />
      <path d={`M${x - r * 0.62} ${y - r * 0.2}Q${x} ${y - r * 0.5} ${x + r * 0.5} ${y - r * 0.3}`} fill="none" stroke={P.heat ? P.fill(0.9) : P.paper} stroke-width={P.lw * 0.9} opacity="0.85" />
    </g>
  );
}

/** Fungal bloom (look 4 and on): brackets on the temple, jaw and shoulder, spores in the air. Look 5 adds the burning eyes. */
export function ZombieGrowth({ c }: { c: Ctx }) {
  if (!c.zombie || c.look < 4) return null;
  const { P, g } = c;
  const x = 50 - g.w;
  const spore = P.heat ? P.fill(0.95) : P.accent;
  return (
    <g>
      {c.look >= 5 && <EyeBurn c={c} />}
      <Bracket c={c} x={x + 1.6} y={37} r={7.6} a={-22} />
      <Bracket c={c} x={x - 1.2} y={43.6} r={5.2} a={-34} />
      <Bracket c={c} x={50 + g.w - 4} y={88} r={7} a={18} />
      <Bracket c={c} x={50 + g.w - 1} y={94} r={4.6} a={34} />
      <Bracket c={c} x={26} y={103} r={8.6} a={-12} />
      <g fill={spore} opacity={P.heat ? 0.9 : 0.8}>
        <circle cx={x - 6} cy="30" r="1.2" /><circle cx={x - 11} cy="38" r="0.9" /><circle cx={x - 3} cy="24" r="0.8" />
        <circle cx={50 + g.w + 8} cy="80" r="1.1" /><circle cx={50 + g.w + 12} cy="88" r="0.8" /><circle cx="17" cy="95" r="1" />
      </g>
    </g>
  );
}

/** Eyes that burn: a flare round each socket, with rays in Survey and a hard halo in Heat. */
function EyeBurn({ c }: { c: Ctx }) {
  const { P, g } = c;
  const eye = (sgn: 1 | -1) => {
    const x = 50 + sgn * g.w * 0.5, y = 51;
    return (
      <g key={sgn}>
        <circle cx={x} cy={y} r="10.5" fill={P.heat ? P.fill(1) : P.accent} opacity={P.heat ? 0.4 : 0.3} filter={`url(#${c.id}-blur)`} />
        {!P.heat && <path d={`M${x} ${y - 10}V${y - 7.4}M${x + sgn * 7.6} ${y - 7}l-1.6 1.8M${x - sgn * 7.6} ${y - 7}l1.6 1.8M${x + sgn * 9.2} ${y - 1}l-2.4 0.6`} stroke={P.ink} stroke-width={P.lw * 0.9} stroke-linecap="round" />}
      </g>
    );
  };
  return <g>{eye(-1)}{eye(1)}</g>;
}

/** The spore crown (look 6): antlers of fungus and bone rising from the skull, tipped with glowing spores. */
export function ZombieGrowthTop({ c }: { c: Ctx }) {
  if (!c.zombie || c.look < 6) return null;
  const { P } = c;
  const bone = P.heat ? P.fill(0.74) : mix(P.paper, P.accent, 0.2);
  const edge = P.heat ? P.fill(0.4) : P.ink;
  const glow = P.heat ? P.fill(1) : P.accent;
  const lw = P.lw;
  const horn = (sgn: 1 | -1) => {
    const X = (d: number) => 50 + sgn * d;
    return (
      <g key={sgn} fill="none" stroke-linecap="round" stroke-linejoin="round">
        <path d={`M${X(4.5)} 21.5C${X(8)} 17 ${X(9.5)} 13 ${X(15)} 9`} stroke={edge} stroke-width={lw * 4.4} />
        <path d={`M${X(4.5)} 21.5C${X(8)} 17 ${X(9.5)} 13 ${X(15)} 9`} stroke={bone} stroke-width={lw * 2.6} />
        <path d={`M${X(9.2)} 15.4C${X(12.5)} 15.2 ${X(16.5)} 17 ${X(19.6)} 21`} stroke={edge} stroke-width={lw * 3.6} />
        <path d={`M${X(9.2)} 15.4C${X(12.5)} 15.2 ${X(16.5)} 17 ${X(19.6)} 21`} stroke={bone} stroke-width={lw * 2} />
        <path d={`M${X(11.8)} 12C${X(12.8)} 10.4 ${X(12.4)} 9 ${X(10.8)} 7.8`} stroke={edge} stroke-width={lw * 3} />
        <path d={`M${X(11.8)} 12C${X(12.8)} 10.4 ${X(12.4)} 9 ${X(10.8)} 7.8`} stroke={bone} stroke-width={lw * 1.5} />
        <g fill={glow} stroke={edge} stroke-width={lw * 0.6}>
          <circle cx={X(15.2)} cy="8.6" r="2" /><circle cx={X(19.8)} cy="21.4" r="1.7" /><circle cx={X(10.6)} cy="7.2" r="1.4" />
        </g>
      </g>
    );
  };
  return (
    <g>
      {P.heat && <ellipse cx="50" cy="15" rx="17" ry="9" fill={glow} opacity="0.3" filter={`url(#${c.id}-blur)`} />}
      {horn(-1)}
      {horn(1)}
      <path d={symShape({ start: [0, 18], segs: [line([0, 18], [9, 25.6])] }, { start: [9, 25.6], segs: [[5, 23, 2, 22.4, 0, 22.4]] })} fill={bone} stroke={edge} stroke-width={lw} stroke-linejoin="round" />
      <circle cx="50" cy="20.2" r="2.2" fill={glow} stroke={edge} stroke-width={lw * 0.7} />
    </g>
  );
}

