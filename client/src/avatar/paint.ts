/* Colour and path helpers for the avatar. Palette values mirror styles/tokens.css (the avatar must
   also render outside the app, e.g. in standalone previews, so it does not read CSS variables). */

const clamp = (v: number, a = 0, b = 1) => Math.max(a, Math.min(b, v));

function rgb(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}
const hex2 = (v: number) => Math.round(clamp(v, 0, 255)).toString(16).padStart(2, '0');

export function mix(a: string, b: string, t: number): string {
  const [r1, g1, b1] = rgb(a), [r2, g2, b2] = rgb(b);
  return `#${hex2(r1 + (r2 - r1) * t)}${hex2(g1 + (g2 - g1) * t)}${hex2(b1 + (b2 - b1) * t)}`;
}

/** Thermal gradient map: void -> cold -> vein -> warm -> hot -> white-hot. */
const RAMP: [number, string][] = [
  [0, '#110A1A'], [0.2, '#2A2560'], [0.4, '#5B2A6E'], [0.58, '#C02A7C'], [0.78, '#FF6B2C'], [1, '#FFF0C2'],
];
export function heatColor(h: number): string {
  const v = clamp(h);
  for (let i = 1; i < RAMP.length; i++) {
    if (v <= RAMP[i][0]) {
      const [h0, c0] = RAMP[i - 1], [h1, c1] = RAMP[i];
      return mix(c0, c1, (v - h0) / (h1 - h0));
    }
  }
  return RAMP[RAMP.length - 1][1];
}

/** Survey ink/paper and the two accents (hazard for the living, grease for the infected). */
const INK = '#1F2326', PAPER = '#DCDDD5', PAPER2 = '#C9CBC1', HAZARD = '#F2BE1A', GREASE = '#C8312B';

export interface Paint {
  heat: boolean;
  lw: number;
  ink: string;
  paper: string;
  paper2: string;
  accent: string;
  /** Fill for a layer. h is its thermal value; tint is its true colour (used by Survey). */
  fill(h: number, tint?: string, amt?: number): string;
  /** Outline colour for a shape filled at heat h. */
  line(h: number): string;
}

export function makePaint(heat: boolean, zombie: boolean, size: number): Paint {
  const lw = clamp(76 / size, 1.1, 2.4);
  if (heat) {
    return {
      heat, lw: lw * 0.7, ink: heatColor(0.08), paper: heatColor(0.1), paper2: heatColor(0.2), accent: heatColor(0.95),
      fill: (h) => heatColor(h),
      line: (h) => heatColor(h - 0.2),
    };
  }
  return {
    heat, lw, ink: INK, paper: PAPER, paper2: PAPER2, accent: zombie ? GREASE : HAZARD,
    fill: (h, tint, amt = 0.8) => (tint ? mix(PAPER, tint, amt) : mix(INK, PAPER, clamp(h))),
    line: () => INK,
  };
}

/* ---- symmetric shapes ----
   A half is described right-side only, in (dx from centre, y) coordinates: a start point and cubic
   segments [c1x,c1y,c2x,c2y,x,y]. The other side is the mirror, walked in reverse. */
export type Seg = [number, number, number, number, number, number];
export type Half = { start: [number, number]; segs: Seg[] };

const f = (v: number) => Math.round(v * 100) / 100;

function emit(h: Half, sgn: 1 | -1, cx: number): string {
  return h.segs.map((s) => `C${f(cx + sgn * s[0])} ${f(s[1])} ${f(cx + sgn * s[2])} ${f(s[3])} ${f(cx + sgn * s[4])} ${f(s[5])}`).join('');
}

export function reverse(h: Half): Half {
  const pts: [number, number][] = [h.start, ...h.segs.map((s): [number, number] => [s[4], s[5]])];
  const segs: Seg[] = [];
  for (let i = h.segs.length - 1; i >= 0; i--) {
    const s = h.segs[i];
    segs.push([s[2], s[3], s[0], s[1], pts[i][0], pts[i][1]]);
  }
  return { start: pts[pts.length - 1], segs };
}

/** Straight line as a cubic segment. */
export const line = (from: [number, number], to: [number, number]): Seg => [
  from[0] + (to[0] - from[0]) / 3, from[1] + (to[1] - from[1]) / 3,
  from[0] + (2 * (to[0] - from[0])) / 3, from[1] + (2 * (to[1] - from[1])) / 3, to[0], to[1],
];

/** Closed mirror-symmetric shape: outer runs top-centre down the right; inner returns to centre. */
export function symShape(outer: Half, inner: Half | null, cx = 50): string {
  const o = outer, i = inner ?? { start: outer.segs.length ? [outer.segs[outer.segs.length - 1][4], outer.segs[outer.segs.length - 1][5]] as [number, number] : outer.start, segs: [] };
  return (
    `M${f(cx + o.start[0])} ${f(o.start[1])}` + emit(o, 1, cx) + emit(i, 1, cx) + emit(reverse(i), -1, cx) + emit(reverse(o), -1, cx) + 'Z'
  );
}

/** Small stable hash for unique SVG ids. */
export function hash(s: string): string {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
  return (h >>> 0).toString(36);
}
