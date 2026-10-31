import type { ExpressionSpecification, LayerSpecification, StyleSpecification } from 'maplibre-gl';
import { tileSource } from '../tiles';

export const SRC = 'openmaptiles';
export const FONT_REGULAR = ['Noto Sans Regular'];
export const FONT_BOLD = ['Noto Sans Bold'];
export const FONT_ITALIC = ['Noto Sans Italic'];

export const SANCTUARY_LANDUSE = ['hospital', 'school', 'kindergarten', 'college', 'university'];
export const SANCTUARY_POI_CLASS = 'place_of_worship';
export const SANCTUARY_BUFFER_M = 40;

export const isWorship: ExpressionSpecification = [
  'any',
  ['==', ['get', 'class'], SANCTUARY_POI_CLASS],
  ['==', ['get', 'subclass'], SANCTUARY_POI_CLASS],
];

/** Pixel radius of `metres` at zoom `z` and latitude `lat` (512px tiles). */
export function metresToPx(metres: number, z: number, lat: number): number {
  const mpp = (78271.517 * Math.cos((lat * Math.PI) / 180)) / Math.pow(2, z);
  return metres / mpp;
}

/** A circle-radius expression that keeps a constant ground radius across zoom levels. */
export function groundRadius(metres: number, lat: number): ExpressionSpecification {
  return ['interpolate', ['exponential', 2], ['zoom'], 10, metresToPx(metres, 10, lat), 22, metresToPx(metres, 22, lat)];
}

export function baseStyle(background: string, layers: LayerSpecification[]): StyleSpecification {
  return {
    version: 8,
    glyphs: tileSource().glyphs,
    sources: { [SRC]: { type: 'vector', url: tileSource().url } },
    layers: [{ id: 'background', type: 'background', paint: { 'background-color': background } }, ...layers],
  };
}

export type RoadGroup = { id: string; classes: string[]; w12: number; w16: number; w19: number; minzoom?: number };

/** Road classes in OpenMapTiles, widest first, with pixel widths at zooms 12 / 16 / 19. */
export const ROAD_GROUPS: RoadGroup[] = [
  { id: 'major', classes: ['motorway', 'trunk'], w12: 2.2, w16: 9, w19: 28 },
  { id: 'primary', classes: ['primary'], w12: 1.6, w16: 7, w19: 22 },
  { id: 'secondary', classes: ['secondary', 'tertiary'], w12: 1, w16: 5.5, w19: 18, minzoom: 11 },
  { id: 'minor', classes: ['minor', 'service'], w12: 0.4, w16: 3.8, w19: 13, minzoom: 12.5 },
];

export function widthExpr(g: RoadGroup, scale = 1): ExpressionSpecification {
  return ['interpolate', ['exponential', 1.6], ['zoom'], 12, g.w12 * scale, 16, g.w16 * scale, 19, g.w19 * scale];
}

export const roadFilter = (classes: string[]): ExpressionSpecification => [
  'all',
  ['==', ['geometry-type'], 'LineString'],
  ['in', ['get', 'class'], ['literal', classes]],
  ['!=', ['get', 'brunnel'], 'tunnel'],
];

export const pathFilter: ExpressionSpecification = [
  'all',
  ['==', ['geometry-type'], 'LineString'],
  ['in', ['get', 'class'], ['literal', ['path', 'track', 'pier']]],
];

export const railFilter: ExpressionSpecification = ['all', ['==', ['get', 'class'], 'rail'], ['!=', ['get', 'brunnel'], 'tunnel']];

export const sanctuaryLanduseFilter: ExpressionSpecification = ['in', ['get', 'class'], ['literal', SANCTUARY_LANDUSE]];

export const GREEN_LANDUSE = ['cemetery', 'pitch', 'playground', 'garden', 'recreation_ground'];
