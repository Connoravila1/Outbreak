import type { LayerSpecification, StyleSpecification } from 'maplibre-gl';
import { HEAT as C } from '../palette';
import {
  FONT_REGULAR, ROAD_GROUPS, SRC, SANCTUARY_BUFFER_M, baseStyle, groundRadius, isWorship, pathFilter, roadFilter,
  sanctuaryLanduseFilter, widthExpr,
} from './common';

/** Heat: thermal sense. Cold indigo void, roads as faint warm veins, buildings as cold mass. */
export function heatStyle(lat = 40): StyleSpecification {
  const layers: LayerSpecification[] = [
    { id: 'landcover', type: 'fill', source: SRC, 'source-layer': 'landcover', paint: { 'fill-color': C.cold, 'fill-opacity': 0.14 } },
    { id: 'park', type: 'fill', source: SRC, 'source-layer': 'park', paint: { 'fill-color': C.cold, 'fill-opacity': 0.22 } },
    { id: 'water', type: 'fill', source: SRC, 'source-layer': 'water', paint: { 'fill-color': C.water } },
    { id: 'waterway', type: 'line', source: SRC, 'source-layer': 'waterway', paint: { 'line-color': C.water, 'line-width': ['interpolate', ['linear'], ['zoom'], 12, 0.8, 18, 4] } },
    { id: 'building', type: 'fill', source: SRC, 'source-layer': 'building', minzoom: 14, paint: { 'fill-color': C.cold, 'fill-opacity': ['interpolate', ['linear'], ['zoom'], 14, 0.3, 17, 0.62] } },
    // sanctuaries: a cool dead zone where nothing glows
    { id: 'sanctuary-fill', type: 'fill', source: SRC, 'source-layer': 'landuse', filter: sanctuaryLanduseFilter, paint: { 'fill-color': C.dead, 'fill-opacity': 0.92 } },
    { id: 'sanctuary-edge', type: 'line', source: SRC, 'source-layer': 'landuse', filter: sanctuaryLanduseFilter, paint: { 'line-color': C.deadEdge, 'line-opacity': 0.45, 'line-width': 1.2, 'line-blur': 1 } },
    { id: 'sanctuary-worship', type: 'circle', source: SRC, 'source-layer': 'poi', filter: isWorship, paint: { 'circle-radius': groundRadius(SANCTUARY_BUFFER_M, lat), 'circle-color': C.dead, 'circle-opacity': 0.92, 'circle-stroke-color': C.deadEdge, 'circle-stroke-opacity': 0.45, 'circle-stroke-width': 1, 'circle-blur': 0.2, 'circle-pitch-alignment': 'map' } },
    {
      id: 'path-glow', type: 'line', source: SRC, 'source-layer': 'transportation', filter: pathFilter, minzoom: 14,
      paint: { 'line-color': C.vein, 'line-opacity': 0.35, 'line-dasharray': [1, 2], 'line-width': ['interpolate', ['linear'], ['zoom'], 14, 0.6, 19, 2] },
    },
  ];
  for (const g of [...ROAD_GROUPS].reverse()) {
    layers.push({
      id: `vein-glow-${g.id}`, type: 'line', source: SRC, 'source-layer': 'transportation', filter: roadFilter(g.classes), minzoom: g.minzoom ?? 0,
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: { 'line-color': C.vein, 'line-opacity': 0.55, 'line-blur': 5, 'line-width': widthExpr(g, 1.6) },
    });
  }
  for (const g of [...ROAD_GROUPS].reverse()) {
    layers.push({
      id: `vein-${g.id}`, type: 'line', source: SRC, 'source-layer': 'transportation', filter: roadFilter(g.classes), minzoom: g.minzoom ?? 0,
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: { 'line-color': C.veinBright, 'line-opacity': 0.75, 'line-width': widthExpr(g, 0.28) },
    });
  }
  layers.push(
    {
      id: 'road-label', type: 'symbol', source: SRC, 'source-layer': 'transportation_name', minzoom: 15.5,
      filter: ['in', ['get', 'class'], ['literal', ['motorway', 'trunk', 'primary', 'secondary', 'tertiary']]],
      layout: { 'symbol-placement': 'line', 'text-field': ['get', 'name'], 'text-font': FONT_REGULAR, 'text-size': 11, 'text-transform': 'lowercase', 'text-letter-spacing': 0.16, 'symbol-spacing': 420 },
      paint: { 'text-color': C.veinBright, 'text-opacity': 0.5, 'text-halo-color': C.void, 'text-halo-width': 1.5 },
    },
    {
      id: 'place-label', type: 'symbol', source: SRC, 'source-layer': 'place', minzoom: 11, maxzoom: 17,
      filter: ['in', ['get', 'class'], ['literal', ['city', 'town', 'village', 'suburb', 'neighbourhood', 'quarter']]],
      layout: { 'text-field': ['get', 'name'], 'text-font': FONT_REGULAR, 'text-size': 12, 'text-transform': 'lowercase', 'text-letter-spacing': 0.22, 'text-max-width': 8 },
      paint: { 'text-color': C.veinBright, 'text-opacity': 0.4 },
    },
  );
  return baseStyle(C.void, layers);
}
