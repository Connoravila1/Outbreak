import { signal } from '@preact/signals';
import type { Battle } from '../api';
import { storage } from '../api/storage';

const KEY = 'outbreak.record';

/** Lifetime tallies kept on this device (the server does not expose a record yet). */
export interface Record_ { wins: number; losses: number; contacts: number; echoes: number; caches: number }
const empty: Record_ = { wins: 0, losses: 0, contacts: 0, echoes: 0, caches: 0 };

export const record = signal<Record_>({ ...empty, ...storage.getJSON<Partial<Record_>>(KEY, {}) });

function bump(f: (r: Record_) => void) {
  const r = { ...record.peek() };
  f(r);
  record.value = r;
  storage.setJSON(KEY, r);
}

const COACH_KEY = 'outbreak.coach.first';
/** The one-time "your first one" hint over the map; gone after the first PvE win. */
export const coachDone = signal<boolean>(storage.get(COACH_KEY) === '1');
function endCoach() { if (!coachDone.peek()) { coachDone.value = true; storage.set(COACH_KEY, '1'); } }

export function recordBattle(b: Battle, contact: boolean) {
  if (b.winner === 'a' && b.kind === 'pve') endCoach();
  bump((r) => {
    if (b.winner === 'a') r.wins++; else r.losses++;
    if (contact || b.kind === 'pvp') r.contacts++;
    if (b.kind === 'echo') r.echoes++;
  });
}
export function recordCache() { bump((r) => { r.caches++; }); }
