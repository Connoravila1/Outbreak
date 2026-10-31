import type { Faction, WorldView } from '../api';
import type { IconName } from '../ui/Icon';
import { catalog } from './store';

export type ObjectKind = 'enemy' | 'cache' | 'airdrop' | 'echo' | 'stronghold' | 'raid';

export interface GameObject {
  id: string;
  kind: ObjectKind;
  lat: number;
  lon: number;
  level: number | null;
  elite: boolean;
  rogue: boolean;
  /** Plain display name ("Shambler", "Supply crate"). */
  name: string;
  icon: IconName;
  expiresAt: number | null;
  detail: string | null;
  /** Catalog flavour text (enemies) and its short tag, in the viewer's voice. */
  lore: string | null;
  note: string | null;
  tutorial: boolean;
  raw: unknown;
}

export const ARCH_ICON: Record<string, IconName> = {
  shambler: 'shambling-zombie', runner: 'sprint', bloater: 'biohazard', brute: 'fist',
  horde: 'shambling-zombie', screamer: 'screaming', abomination: 'skull-crack',
  scavenger: 'swap-bag', scout: 'sprint', barricader: 'barricade', soldier: 'rifle',
  raider_gang: 'swords-emblem', raider: 'swords-emblem', medic: 'heart-plus', warlord: 'skull-crack',
};

export function archetypeName(id: string, f: Faction): string {
  const e = catalog.value?.enemies.find((x) => x.id === id);
  if (e) return e.names[f];
  return id.replace(/_/g, ' ').replace(/^./, (c) => c.toUpperCase());
}

export function objectsFrom(w: WorldView, f: Faction): GameObject[] {
  const base = { level: null, elite: false, rogue: false, expiresAt: null, detail: null, lore: null, note: null, tutorial: false } as const;
  const out: GameObject[] = [];
  for (const e of w.enemies) {
    const cat = catalog.value?.enemies.find((x) => x.id === e.archetype);
    const lore = cat ? (f === 'zombie' ? cat.text_zombie ?? cat.text : cat.text) : null;
    out.push({ ...base, lore, note: cat?.note ?? null, tutorial: !!e.tutorial, id: e.id, kind: 'enemy', lat: e.lat, lon: e.lon, level: e.level, elite: e.elite, name: archetypeName(e.archetype, f), icon: ARCH_ICON[e.archetype] ?? 'target-dummy', expiresAt: e.expires_at, raw: e });
  }
  for (const c of w.caches) {
    const air = c.kind === 'airdrop';
    out.push({ ...base, id: c.id, kind: c.kind, lat: c.lat, lon: c.lon, name: air ? 'Airdrop' : f === 'human' ? 'Supply crate' : 'Fresh remains', icon: air ? 'parachute' : f === 'human' ? 'cardboard-box-closed' : 'meat', expiresAt: c.expires_at, raw: c });
  }
  for (const e of w.echoes) {
    out.push({ ...base, id: e.id, kind: 'echo', lat: e.lat, lon: e.lon, level: e.level, rogue: e.rogue, name: `${e.rogue ? 'Rogue' : 'Echo'} ${e.faction === 'human' ? 'Human' : 'Zombie'}`, icon: 'ghost', detail: e.title, expiresAt: e.expires_at, raw: e });
  }
  for (const s of w.strongholds) {
    out.push({ ...base, id: s.id, kind: 'stronghold', lat: s.lat, lon: s.lon, name: s.clan ? `Stronghold [${s.clan.tag}]` : 'Stronghold', icon: 'castle', detail: s.clan ? s.clan.name : null, raw: s });
  }
  for (const r of w.raids) {
    out.push({ ...base, id: r.id, kind: 'raid', lat: r.lat, lon: r.lon, name: r.boss, icon: 'skull-crack', elite: true, expiresAt: r.ends_at, detail: `${r.hp.toLocaleString()} / ${r.max_hp.toLocaleString()} HP, ${r.fighters} fighting`, raw: r });
  }
  return out;
}

export const INTERACT_RANGE_M = 50;
export const VIEW_RANGE_M = 450;
