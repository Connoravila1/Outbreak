import type { LayerSpecification, StyleSpecification } from 'maplibre-gl';
import { NEUTRAL as C } from '../palette';
import { ROAD_GROUPS, SRC, baseStyle, roadFilter, widthExpr } from './common';

/** Neutral: dark and minimal, for the broadcast before a side is chosen. */
export function neutralStyle(): StyleSpecification {
  const layers: LayerSpecification[] = [
    { id: 'water', type: 'fill', source: SRC, 'source-layer': 'water', paint: { 'fill-color': C.water } },
    { id: 'park', type: 'fill', source: SRC, 'source-layer': 'park', paint: { 'fill-color': C.land, 'fill-opacity': 0.6 } },
    { id: 'building', type: 'fill', source: SRC, 'source-layer': 'building', minzoom: 14, paint: { 'fill-color': C.building } },
  ];
  for (const g of [...ROAD_GROUPS].reverse()) {
    layers.push({
      id: `road-${g.id}`, type: 'line', source: SRC, 'source-layer': 'transportation', filter: roadFilter(g.classes), minzoom: g.minzoom ?? 0,
      layout: { 'line-cap': 'round', 'line-join': 'round' },
      paint: { 'line-color': g.id === 'major' || g.id === 'primary' ? C.roadBig : C.road, 'line-width': widthExpr(g, 0.45) },
    });
  }
  return baseStyle(C.bg, layers);
}
