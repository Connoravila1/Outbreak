import type { Map as MlMap } from 'maplibre-gl';
import { SURVEY as C } from './palette';
import { SURVEY_HATCH, SURVEY_STIPPLE } from './styles/survey';

type Painter = (g: CanvasRenderingContext2D, s: number) => void;

const PAINTERS: Record<string, { size: number; paint: Painter }> = {
  // sparse ink stipple on a building fill
  [SURVEY_STIPPLE]: {
    size: 16,
    paint(g, s) {
      g.fillStyle = C.ink;
      g.globalAlpha = 0.35;
      for (const [x, y] of [[2, 3], [9, 1], [13, 7], [5, 10], [11, 13], [1, 14]]) g.fillRect(x, y, 1, 1);
      g.globalAlpha = 1;
      void s;
    },
  },
  // diagonal pencil hatching in survey blue
  [SURVEY_HATCH]: {
    size: 12,
    paint(g, s) {
      g.strokeStyle = C.blue;
      g.globalAlpha = 0.55;
      g.lineWidth = 1;
      g.beginPath();
      for (const o of [-s, 0, s]) { g.moveTo(o, s); g.lineTo(o + s, 0); }
      g.stroke();
      g.globalAlpha = 1;
    },
  },
};

function add(map: MlMap, id: string) {
  const p = PAINTERS[id];
  if (!p || map.hasImage(id)) return;
  const c = document.createElement('canvas');
  const px = p.size * 2; // painted at 2x for crispness
  c.width = c.height = px;
  const g = c.getContext('2d');
  if (!g) return;
  g.scale(2, 2);
  p.paint(g, p.size);
  map.addImage(id, g.getImageData(0, 0, px, px), { pixelRatio: 2 });
}

/** Paints the Survey fill patterns on demand (style JSON cannot embed images). */
export function installPatterns(map: MlMap) {
  map.setMissingStyleImageResolver((id) => add(map, id));
}
