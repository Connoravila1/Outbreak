import { useEffect, useRef } from 'preact/hooks';
import { signal, useSignalEffect } from '@preact/signals';
import type { Map as MlMap, Marker } from 'maplibre-gl';
import { createMap, maplibregl, setLens } from './factory';
import { MarkerLayer, setClasses } from './markers';
import { gameMap } from './instance';
import { metresToPx } from './styles/common';
import { position, sim, simActive, simTick } from '../location';
import { faction, lens, me, world } from '../state/store';
import { capLandmarks, objectsFrom } from '../state/objects';

export const follow = signal(true);
export const selectedId = signal<string | null>(null);
const select = (id: string) => { selectedId.value = id; };

/** The in-game map: lens-styled, with you, the world's markers, and (on desktop) click-to-walk. */
export function GameMap() {
  const host = useRef<HTMLDivElement>(null);
  const layer = useRef<MarkerLayer | null>(null);
  const youMk = useRef<Marker | null>(null);
  const targetMk = useRef<Marker | null>(null);
  const mapRef = useRef<MlMap | null>(null);
  const ring = useRef<HTMLDivElement | null>(null);

  const sizeRing = () => {
    const m = mapRef.current;
    const p = position.peek();
    if (!m || !p || !ring.current) return;
    const px = metresToPx(50, m.getZoom(), p.lat) * 2;
    
    ring.current.style.width = ring.current.style.height = `${Math.max(24, px)}px`;
  };

  // create once a first position exists
  useSignalEffect(() => {
    const p = position.value;
    if (!p || mapRef.current || !host.current) return;
    const map = createMap(host.current, { lens: lens.peek(), center: p });
    mapRef.current = map;
    gameMap.value = map;
    layer.current = new MarkerLayer(map);
    const el = document.createElement('div');
    el.className = `you you-${lens.peek()}`;
    el.innerHTML = '<div class="you-ring"></div><div class="you-dot"></div>';
    ring.current = el.querySelector('.you-ring');
    youMk.current = new maplibregl.Marker({ element: el, pitchAlignment: 'map' }).setLngLat([p.lon, p.lat]).addTo(map);
    map.on('zoom', sizeRing);
    const tidy = () => layer.current?.declutter(position.peek(), selectedId.peek());
    map.on('zoomend', tidy);
    map.on('moveend', tidy);
    map.on('dragstart', () => { follow.value = false; });
    map.on('click', (e) => {
      selectedId.value = null;
      if (simActive.peek()) sim.walkTo({ lat: e.lngLat.lat, lon: e.lngLat.lng });
    });
    map.once('load', sizeRing);
    sizeRing();
  });

  // lens change
  useSignalEffect(() => {
    const l = lens.value;
    const m = mapRef.current;
    const p = position.peek();
    if (!m || !p) return;
    setLens(m, l, p.lat);
    const el = youMk.current?.getElement();
    if (el) setClasses(el, `you you-${l}`);
  });

  // follow the player
  useSignalEffect(() => {
    const p = position.value;
    const m = mapRef.current;
    if (!p || !m) return;
    youMk.current?.setLngLat([p.lon, p.lat]);
    if (follow.value) m.easeTo({ center: [p.lon, p.lat], duration: 600, essential: false });
    sizeRing();
  });

  // recenter when follow is turned back on
  useSignalEffect(() => {
    const on = follow.value;
    const p = position.peek();
    if (on && p) mapRef.current?.easeTo({ center: [p.lon, p.lat], zoom: 16.3, duration: 450 });
  });

  // walk-to target marker
  useSignalEffect(() => {
    void simTick.value;
    const m = mapRef.current;
    if (!m) return;
    const t = simActive.value ? sim.target : null;
    if (!t) { targetMk.current?.remove(); targetMk.current = null; return; }
    if (!targetMk.current) {
      const el = document.createElement('div');
      el.className = 'walk-target';
      targetMk.current = new maplibregl.Marker({ element: el }).setLngLat([t.lon, t.lat]).addTo(m);
    } else targetMk.current.setLngLat([t.lon, t.lat]);
  });

  // game markers
  useSignalEffect(() => {
    const w = world.value;
    const f = faction.value;
    const l = lens.value;
    const sel = selectedId.value;
    const lvl = me.value?.level ?? 1;
    if (!layer.current) return;
    layer.current.sync(w && f ? capLandmarks(objectsFrom(w, f), position.peek(), sel) : [], { lens: l, myLevel: lvl, selectedId: sel, onSelect: select });
    layer.current.declutter(position.peek(), sel);
  });

  useEffect(() => () => {
    layer.current?.clear();
    mapRef.current?.remove();
    mapRef.current = null;
    gameMap.value = null;
  }, []);

  return (
    <div class="mapwrap">
      <div class="gamemap" ref={host} role="application" aria-label="Map of your surroundings" />
      {!position.value && <p class="map-wait voice">{lens.value === 'heat' ? 'finding you…' : 'Waiting for a location fix.'}</p>}
    </div>
  );
}
