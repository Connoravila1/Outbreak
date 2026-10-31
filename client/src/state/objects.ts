import type { Faction, PlaceKind, WorldView } from '../api';
import type { IconName } from '../ui/Icon';
import { catalog } from './store';
import { haversine, type LatLon } from '../location/geo';

export type ObjectKind = 'enemy' | 'cache' | 'airdrop' | 'echo' | 'stronghold' | 'raid' | 'landmark';

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

export const PLACE_ICON: Record<PlaceKind, IconName> = {
  pharmacy: 'medical-pack', grocery: 'shopping-cart', hardware: 'hammer-nails', fuel: 'gas-pump',
  police: 'police-badge', outfitter: 'shirt', diner: 'knife-fork',
};

const PLACE_FALLBACK: Record<PlaceKind, [string, string]> = {
  pharmacy: ['Pharmacy', 'Sick Ward'], grocery: ['Grocery', 'Larder'], hardware: ['Hardware Store', 'Scrap Heap'],
  fuel: ['Gas Station', 'Fume Pit'], police: ['Police Station', 'Barracks'], outfitter: ['Outfitter', 'Shed Skins'],
  diner: ['Diner', 'Feeding Ground'],
};

/** "Pharmacy" for Humans, "Sick Ward" for Zombies. */
export function placeKindName(kind: PlaceKind, f: Faction): string {
  return catalog.value?.places?.find((x) => x.id === kind)?.names[f] ?? PLACE_FALLBACK[kind][f === 'zombie' ? 1 : 0];
}

/** What a kind of place tends to hold, in the viewer's voice. */
export function placeTendsTo(kind: PlaceKind, f: Faction): string | null {
  const p = catalog.value?.places?.find((x) => x.id === kind);
  return p ? (f === 'zombie' ? p.text_zombie : p.text) : null;
}

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
  for (const l of w.landmarks ?? []) {
    const kind = placeKindName(l.kind, f);
    out.push({ ...base, id: l.id, kind: 'landmark', lat: l.lat, lon: l.lon, name: l.name ?? kind, icon: PLACE_ICON[l.kind], detail: kind, raw: l });
  }
  for (const s of w.strongholds) {
    out.push({ ...base, id: s.id, kind: 'stronghold', lat: s.lat, lon: s.lon, name: s.clan ? `Stronghold [${s.clan.tag}]` : 'Stronghold', icon: 'castle', detail: s.clan ? s.clan.name : null, raw: s });
  }
  for (const r of w.raids) {
    out.push({ ...base, id: r.id, kind: 'raid', lat: r.lat, lon: r.lon, name: r.boss, icon: 'skull-crack', elite: true, expiresAt: r.ends_at, detail: `${r.hp.toLocaleString()} / ${r.max_hp.toLocaleString()} HP, ${r.fighters} fighting`, raw: r });
  }
  return out;
}

/** Downtown can report dozens of places at once; show only the closest few so enemies stay readable. */
export const MAX_LANDMARKS_SHOWN = 8;
/** A place closer than this to one already shown is left off, so a row of shops is one marker, not a pile. */
export const LANDMARK_SPACING_M = 45;

export function capLandmarks(objs: GameObject[], at: LatLon | null, keepId: string | null): GameObject[] {
  if (!at) return objs;
  const marks = objs.filter((o) => o.kind === 'landmark').sort((a, b) => haversine(at, a) - haversine(at, b));
  const kept: GameObject[] = marks.filter((o) => o.id === keepId);
  for (const o of marks) {
    if (kept.length >= MAX_LANDMARKS_SHOWN) break;
    if (o.id !== keepId && kept.every((k) => haversine(k, o) >= LANDMARK_SPACING_M)) kept.push(o);
  }
  const keep = new Set(kept.map((o) => o.id));
  return objs.filter((o) => o.kind !== 'landmark' || keep.has(o.id));
}

export const INTERACT_RANGE_M = 50;
export const VIEW_RANGE_M = 450;
