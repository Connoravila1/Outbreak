import { signal } from '@preact/signals';
import { storage } from '../api/storage';

const read = (k: string, d: number) => {
  const v = parseFloat(storage.get(k) ?? '');
  return Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : d;
};

const K_MUSIC = 'outbreak.vol.music';
const K_FX = 'outbreak.vol.effects';

/** 0..1. Music also governs the map ambience. */
export const musicVol = signal(read(K_MUSIC, 0.8));
/** 0..1. Everything else: interface, combat, rewards, alarms. */
export const effectsVol = signal(read(K_FX, 0.9));

export function setMusicVol(v: number) { musicVol.value = v; storage.set(K_MUSIC, String(v)); }
export function setEffectsVol(v: number) { effectsVol.value = v; storage.set(K_FX, String(v)); }
