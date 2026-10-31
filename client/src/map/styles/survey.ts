import type { LayerSpecification, StyleSpecification } from 'maplibre-gl';
import { SURVEY as C } from '../palette';
import {
  FONT_BOLD, FONT_REGULAR, GREEN_LANDUSE, ROAD_GROUPS, SRC, baseStyle, groundRadius, isWorship, pathFilter,
  railFilter, roadFilter, sanctuaryLanduseFilter, widthExpr, SANCTUARY_BUFFER_M,
} from './common';

/** Pattern image ids; the images themselves are painted in patterns.ts. */
export const SURVEY_STIPPLE = 'survey-stipple';
export const SURVEY_HATCH = 'survey-hatch';

/** Survey: two-ink print on grey map paper. Brown roads, blue water, pencil hatching. */
export function surveyStyle(lat = 40): StyleSpecification {
  const layers: LayerSpecification[] = [
    { id: 'landcover', type: 'fill', source: SRC, 'source-layer': 'landcover', paint: { 'fill-color': C.paperDeep, 'fill-opacity': 0.28 } },
    { id: 'park', type: 'fill', source: SRC, 'source-layer': 'park', paint: { 'fill-color': C.paperDeep, 'fill-opacity': 0.4 } },
    { id: 'landuse-green', type: 'fill', source: SRC, 'source-layer': 'landuse', filter: ['in', ['get', 'class'], ['literal', GREEN_LANDUSE]], paint: { 'fill-color': C.paperDeep, 'fill-opacity': 0.4 } },
    { id: 'landuse-industrial', type: 'fill', source: SRC, 'source-layer': 'landuse', filter: ['in', ['get', 'class'], ['literal', ['industrial', 'commercial', 'retail']]], paint: { 'fill-color': C.paper2, 'fill-opacity': 0.5 } },
    { id: 'water', type: 'fill', source: SRC, 'source-layer': 'water', paint: { 'fill-color': C.blue, 'fill-opacity': 0.5 } },
    { id: 'water-edge', type: 'line', source: SRC, 'source-layer': 'water', paint: { 'line-color': C.blue, 'line-width': 1, 'line-opacity': 0.8 } },
    { id: 'waterway', type: 'line', source: SRC, 'source-layer': 'waterway', paint: { 'line-color': C.blue, 'line-opacity': 0.8, 'line-width': ['interpolate', ['linear'], ['zoom'], 12, 0.6, 18, 3] } },
    // sanctuaries: diagonal pencil hatching in survey blue, drawn under roads and buildings
    { id: 'sanctuary-fill', type: 'fill', source: SRC, 'source-layer': 'landuse', filter: sanctuaryLanduseFilter, paint: { 'fill-pattern': SURVEY_HATCH, 'fill-opacity': 0.95 } },
    { id: 'sanctuary-edge', type: 'line', source: SRC, 'source-layer': 'landuse', filter: sanctuaryLanduseFilter, paint: { 'line-color': C.blue, 'line-opacity': 0.55, 'line-width': 1, 'line-dasharray': [3, 2] } },
    { id: 'sanctuary-worship', type: 'circle', source: SRC, 'source-layer': 'poi', filter: isWorship, paint: { 'circle-radius': groundRadius(SANCTUARY_BUFFER_M, lat), 'circle-color': C.blue, 'circle-opacity': 0.14, 'circle-stroke-color': C.blue, 'circle-stroke-opacity': 0.55, 'circle-stroke-width': 1, 'circle-pitch-alignment': 'map' } },
    { id: 'building', type: 'fill', source: SRC, 'source-layer': 'building', minzoom: 14, paint: { 'fill-color': C.paper2, 'fill-opacity': 0.85, 'fill-outline-color': C.ink } },
    { id: 'building-stipple', type: 'fill', source: SRC, 'source-layer': 'building', minzoom: 15.5, paint: { 'fill-pattern': SURVEY_STIPPLE, 'fill-opacity': 0.7 } },
    { id: 'building-edge', type: 'line', source: SRC, 'source-layer': 'building', minzoom: 15, paint: { 'line-color': C.ink, 'line-opacity': 0.4, 'line-width': 0.7 } },
    {
      id: 'path', type: 'line', source: SRC, 'source-layer': 'transportation', filter: pathFilter, minzoom: 14,
      paint: { 'line-color': C.brown, 'line-opacity': 0.8, 'line-dasharray': [2, 2], 'line-width': ['interpolate', ['linear'], ['zoom'], 14, 0.6, 19, 2.4] },
    },
    {
      id: 'rail', type: 'line', source: SRC, 'source-layer': 'transportation', filter: railFilter, minzoom: 11,
      paint: { 'line-color': C.ink, 'line-opacity': 0.6, 'line-dasharray': [4, 3], 'line-width': ['interpolate', ['linear'], ['zoom'], 11, 0.6, 18, 2] },
    },
  ];
  // casings first (all groups), then fills, so intersections merge cleanly
  for (const g of [...ROAD_GROUPS].reverse()) {
    layers.push({
      id: `road-case-${g.id}`, type: 'line', source: SRC, 'source-layer': 'transportation', filter: roadFilter(g.classes), minzoom: g.minzoom ?? 0,
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: { 'line-color': C.brownDark, 'line-opacity': 0.9, 'line-width': widthExpr(g, 1.0) },
    });
  }
  for (const g of [...ROAD_GROUPS].reverse()) {
    layers.push({
      id: `road-${g.id}`, type: 'line', source: SRC, 'source-layer': 'transportation', filter: roadFilter(g.classes), minzoom: g.minzoom ?? 0,
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: { 'line-color': C.brown, 'line-width': widthExpr(g, 0.72) },
    });
  }
  layers.push(
    {
      id: 'road-label', type: 'symbol', source: SRC, 'source-layer': 'transportation_name', minzoom: 15.5,
      filter: ['in', ['get', 'class'], ['literal', ['motorway', 'trunk', 'primary', 'secondary', 'tertiary']]],
      layout: { 'symbol-placement': 'line', 'text-field': ['get', 'name'], 'text-font': FONT_REGULAR, 'text-size': 11, 'text-letter-spacing': 0.04, 'symbol-spacing': 420, 'text-max-angle': 30 },
      paint: { 'text-color': C.ink, 'text-halo-color': C.paper, 'text-halo-width': 1.8, 'text-opacity': 0.85 },
    },
    {
      id: 'water-label', type: 'symbol', source: SRC, 'source-layer': 'water_name', minzoom: 12,
      layout: { 'text-field': ['get', 'name'], 'text-font': ['Noto Sans Italic'], 'text-size': 12 },
      paint: { 'text-color': C.blue, 'text-halo-color': C.paper, 'text-halo-width': 1.5 },
    },
    {
      id: 'place-label', type: 'symbol', source: SRC, 'source-layer': 'place', minzoom: 11, maxzoom: 17,
      filter: ['in', ['get', 'class'], ['literal', ['city', 'town', 'village', 'suburb', 'neighbourhood', 'quarter']]],
      layout: { 'text-field': ['get', 'name'], 'text-font': FONT_BOLD, 'text-size': 12, 'text-transform': 'uppercase', 'text-letter-spacing': 0.14, 'text-max-width': 8 },
      paint: { 'text-color': C.ink, 'text-opacity': 0.55, 'text-halo-color': C.paper, 'text-halo-width': 1.5 },
    },
  );
  return baseStyle(C.paper, layers);
}
