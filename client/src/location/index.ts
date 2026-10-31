import { effect, signal } from '@preact/signals';
import { appActive } from '../native/active';
import { KEYS, storage } from '../api/storage';
import { RealSource } from './real';
import { SimSource } from './sim';
import { NativeSource, requestNativeLocationPermission } from './native';
import { isNative } from '../native/platform';
import type { Fix } from './geo';
import type { LocationSource } from './source';

export * from './geo';
export { PRESETS, WALK_SPEED, RUN_SPEED } from './sim';
export { getOnce } from './real';
export { requestNativeLocationPermission } from './native';

/** Wide pointer-driven viewports get the simulator by default; phones use real GPS. */
export function isDesktop(): boolean {
  if (isNative) return false;
  return window.matchMedia('(min-width: 900px) and (pointer: fine)').matches;
}

export const sim = new SimSource();
export const real = isNative ? new NativeSource() : new RealSource();

const stored = storage.get(KEYS.simActive);
export const simActive = signal<boolean>(isNative ? false : stored == null ? isDesktop() : stored === '1');
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

/** Native builds never simulate. Browsers prompt on first watch; native asks explicitly first. */
export async function requestLocationPermission(): Promise<boolean> {
  if (!isNative) return true;
  return (await requestNativeLocationPermission()) === 'granted';
}

export function setSimActive(on: boolean) {
  if (isNative) return;
  simActive.value = on;
  storage.set(KEYS.simActive, on ? '1' : '0');
  position.value = null;
  startLocation();
}

// GPS is the biggest drain: the real watch runs only while the app is in the foreground (Patrol has its
// own native service). The simulator is cheap and keeps going.
effect(() => {
  const on = appActive.value;
  if (!active || active === sim) return;
  if (on) active.start(); else active.stop();
});
