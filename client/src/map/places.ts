import type { Map as MlMap } from 'maplibre-gl';
import type { PlaceKind, PlaceReport } from '../api';
import { haversine } from '../location/geo';
import { SRC } from './styles/common';

/** How far from the player places are reported, and the most sent per location poll. */
export const PLACE_RADIUS_M = 400;
export const PLACE_MAX = 40;

/** OpenStreetMap `class` / `subclass` words (OpenMapTiles `poi` layer) for each game kind. */
const WORDS: Record<PlaceKind, string[]> = {
  pharmacy: ['pharmacy', 'doctors', 'doctor', 'clinic'],
  grocery: ['supermarket', 'grocery', 'convenience', 'bakery', 'butcher'],
  hardware: ['hardware', 'doityourself', 'car_repair'],
  fuel: ['fuel'],
  police: ['police', 'military'],
  outfitter: ['sports', 'outdoor', 'clothes', 'clothing_store'],
  diner: ['bar', 'pub', 'restaurant', 'fast_food', 'cafe'],
};

/** Sanctuaries stay out of the game: no cache is ever tied to them. */
const SANCTUARY_WORDS = new Set(['hospital', 'school', 'kindergarten', 'college', 'university', 'place_of_worship']);

const KIND_OF = new Map<string, PlaceKind>();
for (const [kind, words] of Object.entries(WORDS) as [PlaceKind, string[]][]) for (const w of words) KIND_OF.set(w, kind);

/** The game kind of a map POI, or null (unrelated, or a sanctuary). */
export function placeKindOf(cls: unknown, subclass: unknown): PlaceKind | null {
  const words = [cls, subclass].filter((x): x is string => typeof x === 'string').map((x) => x.toLowerCase());
  if (words.some((w) => SANCTUARY_WORDS.has(w))) return null;
  for (const w of words) {
    const k = KIND_OF.get(w);
    if (k) return k;
  }
  return null;
}

/** Stable key: the OSM feature id when the tile has one, else a hash of the rounded coordinates. */
function keyOf(id: unknown, lat: number, lon: number): string {
  if ((typeof id === 'number' && Number.isFinite(id)) || (typeof id === 'string' && /^[A-Za-z0-9_-]{1,30}$/.test(id))) return 'o' + String(id);
  return `c${Math.round(lat * 1e5)}_${Math.round(lon * 1e5)}`;
}

/**
 * Game-relevant POIs within 400 m of `at`, from the vector tiles the map has already loaded.
 * Deduped (a place on a tile edge appears in both tiles), nearest first, at most 40.
 */
export function collectPlaces(map: MlMap, at: { lat: number; lon: number }): PlaceReport[] {
  if (!map.getSource(SRC)) return [];
  const seen = new Map<string, PlaceReport & { d: number }>();
  for (const f of map.querySourceFeatures(SRC, { sourceLayer: 'poi' })) {
    if (f.geometry.type !== 'Point') continue;
    const props = f.properties ?? {};
    const kind = placeKindOf(props.class, props.subclass);
    if (!kind) continue;
    const [lon, lat] = f.geometry.coordinates;
    const d = haversine(at, { lat, lon });
    if (d > PLACE_RADIUS_M) continue;
    const key = keyOf(f.id, lat, lon);
    if (seen.has(key)) continue;
    const raw = props.name ?? props['name:latin'] ?? props.name_en;
    const name = typeof raw === 'string' ? raw.trim().slice(0, 48) : '';
    seen.set(key, { key, kind, lat, lon, ...(name ? { name } : {}), d });
  }
  return [...seen.values()].sort((a, b) => a.d - b.d).slice(0, PLACE_MAX).map(({ d: _d, ...p }) => p);
}
