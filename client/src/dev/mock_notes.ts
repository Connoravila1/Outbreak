// The mock server's notes (GET /api/notes, claims, drops). The text is the real thing: see mock_notes_data.ts.
import type { ArchiveNote, Faction, NoteArchive, NoteRef, Rarity } from '../api';
import { MOCK_NOTES, MOCK_SETS, type MockNote } from './mock_notes_data';

export interface Held { id: string; at: number }

const VALUE: Record<Rarity, number> = { common: 10, uncommon: 20, rare: 40, legendary: 100 };
const WEIGHT: Record<Rarity, number> = { common: 10, uncommon: 6, rare: 3, legendary: 1.5 };

export const FIRST_BLOOD_NOTE = 'starlite.04';

const sees = (setId: string, f: Faction) => {
  const a = MOCK_SETS.find((s) => s.id === setId)!.audience;
  return a === 'both' || a === f;
};
const visible = (f: Faction) => MOCK_NOTES.filter((n) => sees(n.set, f));
const setNotes = (id: string) => MOCK_NOTES.filter((n) => n.set === id);
const setReward = (id: string) => setNotes(id).reduce((a, n) => a + VALUE[n.rarity], 0);

export const visibleTotal = (f: Faction) => visible(f).length;
export const titlesFor = (claimed: string[]) => claimed.map((c) => MOCK_SETS.find((s) => s.id === c)!.title);

export function refOf(n: MockNote): NoteRef {
  return { id: n.id, title: n.title, set: n.set, rarity: n.rarity, form: n.form };
}
export const noteNamed = (id: string) => MOCK_NOTES.find((n) => n.id === id);

/** Patient Zero opens once half of the rest is held. */
function zeroOpen(f: Faction, held: Held[]) {
  const rest = visible(f).filter((n) => n.set !== 'zero');
  return rest.filter((n) => held.some((h) => h.id === n.id)).length >= rest.length / 2;
}

/** A note from `chance`, or null. Never one already held, never one the faction cannot read. */
export function rollNote(f: Faction, held: Held[], chance: number, allowZero: boolean): NoteRef | null {
  if (Math.random() >= chance) return null;
  const pool = visible(f).filter((n) => !held.some((h) => h.id === n.id) && n.set !== 'road' && (n.set !== 'zero' || (allowZero && zeroOpen(f, held))));
  if (!pool.length) return null;
  let x = Math.random() * pool.reduce((a, n) => a + WEIGHT[n.rarity], 0);
  for (const n of pool) { x -= WEIGHT[n.rarity]; if (x < 0) return refOf(n); }
  return refOf(pool[pool.length - 1]);
}

export function archiveFor(f: Faction, held: Held[], claimed: string[]): NoteArchive {
  const at = new Map(held.map((h) => [h.id, h.at]));
  return {
    sets: MOCK_SETS.filter((s) => sees(s.id, f)).map((s) => {
      const found = setNotes(s.id).filter((n) => at.has(n.id)).length;
      const sealed = s.id === 'zero' && found === 0;
      return { id: s.id, name: sealed ? '???' : s.name, title: sealed ? '???' : s.title, blurb: sealed ? '' : s.blurb, total: setNotes(s.id).length, found, reward: setReward(s.id), claimed: claimed.includes(s.id) };
    }),
    notes: visible(f).map((n): ArchiveNote => at.has(n.id)
      ? { id: n.id, set: n.set, rarity: n.rarity, locked: false, title: n.title, author: n.author, date: n.date, form: n.form, body: n.body, found_at: at.get(n.id)! }
      : { id: n.id, set: n.set, rarity: n.rarity, locked: true, title: null, author: null, date: null, form: null, body: null, found_at: null }),
  };
}

/** The salvage a completed, unclaimed set pays; null when it cannot be claimed. */
export function claimable(f: Faction, held: Held[], claimed: string[], set: string): { salvage: number; title: string } | null {
  const s = MOCK_SETS.find((x) => x.id === set);
  if (!s || !sees(set, f) || claimed.includes(set)) return null;
  if (!setNotes(set).every((n) => held.some((h) => h.id === n.id))) return null;
  return { salvage: setReward(set), title: s.title };
}

export const allVisibleIds = (f: Faction) => visible(f).map((n) => n.id);
