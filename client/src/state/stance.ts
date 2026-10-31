import { signal } from '@preact/signals';
import type { Faction, Stance } from '../api';
import { KEYS, storage } from '../api/storage';
import { catalog, me } from './store';

export const STANCES: Stance[] = ['aggressive', 'careful', 'evasive'];

const FALLBACK_NAME: Record<Stance, Record<Faction, string>> = {
  aggressive: { human: 'Aggressive', zombie: 'frenzy' },
  careful: { human: 'Careful', zombie: 'stalk' },
  evasive: { human: 'Evasive', zombie: 'slink' },
};

const asStance = (v: string | null): Stance | null => (v === 'aggressive' || v === 'careful' || v === 'evasive' ? v : null);

/** What the player picked last time (the server default is careful). */
export const lastStance = signal<Stance>(asStance(storage.get(KEYS.stance)) ?? 'careful');

export function chooseStance(s: Stance) {
  lastStance.value = s;
  storage.set(KEYS.stance, s);
}

/** Faction-voiced name, from the catalog when it has one. */
export function stanceName(s: Stance, f: Faction): string {
  return catalog.value?.stances?.find((x) => x.id === s)?.names[f] ?? FALLBACK_NAME[s][f];
}

/** Effect text of a stance, from the catalog. */
export function stanceText(s: Stance): string {
  return catalog.value?.stances?.find((x) => x.id === s)?.text ?? '';
}

/** Fights needed against an enemy type before the game tells you how to beat it. */
export const HINT_FIGHTS = 3;

/** The one-line hint for an archetype, once it has been fought enough times (else null). */
export function stanceHint(archetype: string, f: Faction): string | null {
  const fought = me.value?.bestiary?.[archetype] ?? 0;
  if (fought < HINT_FIGHTS) return null;
  const e = catalog.value?.enemies.find((x) => x.id === archetype);
  const line = f === 'zombie' ? e?.hint_zombie : e?.hint;
  return line || null;
}
