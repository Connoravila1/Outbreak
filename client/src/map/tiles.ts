// Where the map's vector tiles come from. By default OpenFreeMap; a self-hosted server can advertise
// a PMTiles archive in /api/health (`tiles`), which MapLibre then reads through the pmtiles protocol.
import * as maplibregl from 'maplibre-gl';
import { Protocol } from 'pmtiles';
import { api, getServerUrl } from '../api';
import type { TilesAdvert } from '../api/types';

export const OPENFREEMAP_TILEJSON = 'https://tiles.openfreemap.org/planet';
export const OPENFREEMAP_GLYPHS = 'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf';

export interface TileSource { url: string; glyphs: string }

let current: TileSource = { url: OPENFREEMAP_TILEJSON, glyphs: OPENFREEMAP_GLYPHS };
let protocolAdded = false;

/** Turn the server's advert into a TileJSON/PMTiles URL (paths are relative to the server address). */
export function resolveTiles(advert: TilesAdvert | null | undefined, base: string): TileSource {
  if (!advert?.pmtiles) return { url: OPENFREEMAP_TILEJSON, glyphs: OPENFREEMAP_GLYPHS };
  const abs = /^https?:\/\//i.test(advert.pmtiles) ? advert.pmtiles : `${base || location.origin}${advert.pmtiles}`;
  return { url: `pmtiles://${abs}`, glyphs: advert.glyphs || OPENFREEMAP_GLYPHS };
}

export function applyTiles(advert: TilesAdvert | null | undefined) {
  current = resolveTiles(advert, getServerUrl());
  if (current.url.startsWith('pmtiles://') && !protocolAdded) {
    maplibregl.addProtocol('pmtiles', new Protocol().tile);
    protocolAdded = true;
  }
}

/** The source the styles should use right now. */
export const tileSource = (): TileSource => current;

/** Ask the server which tiles to use; a failure keeps OpenFreeMap. Maps created afterwards pick it up. */
export async function loadTiles(): Promise<void> {
  try {
    const h = await api.health();
    applyTiles(h.tiles);
  } catch { /* keep the default */ }
}
