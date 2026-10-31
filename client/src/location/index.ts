import { signal } from '@preact/signals';
import { KEYS, storage } from '../api/storage';
import { RealSource } from './real';
import { SimSource } from './sim';
import type { Fix } from './geo';
import type { LocationSource } from './source';

export * from './geo';
export { PRESETS, WALK_SPEED, RUN_SPEED } from './sim';
export { getOnce } from './real';

/** Wide pointer-driven viewports get the simulator by default; phones use real GPS. */
export function isDesktop(): boolean {
  return window.matchMedia('(min-width: 900px) and (pointer: fine)').matches;
}

export const sim = new SimSource();
export const real = new RealSource();

const stored = storage.get(KEYS.simActive);
export const simActive = signal<boolean>(stored == null ? isDesktop() : stored === '1');
/** Latest fix from the active source. */
export const position = signal<Fix | null>(null);
export const locationError = signal<string | null>(null);
/** Bumps on every sim change so the panel re-renders (target, speed). */
export const simTick = signal(0);
sim.onChange = () => { simTick.value++; };

let active: LocationSource | null = null;
let unsub: (() => void) | null = null;

export function activeSource(): LocationSource { return simActive.value ? sim : real; }

/** (Re)bind to whichever source is selected. Call once at boot and whenever the toggle flips. */
export function startLocation() {
  unsub?.();
  active?.stop();
  active = activeSource();
  unsub = active.subscribe(
    (fix) => { position.value = fix; locationError.value = null; },
    (msg) => { locationError.value = msg; },
  );
  active.start();
}

export function setSimActive(on: boolean) {
  simActive.value = on;
  storage.set(KEYS.simActive, on ? '1' : '0');
  position.value = null;
  startLocation();
}
