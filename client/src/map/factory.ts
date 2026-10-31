import * as maplibregl from 'maplibre-gl';
import type { Map as MlMap, StyleSpecification } from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import workerUrl from 'maplibre-gl/dist/maplibre-gl-worker.mjs?url';
import type { Lens } from '../state/store';
import { installPatterns } from './patterns';
import { heatStyle } from './styles/heat';
import { neutralStyle } from './styles/neutral';
import { surveyStyle } from './styles/survey';

// Bundlers do not emit maplibre's worker on their own; point it at an explicit asset.
maplibregl.setWorkerUrl(new URL(workerUrl, location.href).href);

export function styleFor(lens: Lens, lat: number): StyleSpecification {
  return lens === 'survey' ? surveyStyle(lat) : lens === 'heat' ? heatStyle(lat) : neutralStyle();
}

export interface MapOpts {
  lens: Lens;
  center: { lat: number; lon: number };
  zoom?: number;
  interactive?: boolean;
  attribution?: boolean;
}

export function createMap(container: HTMLElement, o: MapOpts): MlMap {
  const map = new maplibregl.Map({
    container,
    style: styleFor(o.lens, o.center.lat),
    center: [o.center.lon, o.center.lat],
    zoom: o.zoom ?? 16.3,
    minZoom: 12,
    maxZoom: 19.5,
    interactive: o.interactive ?? true,
    attributionControl: false,
    pitchWithRotate: false,
    dragRotate: false,
    touchPitch: false,
    fadeDuration: 150,
  });
  map.touchZoomRotate.disableRotation();
  if (o.attribution !== false) {
    map.addControl(new maplibregl.AttributionControl({ compact: true, customAttribution: '© OpenStreetMap contributors' }), 'bottom-left');
    // start collapsed (the "i" button); it stays one tap away
    const a = container.querySelector('.maplibregl-ctrl-attrib');
    a?.classList.remove('maplibregl-compact-show');
    a?.removeAttribute('open');
  }
  installPatterns(map);
  return map;
}

export function setLens(map: MlMap, lens: Lens, lat: number) {
  map.setStyle(styleFor(lens, lat));
}

export { maplibregl };
