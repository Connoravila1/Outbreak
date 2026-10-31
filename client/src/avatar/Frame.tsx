import type { ComponentChildren } from 'preact';
import { Avatar, type AvatarProps } from './Avatar';
import './frame.css';

const polar = (r: number, deg: number): [number, number] => {
  const a = (deg * Math.PI) / 180;
  return [50 + r * Math.cos(a), 50 + r * Math.sin(a)];
};
const f1 = (n: number) => Math.round(n * 10) / 10;

/** One barb of the wire: two short crossed strokes, turned to the ring. */
function Barb({ deg }: { deg: number }) {
  const [x, y] = polar(44.5, deg);
  return <path d="M-3.4 -2.2 L3.4 2.2 M-3.4 2.2 L3.4 -2.2" transform={`translate(${f1(x)} ${f1(y)}) rotate(${deg})`} />;
}

const SPORE_AT = [10, 35, 62, 95, 130, 150, 185, 210, 240, 275, 300, 330];
const SPORE_R = [44, 47, 45, 48, 44, 47, 45, 49, 44, 46, 48, 45];
const SPORE_S = [3.2, 2, 2.6, 1.8, 3.4, 2.2, 2.8, 2, 3, 2.4, 3.2, 1.8];

/** A leaf along a wreath branch: an ellipse laid across the ring, leaning with it. */
function Leaf({ deg, side }: { deg: number; side: 1 | -1 }) {
  const [x, y] = polar(45, deg);
  return <ellipse cx={f1(x)} cy={f1(y)} rx="5" ry="2.1" transform={`rotate(${deg + 90 + side * 32} ${f1(x)} ${f1(y)})`} />;
}
const LEAVES = [102, 118, 134, 150, 166, 182, 198, 214, 230];

function FrameArt({ id }: { id: string }) {
  switch (id) {
    case 'frame_grease':
      return (
        <g fill="none" stroke="var(--fa)" stroke-linecap="round">
          <path stroke-width="3.4" d="M50 5 C77 4 95 25 94 51 C93 77 73 95 48 94 C23 93 6 74 7 48 C8 24 28 8 58 9" />
          <path stroke-width="2" opacity=".55" d="M43 3 C70 2 98 22 97 55 C96 70 90 82 80 90" />
        </g>
      );
    case 'frame_tape': {
      const c = 2 * Math.PI * 45.5;
      return (
        <g fill="none" stroke-width="7">
          <circle cx="50" cy="50" r="45.5" stroke="var(--fb)" />
          <circle cx="50" cy="50" r="45.5" stroke="var(--fa)" stroke-dasharray={`${f1(c / 28)} ${f1(c / 28)}`} />
        </g>
      );
    }
    case 'frame_stitch':
      return (
        <g fill="none">
          <circle cx="50" cy="50" r="44.5" stroke="var(--fb)" stroke-width="1.4" />
          <circle cx="50" cy="50" r="44.5" stroke="var(--fa)" stroke-width="6" stroke-dasharray="1.9 4.1" />
        </g>
      );
    case 'frame_reticle':
      return (
        <g fill="none" stroke="var(--fa)" stroke-linecap="square">
          <circle cx="50" cy="50" r="45" stroke-width="1.1" opacity=".7" />
          <path stroke-width="3.2" d="M4 20 V4 H20 M80 4 H96 V20 M96 80 V96 H80 M20 96 H4 V80" />
          <path stroke-width="2.4" d="M50 3 V12 M50 88 V97 M3 50 H12 M88 50 H97" />
        </g>
      );
    case 'frame_barbed':
      return (
        <g fill="none" stroke="var(--fa)" stroke-linecap="round">
          <circle cx="50" cy="50" r="44.5" stroke="var(--fb)" stroke-width="2.2" />
          <g stroke-width="1.8">{Array.from({ length: 14 }, (_, i) => <Barb key={i} deg={i * (360 / 14) + 8} />)}</g>
        </g>
      );
    case 'frame_bloom':
      return (
        <g fill="var(--fa)" stroke="none">
          <circle cx="50" cy="50" r="44" fill="none" stroke="var(--fb)" stroke-width="1" stroke-dasharray="2 3" />
          {SPORE_AT.map((d, i) => { const [x, y] = polar(SPORE_R[i], d); return <circle key={d} cx={f1(x)} cy={f1(y)} r={SPORE_S[i]} />; })}
        </g>
      );
    case 'frame_wreath':
      return (
        <g fill="var(--fa)" stroke="none">
          <path fill="none" stroke="var(--fb)" stroke-width="1.4" d="M42 94 C14 84 4 60 8 36 M58 94 C86 84 96 60 92 36" />
          {LEAVES.map((d) => <Leaf key={'l' + d} deg={d} side={1} />)}
          {LEAVES.map((d) => <Leaf key={'r' + d} deg={180 - d} side={-1} />)}
        </g>
      );
    default:
      return null;
  }
}

/** The art around a portrait. Colours come from the lens through CSS variables (frame.css). */
export function FrameRing({ id }: { id: string }) {
  return (
    <svg class="frame-ring" viewBox="0 0 100 100" aria-hidden="true" focusable="false">
      <FrameArt id={id} />
    </svg>
  );
}

interface FramedProps extends Omit<AvatarProps, 'size'> {
  /** Cosmetic id from the catalog, or null for a bare portrait. */
  frame: string | null | undefined;
  /** Outside size; the portrait takes about four fifths of it. */
  size?: number;
  children?: ComponentChildren;
}

/** The avatar in its round plate, with the equipped frame around it. */
export function FramedAvatar({ frame, size = 88, children, ...avatar }: FramedProps) {
  const inner = Math.round(size * 0.82);
  return (
    <div class={'portrait' + (frame ? ' framed ' + frame.replace('_', '-') : '')} style={{ width: `${size}px`, height: `${size}px` }}>
      <div class="avatar-frame" style={{ width: `${inner}px`, height: `${inner}px` }}>
        <Avatar {...avatar} size={inner} />
      </div>
      {frame && <FrameRing id={frame} />}
      {children}
    </div>
  );
}
