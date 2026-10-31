import type { Map as MlMap } from 'maplibre-gl';
import { SANCTUARY_BUFFER_M, SANCTUARY_LANDUSE, SANCTUARY_POI_CLASS, SRC } from './styles/common';
import { haversine } from '../location/geo';

type Ring = number[][];

function inRing(x: number, y: number, ring: Ring): boolean {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i];
    const [xj, yj] = ring[j];
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

/** Point-in-polygon with holes. `rings[0]` is the outer ring. */
export function inPolygon(x: number, y: number, rings: Ring[]): boolean {
  if (!rings.length || !inRing(x, y, rings[0])) return false;
  for (let i = 1; i < rings.length; i++) if (inRing(x, y, rings[i])) return false;
  return true;
}

/**
 * Sanctuary test against the tiles the map has loaded: hospital/school/kindergarten/college/
 * university landuse polygons, and places of worship buffered by 40 m. Returns false until
 * tiles around the point have loaded, so callers should treat it as best effort.
 */
export function isInSanctuary(map: MlMap, p: { lng: number; lat: number }): boolean {
  if (!map.getSource(SRC)) return false;
  const zones = map.querySourceFeatures(SRC, {
    sourceLayer: 'landuse',
    filter: ['in', 'class', ...SANCTUARY_LANDUSE],
  });
  for (const f of zones) {
    const g = f.geometry;
    if (g.type === 'Polygon') {
      if (inPolygon(p.lng, p.lat, g.coordinates)) return true;
    } else if (g.type === 'MultiPolygon') {
      for (const poly of g.coordinates) if (inPolygon(p.lng, p.lat, poly)) return true;
    }
  }
  const pois = map.querySourceFeatures(SRC, { sourceLayer: 'poi' });
  for (const f of pois) {
    const props = f.properties ?? {};
    if (props.class !== SANCTUARY_POI_CLASS && props.subclass !== SANCTUARY_POI_CLASS) continue;
    if (f.geometry.type !== 'Point') continue;
    const [lon, lat] = f.geometry.coordinates;
    if (haversine({ lat: p.lat, lon: p.lng }, { lat, lon }) <= SANCTUARY_BUFFER_M) return true;
  }
  return false;
}
