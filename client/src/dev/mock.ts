/*
 * TEMPORARY SCAFFOLDING. An in-browser stand-in for the Zig server so the UI can be exercised
 * before the real one exists. Enable with ?mock=1 (sticks in sessionStorage) or VITE_MOCK=1.
 * Delete this file (and the import in main.tsx) once the real server is the default. Nothing
 * here is authoritative game logic and the numbers are not from DESIGN.md's balance tables.
 */
import { setFetcher } from '../api/client';
import type {
  Battle, Catalog, ClanMessage, Combatant, Faction, GameEvent, Item, LeaderboardEntry, Me, Mission, PlaceReport, PlayerRecord, Rarity, Rewards, Slot, Stance, Stats, Turn, WorldView,
} from '../api/types';

const KEY = 'outbreak.mock.db';
const TOKEN = 'mock-token';
const RECOVERY = 'MOCK-7QX2-K9PD-41LA';
const TERMS_VERSION = 1;

// In transit, as the server decides it: over 7 m/s on two fixes in a row, for a minute past the last.
const transit = { lat: 0, lon: 0, at: 0, streak: 0, until: 0 };
function observeTransit(lat: number, lon: number): boolean {
  const now = Date.now();
  if (transit.at && now - transit.at < 120e3) {
    const dy = (lat - transit.lat) * 111_320, dx = (lon - transit.lon) * 111_320 * Math.cos((lat * Math.PI) / 180);
    const speed = Math.hypot(dx, dy) / Math.max(1, (now - transit.at) / 1000);
    if (speed > 7) { transit.streak++; if (transit.streak >= 2) transit.until = now + 60e3; } else transit.streak = 0;
  }
  Object.assign(transit, { lat, lon, at: now });
  return transit.until > now;
}
const inTransit = () => transit.until > Date.now();
/** Identities that "exist on the server" even after this device forgets them (survives account deletion of others). */
const IDKEY = 'outbreak.mock.identities';

export function mockRequested(): boolean {
  try {
    if (new URLSearchParams(location.search).get('mock') === '1') sessionStorage.setItem('outbreak.mock', '1');
    return sessionStorage.getItem('outbreak.mock') === '1' || import.meta.env.VITE_MOCK === '1';
  } catch {
    return import.meta.env.VITE_MOCK === '1';
  }
}

// ---------- deterministic noise ----------
function hash(...n: number[]): number {
  let h = 2166136261;
  for (const v of n) { h ^= v | 0; h = Math.imul(h, 16777619); h ^= h >>> 13; }
  return h >>> 0;
}
function rng(seed: number) {
  let s = seed >>> 0 || 1;
  return () => { s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0; return s / 4294967296; };
}

// ---------- catalog ----------
const names = (human: string, zombie: string) => ({ human, zombie });
const CATALOG: Catalog = {
  version: 1,
  achievements: MOCK_ACHIEVEMENTS,
  cosmetics: MOCK_COSMETICS,
  items: [
    { id: 'bat', slot: 'weapon', req: 1, names: names('Baseball Bat', 'Rotten Teeth'), stats: { hp: 0, atk: 7, def: 0, spd: 0 } },
    { id: 'knife', slot: 'weapon', req: 1, names: names('Kitchen Knife', 'Broken Nails'), stats: { hp: 0, atk: 5, def: 0, spd: 3 } },
    { id: 'crowbar', slot: 'weapon', req: 3, names: names('Crowbar', 'Bone Spur'), stats: { hp: 0, atk: 8, def: 2, spd: 0 } },
    { id: 'shotgun', slot: 'weapon', req: 8, names: names('Pump Shotgun', 'Gaping Maw'), stats: { hp: 0, atk: 14, def: 0, spd: -1 } },
    { id: 'katana', slot: 'weapon', req: 12, names: names('Katana', 'Razor Talons'), stats: { hp: 0, atk: 17, def: 0, spd: 4 } },
    { id: 'hoodie', slot: 'armor', req: 1, names: names('Hoodie', 'Torn Skin'), stats: { hp: 5, atk: 0, def: 3, spd: 1 } },
    { id: 'jacket', slot: 'armor', req: 1, names: names('Leather Jacket', 'Thick Hide'), stats: { hp: 8, atk: 0, def: 4, spd: 0 } },
    { id: 'riot_vest', slot: 'armor', req: 10, names: names('Riot Vest', 'Bone Plating'), stats: { hp: 20, atk: 0, def: 11, spd: -1 } },
    { id: 'flashlight', slot: 'utility', req: 1, names: names('Flashlight', 'Night Eyes'), stats: { hp: 0, atk: 0, def: 1, spd: 3 } },
    { id: 'backpack', slot: 'utility', req: 1, names: names('Backpack', 'Scavenger Gut'), stats: { hp: 10, atk: 0, def: 2, spd: 0 } },
    { id: 'jammer', slot: 'utility', req: 14, names: names('Signal Jammer', 'Mind Blight'), stats: { hp: 0, atk: 3, def: 3, spd: 9 } },
  ],
  uniques: [
    { id: 'old_faithful', base: 'bat', names: names('Old Faithful', 'The First Bite'), lore: 'Dad swore it never missed.', perks: ['brutal', 'lucky'] },
    { id: 'the_wall', base: 'riot_vest', names: names('The Wall', 'Ossuary'), lore: 'Eleven riots. Not one dent.', perks: ['sturdy', 'thorns'] },
  ],
  rarities: {},
  perks: [
    { id: 'keen', name: 'Keen', text: '+6% crit' }, { id: 'swift', name: 'Swift', text: '+8% SPD' }, { id: 'brutal', name: 'Brutal', text: '+8% ATK' },
    { id: 'sturdy', name: 'Sturdy', text: '+8% DEF' }, { id: 'vital', name: 'Vital', text: '+10% max HP' }, { id: 'leech', name: 'Leech', text: 'Heal 5% of damage dealt' },
    { id: 'thorns', name: 'Thorns', text: 'Reflect 8% of damage taken' }, { id: 'lucky', name: 'Lucky', text: '+15% loot chance' },
  ],
  consumables: [
    { id: 'heal_s', names: names('Bandage', 'Raw Meat'), text: 'Heal 25% max HP', price: 20 },
    { id: 'heal_m', names: names('First Aid Kit', 'Fresh Kill'), text: 'Heal 60% max HP', price: 50 },
    { id: 'revive', names: names('Trauma Kit', 'Mutagen Vial'), text: 'Revive from Downed at 100%, or full heal', price: 120 },
    { id: 'buff_atk', names: names('Adrenaline Shot', 'Rage Gland'), text: '+15% ATK for 30 min', price: 60 },
    { id: 'flag', names: names('Territory Flag', 'Infestation Marker'), text: 'Claim a Stronghold for your clan', price: 300 },
    { id: 'xp_token', names: names("Veteran's Logbook", 'Fresh Brain'), text: 'Gain as much XP as one standard win at your level. Found in caches, never sold.', price: 0 },
  ],
  avatar_looks: [
    { index: 0, level: 1, names: names('Standard issue', 'As it comes') }, { index: 1, level: 5, names: names('Scavenged scarf', 'Veined') },
    { index: 2, level: 10, names: names('Riot visor', 'Torn skin') }, { index: 3, level: 20, names: names('Field paint', 'Bared bone') },
    { index: 4, level: 30, names: names('Hardened kit', 'Fungal bloom') }, { index: 5, level: 35, names: names('Command coat', 'Burning eyes') },
    { index: 6, level: 50, names: names('Last Hope sash', 'Spore crown') },
  ],
  abilities: [
    { id: 'second_wind', level: 3, names: names('Second Wind', 'Devour'), text: 'Once per fight, below 35% HP, heal 30% max HP' },
    { id: 'aimed_shot', level: 7, names: names('Aimed Shot', 'Pounce'), text: 'Your first attack is a guaranteed crit' },
    { id: 'barricade', level: 12, names: names('Barricade', 'Calcify'), text: 'Take 35% less damage for the first 3 turns' },
    { id: 'molotov', level: 25, names: names('Molotov', 'Infectious Bite'), text: 'Your first hit burns: 5% of max HP per turn for 4 turns' },
  ],
  enemies: [
    { id: 'shambler', names: names('Shambler', 'Scavenger'), text: 'Slow, stupid, relentless. It falls apart and keeps coming.', text_zombie: 'Picks through the ruins for tins and boots. Wary, thin, armed with a pipe.', note: 'Common' },
    { id: 'runner', names: names('Runner', 'Scout'), text: 'Fast, loud and starving. You hear it before you see it.', text_zombie: 'Moves ahead of the group, watching the rooftops. Quick on its feet.', note: 'Fast' },
    { id: 'bloater', names: names('Bloater', 'Barricader'), text: 'Swollen and slow, a wall of rotten meat. Do not pop it.', text_zombie: 'Hides behind doors and bedsprings lashed to a shopping trolley.', note: 'Tanky' },
    { id: 'brute', names: names('Brute', 'Soldier'), text: 'Big, angry and hard to put down.', text_zombie: 'Armoured and drilled. Does not scare easily.', note: 'Strong' },
  ],
  levels: {
    xp_to_next: Array.from({ length: 50 }, (_, i) => Math.round((40 * Math.pow(i + 1, 1.55) + 30) / 10) * 10),
    titles: {
      human: ['Survivor', 'Forager', 'Defender', 'Ranger', 'Sentinel', 'Warden', 'Vanguard', 'Commander', 'Hero', 'Legend', 'Last Hope'],
      zombie: ['Turned', 'Lurcher', 'Lurker', 'Stalker', 'Ravager', 'Mauler', 'Alpha', 'Dread', 'Blight', 'Plaguebringer', 'Patient Zero'],
    },
    unlocks: [
      { level: 1, key: 'start', text: 'Starter kit, map, PvE, caches' },
      { level: 2, key: 'store', text: 'The Store' }, { level: 3, key: 'ability_slot_1', text: 'Ability slot 1 and your first ability' },
      { level: 4, key: 'upgrading', text: 'Item upgrading' }, { level: 5, key: 'contact', text: 'PvP protection ends: real-world fights begin' },
      { level: 5, key: 'missions', text: 'Weekly missions' }, { level: 5, key: 'echoes', text: 'Echoes' }, { level: 5, key: 'look_1', text: 'A new avatar look' },
      { level: 7, key: 'ability_7', text: 'New ability: Aimed Shot / Pounce' }, { level: 8, key: 'airdrops', text: 'Airdrops become visible' },
      { level: 10, key: 'clans', text: 'Clans' }, { level: 10, key: 'look_2', text: 'A new avatar look' }, { level: 12, key: 'ability_slot_2', text: 'Ability slot 2, and Barricade / Calcify' },
      { level: 15, key: 'territory', text: 'Territory: plant flags at Strongholds' }, { level: 18, key: 'ability_18', text: 'New ability: Adrenaline / Bloodlust' },
      { level: 20, key: 'raids', text: 'Raids' }, { level: 20, key: 'look_3', text: 'A new avatar look' },
      { level: 25, key: 'ability_slot_3', text: 'Ability slot 3, and Molotov / Infectious Bite' },
      { level: 30, key: 'legendary', text: 'Legendary drop rate +50%' }, { level: 30, key: 'look_4', text: 'A new avatar look' },
      { level: 35, key: 'look_5', text: 'A new avatar look' }, { level: 50, key: 'look_6', text: 'A new avatar look' },
    ],
  },
  store: [
    { sku: 'heal_s', name: 'Bandage', price: 20, text: 'Heal 25% max HP' },
    { sku: 'heal_m', name: 'First Aid Kit', price: 50, text: 'Heal 60% max HP' },
    { sku: 'revive', name: 'Trauma Kit', price: 120, text: 'Revive from Downed at 100%' },
    { sku: 'supply', name: 'Supply Requisition', price: 150, text: 'A random item of your level, Uncommon or better' },
    { sku: 'xp_boost', name: 'XP Boost', price: 200, text: '+50% XP for 1 hour' },
  ],
};

import { earnNew, freshCollection, MOCK_ACHIEVEMENTS, MOCK_COSMETICS, metricsOf, titlesFrom, type CollectionState } from './mock_collection';
import { allVisibleIds, archiveFor, claimable, FIRST_BLOOD_NOTE, noteNamed, refOf, rollNote, titlesFor, visibleTotal, type Held } from './mock_notes';

// ---------- database ----------
interface Clan { id: string; name: string; tag: string; faction: Faction; code: string; strongholds: number }
interface Ident { provider: string; subject: string; email: string | null }
interface DB {
  exists: boolean; ids: Ident[];
  callsign: string | null; avatar?: Record<string, unknown> | null; faction: Faction | null; level: number; xp: number; hp: number; salvage: number;
  items: Item[]; eq: Record<Slot, string | null>; consumables: Record<string, number>; abil: string[]; buffs: { kind: string; until: number }[];
  defeated: string[]; n: number; mprog: number[]; mclaimed: boolean[]; wprog: number; wclaimed: boolean; streak: number;
  clan: { id: string; role: string } | null; chat: ClanMessage[]; warPoints: number; feed: GameEvent[]; contactPending: boolean;
  userClans: Clan[];
  rec: PlayerRecord;
  stance?: Stance; bestiary?: Record<string, number>;
  notes?: Held[]; noteClaims?: string[];
  /** Moderation: a forced callsign change, reports sent (to dedupe), and a suspension. */
  mustRename?: boolean; reported?: string[]; banned?: { reason: string; until: number | null } | null;
  col?: CollectionState;
  /** The terms version accepted (0: none). */
  terms?: number;
}
function fresh(): DB {
  return {
    exists: false, ids: [], callsign: null, faction: null, level: 1, xp: 0, hp: 100, salvage: 0, items: [], eq: { weapon: null, armor: null, utility: null },
    consumables: {}, abil: [], buffs: [], defeated: [], n: 1, mprog: [1, 0, 240], mclaimed: [false, false, false], wprog: 0, wclaimed: false,
    streak: 2, clan: null, chat: [], warPoints: 0, feed: [], contactPending: false, userClans: [],
    rec: { wins: 0, losses: 0, contacts: 0, echoes: 0, caches: 0, distance_m: 0, contacts_won: 0, contacts_lost: 0, echoes_won: 0 },
  };
}
function load(): DB {
  try { const r = localStorage.getItem(KEY); if (r) return { ...fresh(), ...JSON.parse(r) }; } catch { /* ignore */ }
  return fresh();
}
let db = load();
const save = () => {
  try {
    localStorage.setItem(KEY, JSON.stringify(db));
    const v = vault();
    for (const i of db.ids) v[idKey(i)] = db;
    if (db.ids.length) putVault(v);
  } catch { /* ignore */ }
};

const maxHp = (l: number) => 100 + 14 * (l - 1);
const sum = (a: Stats, b: Stats): Stats => ({ hp: a.hp + b.hp, atk: a.atk + b.atk, def: a.def + b.def, spd: a.spd + b.spd });
const MULT: Record<Rarity, number> = { common: 1, uncommon: 1.2, rare: 1.45, legendary: 1.8 };
const RCOST: Record<Rarity, number> = { common: 1, uncommon: 1.3, rare: 1.7, legendary: 2.2 };
const SCRAP: Record<Rarity, number> = { common: 3, uncommon: 8, rare: 20, legendary: 50 };
const PERKS = ['keen', 'swift', 'brutal', 'sturdy', 'vital', 'leech', 'thorns', 'lucky'];

function finishItem(it: Item): Item {
  const c = CATALOG.items.find((i) => i.id === it.base)!;
  const m = MULT[it.rarity] * (1 + 0.04 * it.upgrade) * (it.unique ? 1.1 : 1);
  const k = (v: number) => Math.round(v * m);
  it.stats = { hp: k(c.stats.hp), atk: k(c.stats.atk), def: k(c.stats.def), spd: k(c.stats.spd) };
  it.power = it.stats.atk * 2 + it.stats.def * 2 + it.stats.spd + Math.round(it.stats.hp / 4);
  it.scrap_value = Math.round(SCRAP[it.rarity] * (1 + c.req / 10));
  it.upgrade_cost = it.upgrade >= 10 ? null : Math.round(8 * Math.pow(it.upgrade + 1, 1.6) * (1 + c.req / 10) * RCOST[it.rarity]);
  return it;
}

function makeItem(base: string, rarity: Rarity, upgrade = 0, unique: string | null = null): Item {
  const c = CATALOG.items.find((i) => i.id === base)!;
  const perks = unique ? CATALOG.uniques.find((u) => u.id === unique)!.perks
    : rarity === 'rare' ? [PERKS[(db.n * 3) % PERKS.length]] : rarity === 'legendary' ? [PERKS[(db.n * 3) % PERKS.length], PERKS[(db.n * 5 + 1) % PERKS.length]] : [];
  const col = collection();
  if (!col.bases.includes(base)) col.bases.push(base);
  if (unique && !col.uniques.includes(unique)) col.uniques.push(unique);
  if (!col.rarities.includes(rarity)) col.rarities.push(rarity);
  return finishItem({ uid: 'it' + db.n++, base, slot: c.slot, rarity, upgrade, perks, unique, req: c.req, stats: { hp: 0, atk: 0, def: 0, spd: 0 }, power: 0, scrap_value: 0, upgrade_cost: 0 });
}

const collection = (): CollectionState => db.col ?? (db.col = freshCollection());

/** Earn whatever is newly met: pays the salvage, lists it in `r`, and files it in the feed. */
function checkAchievements(r?: Rewards): void {
  const col = collection();
  col.bestUp = Math.max(col.bestUp ?? 0, ...db.items.map((i) => i.upgrade));
  const got = earnNew(col, db.faction ?? 'human', { distance_m: db.rec.distance_m, wins: db.rec.wins, contacts_won: db.rec.contacts_won ?? 0, echoes_won: db.rec.echoes_won ?? 0, caches: db.rec.caches, level: db.level, notes: (db.notes ?? []).length, sets: (db.noteClaims ?? []).length, bestUpgrade: col.bestUp }, Date.now());
  for (const a of got) {
    db.salvage += a.salvage;
    pushFeed('achievement', `${a.name}: +${a.salvage} salvage`, { rewards: { ...emptyRewards(), salvage: a.salvage, achievements: [a] } });
  }
  if (r && got.length) r.achievements = [...(r.achievements ?? []), ...got];
}

function equipped(): Record<Slot, string | null> {
  const e = { ...db.eq };
  for (const s of ['weapon', 'armor', 'utility'] as Slot[]) if (e[s] && !db.items.some((i) => i.uid === e[s])) e[s] = null;
  return e;
}

const slotsAt = (l: number) => (l >= 25 ? 3 : l >= 12 ? 2 : l >= 3 ? 1 : 0);

function emptyRewards(xp = 0): Rewards {
  return { xp, salvage: 0, items: [], consumables: {}, war_points: 0, level_up: null };
}

function missionList(): Mission[] {
  const xpn = CATALOG.levels.xp_to_next[db.level - 1];
  const defs: [string, string, string, number][] = [['d1', 'defeat', 'Defeat 5 enemies', 5], ['d2', 'cache', 'Open 2 caches', 2], ['d3', 'walk', 'Walk 1000 m', 1000]];
  return defs.map(([id, kind, text, target], i) => ({
    id, kind, text, target, progress: Math.min(target, db.mprog[i]), claimed: db.mclaimed[i],
    rewards: { ...emptyRewards(Math.round(xpn * 0.2)), salvage: 6 + i * 3 },
  }));
}
function weeklyMission(): Mission | null {
  if (db.level < 5) return null;
  const r = emptyRewards(Math.round(CATALOG.levels.xp_to_next[db.level - 1] * 0.5));
  r.salvage = 40;
  return { id: 'w1', kind: 'win', text: 'Win 3 Contacts or Echoes', target: 3, progress: Math.min(3, db.wprog), claimed: db.wclaimed, rewards: r };
}

/** The last /api/location said `mock: true` (a mock provider on the phone). */
let mockSimulated = false;

function buildMe(): Me {
  const base: Stats = { hp: maxHp(db.level), atk: 10 + 2 * (db.level - 1), def: 6 + 1.5 * (db.level - 1), spd: 10 + 0.6 * (db.level - 1) };
  const eq = equipped();
  let total = base;
  for (const uid of Object.values(eq)) { const it = db.items.find((i) => i.uid === uid); if (it) total = sum(total, it.stats); }
  const titles = CATALOG.levels.titles[db.faction ?? 'human'];
  const unlocked = CATALOG.abilities.filter((a) => a.level <= db.level).map((a) => a.id);
  const slots = slotsAt(db.level);
  const myClan = db.clan ? allClans().find((c) => c.id === db.clan!.id) : null;
  return {
    id: 'mock-1', callsign: db.callsign, must_rename: !!db.mustRename, faction: db.faction, level: db.level, xp: db.xp,
    xp_next: CATALOG.levels.xp_to_next[db.level - 1], token_xp: 20 + 6 * db.level, title: titles[Math.min(titles.length - 1, Math.floor(db.level / 5))],
    hp: Math.min(db.hp, total.hp), max_hp: total.hp, downed_until: null,
    stats: { hp: total.hp, atk: Math.round(total.atk), def: Math.round(total.def), spd: Math.round(total.spd) },
    base_stats: { hp: base.hp, atk: Math.round(base.atk), def: Math.round(base.def), spd: Math.round(base.spd) },
    salvage: db.salvage, inventory_cap: 30 + 2 * (db.level - 1), equipped: eq, items: db.items,
    consumables: db.consumables,
    abilities: { unlocked, equipped: db.abil.filter((a) => unlocked.includes(a)).slice(0, slots), slots },
    buffs: db.buffs.filter((b) => b.until > Date.now()),
    missions: { daily: missionList(), weekly: weeklyMission(), streak: db.streak, resets_at: Date.now() + 6 * 3600e3 + 1500e3 },
    clan: db.clan && myClan ? { id: myClan.id, name: myClan.name, tag: myClan.tag, role: db.clan.role } : null,
    avatar: db.avatar ?? null, pvp_protected: db.level < 5, underdog_bonus: 0.15, war_points_week: db.warPoints,
    record: { ...db.rec, contacts_won: db.rec.contacts_won ?? 0, contacts_lost: db.rec.contacts_lost ?? 0, echoes_won: db.rec.echoes_won ?? 0 },
    contact_rank: contactRank(db.faction ?? 'human', db.rec.contacts_won ?? 0),
    terms: { current: TERMS_VERSION, accepted: db.terms ?? 0, needs_accept: (db.terms ?? 0) < TERMS_VERSION },
    account: { guest: db.ids.length === 0, providers: db.ids.map((i) => i.provider), email: db.ids.find((i) => i.email)?.email ?? null },
    stance: db.stance ?? 'careful', bestiary: db.bestiary ?? {},
    notes: { found: (db.notes ?? []).length, total: visibleTotal(db.faction ?? 'human') },
    titles_extra: [...titlesFor(db.noteClaims ?? []), ...titlesFrom(collection(), db.faction ?? 'human')],
    cosmetics: { owned: collection().owned, color: collection().color, frame: collection().frame },
    achievements: { earned: collection().earned.length, total: MOCK_ACHIEVEMENTS.length },
    simulated_location: mockSimulated,
  };
}

const RANK_AT = [0, 1, 5, 15, 40, 100];
const RANK_NAMES: Record<Faction, string[]> = {
  human: ['Unbloodied', 'Blooded', 'Tracker', 'Veteran', 'Warden', 'Legend'],
  zombie: ['Unfed', 'Blooded', 'Stalker', 'Ravener', 'Apex', 'Legend'],
};
function contactRank(f: Faction, wins: number): Me['contact_rank'] {
  let tier = 0;
  RANK_AT.forEach((at, i) => { if (wins >= at) tier = i; });
  const last = tier + 1 >= RANK_AT.length;
  return { name: RANK_NAMES[f][tier], tier, wins, next_at: last ? null : RANK_AT[tier + 1], next_name: last ? null : RANK_NAMES[f][tier + 1] };
}

// ---------- world ----------
const CELL_M = 150;
const dims = (lat: number) => ({ dlat: CELL_M / 111320, dlon: CELL_M / (111320 * Math.cos((lat * Math.PI) / 180)) });
const ARCH = ['shambler', 'shambler', 'runner', 'bloater', 'brute'];

function enemiesIn(i: number, j: number, win: number, lat0: number) {
  const r = rng(hash(i, j, win, 7));
  const n = Math.floor(r() * 3.2);
  const { dlat, dlon } = dims(lat0);
  return Array.from({ length: n }, (_, k) => ({
    id: `e:${i}:${j}:${win}:${k}`, archetype: ARCH[Math.floor(r() * ARCH.length)],
    off: Math.floor(r() * 5) - 2, elite: r() < 0.08,
    lat: (i + 0.1 + r() * 0.8) * dlat, lon: (j + 0.1 + r() * 0.8) * dlon,
  }));
}
function cacheIn(i: number, j: number, win: number, lat0: number) {
  const r = rng(hash(i, j, win, 99));
  if (r() > 0.35) return null;
  const { dlat, dlon } = dims(lat0);
  return { id: `c:${i}:${j}:${win}`, lat: (i + 0.1 + r() * 0.8) * dlat, lon: (j + 0.1 + r() * 0.8) * dlon };
}

const PLACE_KINDS = ['pharmacy', 'grocery', 'hardware', 'fuel', 'police', 'outfitter', 'diner'];
/** Solar time: night is 20:00 to 06:00 at the player's longitude. */
function mockTime(now: number, lon: number): WorldView['time'] {
  const day = 86400e3, hour = 3600e3;
  const m = (((now + Math.round((lon / 15) * hour)) % day) + day) % day;
  const night = m >= 20 * hour || m < 6 * hour;
  const target = m < 6 * hour ? 6 * hour : m < 20 * hour ? 20 * hour : 30 * hour;
  return { phase: night ? 'night' : 'day', changes_at: now + (target - m) };
}

function world(lat: number, lon: number, places: PlaceReport[] = []): WorldView {
  const now = Date.now();
  const { dlat, dlon } = dims(lat);
  const ci = Math.floor(lat / dlat), cj = Math.floor(lon / dlon);
  const w10 = Math.floor(now / 600e3), w30 = Math.floor(now / 1800e3);
  const v: WorldView = { now, me: { simulated_location: mockSimulated, hp: db.hp, max_hp: buildMe().max_hp, downed_until: null, level: db.level, xp: db.xp, xp_next: CATALOG.levels.xp_to_next[db.level - 1], salvage: db.salvage }, hostiles_near: false, in_transit: false, enemies: [], caches: [], echoes: [], landmarks: [], time: mockTime(now, lon), strongholds: [], raids: [], events: [] };
  const win4h = Math.floor(now / (4 * 3600e3));
  for (const p of places.slice(0, 40)) {
    if (!PLACE_KINDS.includes(p.kind)) continue;
    const id = `l.${p.key}.${win4h}`;
    const used = db.defeated.includes(id);
    v.landmarks.push({ id, kind: p.kind, name: p.name ?? null, lat: p.lat, lon: p.lon, available: !used, available_at: used ? (win4h + 1) * 4 * 3600e3 : null });
  }
  const R = 3; // 450 m / 150 m
  for (let i = ci - R; i <= ci + R; i++) for (let j = cj - R; j <= cj + R; j++) {
    for (const e of enemiesIn(i, j, w10, lat)) {
      if (db.defeated.includes(e.id)) continue;
      v.enemies.push({ id: e.id, archetype: e.archetype, level: Math.max(1, db.level + (e.elite ? 3 : e.off)), elite: e.elite, tutorial: db.rec.wins === 0 && v.enemies.length === 0, lat: e.lat, lon: e.lon, expires_at: (w10 + 1) * 600e3 });
    }
    const c = cacheIn(i, j, w30, lat);
    if (c && !db.defeated.includes(c.id)) v.caches.push({ id: c.id, kind: 'cache', lat: c.lat, lon: c.lon, expires_at: (w30 + 1) * 1800e3 });
  }
  if (db.level >= 5) v.echoes.push({ id: `echo:${ci}:${cj}:${w30}`, level: db.level + 1, faction: db.faction === 'human' ? 'zombie' : 'human', title: 'Stalker', rogue: true, lat: (ci + 0.5) * dlat, lon: (cj + 1.4) * dlon, expires_at: (w30 + 1) * 1800e3 });
  v.hostiles_near = hash(ci, cj, w10) % 5 === 0;
  return v;
}

// ---------- fights ----------
function combatantMe(): Combatant {
  const m = buildMe();
  const f = m.faction ?? 'human';
  return {
    name: m.callsign ?? "You", faction: f, level: m.level, title: m.title, kind: 'player', archetype: null, max_hp: m.max_hp, hp_start: m.hp, stats: m.stats,
    abilities: m.abilities.equipped,
    gear: Object.values(m.equipped).filter(Boolean).map((uid) => { const it = m.items.find((i) => i.uid === uid)!; return it.unique ? CATALOG.uniques.find((u) => u.id === it.unique)!.names[f] : CATALOG.items.find((c) => c.id === it.base)!.names[f]; }),
    gear_detail: Object.values(m.equipped).filter(Boolean).map((uid) => {
      const it = m.items.find((i) => i.uid === uid)!;
      const name = it.unique ? CATALOG.uniques.find((u) => u.id === it.unique)!.names[f] : CATALOG.items.find((c) => c.id === it.base)!.names[f];
      return { slot: it.slot, name, rarity: it.rarity, upgrade: it.upgrade, unique: !!it.unique };
    }),
    stance: db.stance ?? 'careful',
  };
}

/** A small, honest imitation of the resolver: crits, dodges, two abilities, a burn. Not the real maths. */
function fight(foe: Combatant, seed: number): { turns: Turn[]; win: boolean } {
  const r = rng(seed);
  const me = combatantMe();
  let hpA = me.hp_start, hpB = foe.max_hp;
  const turns: Turn[] = [];
  const mine = new Set(me.abilities);
  const theirs = new Set(foe.abilities);
  let windUsed = false, firstA = true, firstB = true, burn = 0;
  const push = (actor: 'a' | 'b', ev: Turn['ev'], ability: string | null, dmg: number, heal: number) => turns.push({ actor, ev, ability, dmg, heal, hp_a: Math.round(hpA), hp_b: Math.round(hpB) });
  for (let t = 0; t < 30 && hpA > 0 && hpB > 0; t++) {
    if (burn > 0) { const d = Math.round(foe.max_hp * 0.05); hpB = Math.max(0, hpB - d); burn--; push('a', 'dot', 'molotov', d, 0); if (hpB <= 0) break; }
    for (const actor of ['a', 'b'] as const) {
      if (hpA <= 0 || hpB <= 0) break;
      const att = actor === 'a' ? me.stats : foe.stats;
      const def = actor === 'a' ? foe.stats : me.stats;
      if (actor === 'a' && mine.has('second_wind') && !windUsed && hpA / me.max_hp < 0.35) {
        windUsed = true;
        const h = Math.round(me.max_hp * 0.3);
        hpA = Math.min(me.max_hp, hpA + h);
        push('a', 'heal', 'second_wind', 0, h);
        continue;
      }
      const first = actor === 'a' ? firstA : firstB;
      const aimed = first && (actor === 'a' ? mine : theirs).has('aimed_shot');
      const dodge = !aimed && r() < 0.1;
      const crit = aimed || (!dodge && r() < 0.12);
      const dmg = dodge ? 0 : Math.max(1, Math.round(1.4 * att.atk ** 2 / (att.atk + def.def) * (0.85 + r() * 0.3) * (crit ? 1.6 : 1)));
      if (actor === 'a') { hpB = Math.max(0, hpB - dmg); firstA = false; } else { hpA = Math.max(0, hpA - dmg); firstB = false; }
      push(actor, dodge ? 'dodge' : crit ? 'crit' : 'hit', aimed ? 'aimed_shot' : null, dmg, 0);
      if (actor === 'a' && first && !dodge && mine.has('molotov')) burn = 4;
    }
  }
  return { turns, win: hpB <= 0 || (hpA > 0 && hpA / me.max_hp >= hpB / foe.max_hp) };
}

function grantXp(r: Rewards) {
  db.xp += r.xp;
  const from = db.level;
  while (db.xp >= CATALOG.levels.xp_to_next[db.level - 1] && db.level < 50) { db.xp -= CATALOG.levels.xp_to_next[db.level - 1]; db.level++; }
  if (db.level > from) {
    const unlocks = CATALOG.levels.unlocks.filter((u) => u.level > from && u.level <= db.level).map((u) => u.text);
    r.level_up = { from, to: db.level, unlocks };
  }
}

function lootRewards(xp: number, items: number, legendaryBias = 0): Rewards {
  const r = emptyRewards(xp);
  r.salvage = 3 + Math.floor(db.level / 2);
  db.salvage += r.salvage;
  const eligible = CATALOG.items.filter((c) => c.req <= db.level + 2);
  const drops = Math.random() < items ? (Math.random() < 0.3 ? 2 : 1) : 0;
  for (let i = 0; i < drops; i++) {
    const base = eligible[Math.floor(Math.random() * eligible.length)].id;
    const roll = Math.random() - legendaryBias;
    const rarity: Rarity = roll < 0.04 ? 'legendary' : roll < 0.16 ? 'rare' : roll < 0.45 ? 'uncommon' : 'common';
    const uq = rarity === 'legendary' ? CATALOG.uniques.find((u) => u.base === base)?.id ?? null : null;
    const it = makeItem(base, rarity, 0, uq);
    db.items.push(it);
    r.items.push(it);
  }
  if (Math.random() < 0.5) { db.consumables.heal_s = (db.consumables.heal_s ?? 0) + 1; r.consumables.heal_s = 1; }
  return r;
}

/** The rarer finds of a cache: an XP token now and then, and from an airdrop a found cosmetic (a repeat is salvage). */
function giveFinds(r: Rewards, airdrop: boolean) {
  if (Math.random() < (airdrop ? 0.16 : 0.1)) { db.consumables.xp_token = (db.consumables.xp_token ?? 0) + 1; r.consumables.xp_token = 1; }
  if (!airdrop || Math.random() >= 0.08) return;
  const pool = MOCK_COSMETICS.filter((c) => c.found);
  const c = pool[Math.floor(Math.random() * pool.length)];
  const col = collection();
  const duplicate = col.owned.includes(c.id);
  const salvage = duplicate ? (c.kind === 'color' ? 150 : 250) : 0;
  if (!duplicate) col.owned.push(c.id);
  db.salvage += salvage; r.salvage += salvage;
  r.cosmetics = [...(r.cosmetics ?? []), { id: c.id, kind: c.kind, duplicate, salvage }];
}

/** Hold a note (a given one, else a roll at `chance`) and list it in `r`. */
function giveNote(r: Rewards, id: string | null, chance: number, allowZero = false) {
  const held = db.notes ?? (db.notes = []);
  const n = id ? noteNamed(id) : null;
  const ref = n ? (held.some((h) => h.id === n.id) ? null : refOf(n)) : rollNote(db.faction ?? 'human', held, chance, allowZero);
  if (!ref) return;
  held.push({ id: ref.id, at: Date.now() });
  r.notes = [...(r.notes ?? []), ref];
}

function pushFeed(type: GameEvent['type'], text: string, extra: Partial<GameEvent> = {}): GameEvent {
  const ev: GameEvent = { id: 'ev' + db.n++, at: Date.now(), type, text, ...extra };
  db.feed = [ev, ...db.feed].slice(0, 50);
  return ev;
}

function resolve(foe: Combatant, kind: Battle['kind'], xpBase: number, warPts: number, bias = 0): Battle {
  const a = combatantMe();
  const { turns, win } = fight(foe, hash(db.n++, foe.level));
  const last = turns[turns.length - 1];
  db.hp = Math.max(1, last ? last.hp_a : db.hp);
  const rewards = win ? lootRewards(xpBase, 0.4, bias) : lootRewards(Math.round(xpBase * 0.25), 0);
  if (win) { rewards.war_points = warPts; db.warPoints += warPts; db.mprog[0]++; if (kind !== 'pve') db.wprog++; }
  if (kind === 'pvp') { db.rec.contacts_won = (db.rec.contacts_won ?? 0) + (win ? 1 : 0); db.rec.contacts_lost = (db.rec.contacts_lost ?? 0) + (win ? 0 : 1); }
  if (win) giveNote(rewards, db.rec.wins === 0 && kind === 'pve' ? FIRST_BLOOD_NOTE : null, kind === 'pve' ? 0.03 : 0);
  if (win) db.rec.wins++; else db.rec.losses++;
  if (kind === 'echo') { db.rec.echoes++; if (win) db.rec.echoes_won = (db.rec.echoes_won ?? 0) + 1; }
  grantXp(rewards);
  checkAchievements(rewards);
  save();
  return { id: 'b' + db.n, kind, a, b: foe, turns, winner: win ? 'a' : 'b', rewards, me: buildMe() };
}

function oppFaction(): Faction { return db.faction === 'human' ? 'zombie' : 'human'; }
const gearFor = (f: Faction, bases: string[]) => bases.map((b) => CATALOG.items.find((i) => i.id === b)!.names[f]);
/** A kit for a made-up opponent: one item per slot, rarities as given (a legendary wears its unique's name). */
function kitFor(f: Faction, bases: [string, Rarity, number][]): NonNullable<Combatant['gear_detail']> {
  return bases.map(([id, rarity, upgrade]) => {
    const c = CATALOG.items.find((i) => i.id === id)!;
    const uq = rarity === 'legendary' ? CATALOG.uniques.find((u) => u.base === id) : undefined;
    return { slot: c.slot, name: uq ? uq.names[f] : c.names[f], rarity, upgrade, unique: !!uq };
  });
}

function contactBattle(): Battle {
  const f = oppFaction();
  const lvl = Math.max(5, db.level - 2);
  const foe: Combatant = {
    name: f === 'zombie' ? 'A Zombie' : 'A Human', faction: f, level: lvl, title: CATALOG.levels.titles[f][Math.min(10, Math.floor(lvl / 5))], kind: 'player', archetype: null,
    max_hp: maxHp(lvl), hp_start: maxHp(lvl), stats: { hp: maxHp(lvl), atk: 11 + 2 * lvl, def: 7 + 1.5 * lvl, spd: 10 + 0.6 * lvl },
    abilities: lvl >= 7 ? ['aimed_shot'] : [], gear: gearFor(f, ['crowbar', 'jacket', 'flashlight']),
    gear_detail: kitFor(f, [['crowbar', 'rare', 3], ['jacket', 'uncommon', 1], ['flashlight', 'legendary', 0]]),
    stance: 'aggressive',
  };
  foe.stats = { hp: foe.max_hp, atk: Math.round(foe.stats.atk), def: Math.round(foe.stats.def), spd: Math.round(foe.stats.spd) };
  return resolve(foe, 'pvp', 60 + 10 * lvl, 10);
}

// ---------- clans ----------
const SEED_CLANS: Clan[] = [
  { id: 'cl1', name: 'Night Shift', tag: 'NITE', faction: 'human', code: 'NITE-4821', strongholds: 2 },
  { id: 'cl2', name: 'Last Light', tag: 'LAST', faction: 'human', code: 'LAST-1107', strongholds: 0 },
  { id: 'cl3', name: 'The Hollow Choir', tag: 'HOLO', faction: 'zombie', code: 'HOLO-9930', strongholds: 3 },
  { id: 'cl4', name: 'Rot Union', tag: 'ROT', faction: 'zombie', code: 'ROT-5512', strongholds: 1 },
];
const allClans = () => [...SEED_CLANS, ...db.userClans];
function clanDetail(c: Clan) {
  const f = c.faction;
  const roster = [
    { callsign: 'Marrow', level: 31, title: CATALOG.levels.titles[f][6], role: 'Leader', weekly_points: 212 },
    { callsign: 'Pike', level: 22, title: CATALOG.levels.titles[f][4], role: 'Officer', weekly_points: 148 },
    { callsign: 'Ness', level: 14, title: CATALOG.levels.titles[f][2], role: 'Member', weekly_points: 61 },
  ];
  if (db.clan?.id === c.id) roster.push({ callsign: db.callsign ?? 'You', level: db.level, title: buildMe().title, role: db.clan.role, weekly_points: db.warPoints });
  return { id: c.id, name: c.name, tag: c.tag, code: c.code, members: roster, strongholds: c.strongholds, perks: c.strongholds >= 3 ? { xp_bonus: 0.05 } : {} };
}
function seedChat() {
  if (db.chat.length) return;
  const now = Date.now();
  db.chat = [
    { id: 'm1', callsign: 'Marrow', text: 'Stronghold on 5th is open. Anyone near?', at: now - 3600e3 },
    { id: 'm2', callsign: 'Pike', text: 'On my way.', at: now - 3500e3 },
  ];
}

// ---------- accounts ----------
function checkCallsign(cs: string) {
  if (cs.length < 3 || cs.length > 16) throw new HttpError(400, 'callsign_invalid', 'Callsigns are 3 to 16 characters: letters, digits, _ and -.');
  if (!/^[A-Za-z0-9_-]+$/.test(cs)) throw new HttpError(400, 'callsign_invalid', 'Callsigns are 3 to 16 characters: letters, digits, _ and -.');
  if (/shit|fuck|cunt/i.test(cs)) throw new HttpError(400, 'callsign_invalid', 'That name is not allowed here. Please pick another name.');
  if (cs.toLowerCase() === 'taken') throw new HttpError(409, 'callsign_taken', 'That callsign is taken.');
}
/** Characters that live "on the server": identity key -> saved DB. */
const vault = (): Record<string, DB> => { try { return JSON.parse(localStorage.getItem(IDKEY) ?? '{}'); } catch { return {}; } };
const putVault = (v: Record<string, DB>) => { try { localStorage.setItem(IDKEY, JSON.stringify(v)); } catch { /* ignore */ } };
const idKey = (i: Ident) => i.provider + ':' + i.subject;
function forgetIdentity(i: Ident) { const v = vault(); delete v[idKey(i)]; putVault(v); }
function mockSignIn(body: any, authed: boolean, link: boolean): unknown {
  const subject = String(need(body, 'subject')).trim();
  const ident: Ident = { provider: 'dev', subject, email: typeof body.email === 'string' ? body.email : null };
  const key = idKey(ident);
  const v = vault();
  if (link && !(authed && db.exists)) throw new HttpError(401, 'unauthorized', 'Missing token.');
  if (v[key]) {
    if (authed && db.exists && !link) {
      if (db.faction && !body.switch) throw new HttpError(409, 'identity_in_use', 'That account already has a survivor. Switch to it? The survivor on this phone will be lost.');
    } else if (link) throw new HttpError(409, 'identity_in_use', 'That dev account is already linked to another survivor.');
    db = { ...fresh(), ...v[key] }; save();
    return { token: TOKEN, me: buildMe(), created: false };
  }
  if (authed && db.exists) {
    if (db.ids.some((i) => i.provider === 'dev')) throw new HttpError(409, 'already_linked', 'A different dev account is already linked.');
    db.ids.push(ident); v[key] = db; putVault(v); save();
    return link ? { me: buildMe() } : { token: TOKEN, me: buildMe(), created: false };
  }
  if (body.terms !== TERMS_VERSION) throw new HttpError(400, 'terms_required', 'Accept the terms of service to play.');
  db = { ...fresh(), exists: true, ids: [ident], terms: TERMS_VERSION }; v[key] = db; putVault(v); save();
  return { token: TOKEN, me: buildMe(), created: true };
}

// ---------- routing ----------
class HttpError { constructor(public status: number, public error: string, public message: string, public extra: Record<string, unknown> = {}) {} }
const need = (b: any, k: string) => { if (b?.[k] == null) throw new HttpError(400, 'bad_request', `Missing ${k}.`); return b[k]; };
const findItem = (uid: string) => { const it = db.items.find((i) => i.uid === uid); if (!it) throw new HttpError(404, 'no_item', 'No such item.'); return it; };

function route(method: string, path: string, body: any, authed: boolean): unknown {
  const guard = () => {
    if (!authed || !db.exists) throw new HttpError(401, 'unauthorized', 'Sign in again.');
    if (db.banned && (db.banned.until === null || db.banned.until > Date.now())) throw new HttpError(403, 'banned', 'This account is suspended.', db.banned);
  };
  const mine = () => ({ me: buildMe() });
  switch (`${method} ${path}`) {
    case 'POST /api/client-error': return { ok: true, stored: Array.isArray(body?.reports) ? body.reports.length : 0 };
    case 'GET /api/health': return { ok: true, version: 'mock', players_online: 41, terms_version: TERMS_VERSION, providers: { google: false, apple: false, dev: true, google_web_client_id: null, apple_web_service_id: null } };
    case 'GET /api/catalog': return CATALOG;
    case 'GET /api/factions': return { human: { share: 0.62, players: 310 }, zombie: { share: 0.38, players: 190 }, underdog: 'zombie', underdog_bonus: 0.12 };
    case 'POST /api/register': {
      if (body?.terms !== TERMS_VERSION) throw new HttpError(400, 'terms_required', 'Accept the terms of service to play.');
      const cs = typeof body?.callsign === 'string' ? body.callsign.trim() : '';
      if (cs) checkCallsign(cs);
      db = { ...fresh(), exists: true, callsign: cs || null, terms: TERMS_VERSION }; save();
      return { token: TOKEN, recovery_code: RECOVERY, me: buildMe() };
    }
    case 'POST /api/terms': {
      guard();
      if (body?.version !== TERMS_VERSION) throw new HttpError(400, 'terms_required', 'Accept the terms of service to play.');
      db.terms = TERMS_VERSION; save();
      return mine();
    }
    case 'POST /api/callsign': {
      guard();
      if (db.callsign && !db.mustRename) throw new HttpError(409, 'callsign_set', 'Your callsign is permanent.');
      const cs = String(need(body, 'callsign')).trim();
      checkCallsign(cs);
      db.callsign = cs; db.mustRename = false; save();
      return mine();
    }
    case 'POST /api/recover': {
      if (String(need(body, 'recovery_code')).trim().toUpperCase() !== RECOVERY || !db.exists) throw new HttpError(404, 'bad_recovery', 'No account matches that code. (Mock code: ' + RECOVERY + ')');
      return { token: TOKEN, me: buildMe() };
    }
    case 'POST /api/auth/dev': return mockSignIn(body, authed, false);
    case 'POST /api/auth/link/dev': return mockSignIn(body, authed, true);
    case 'POST /api/auth/unlink/dev': {
      guard();
      if (db.ids.length <= 1) throw new HttpError(409, 'last_identity', 'That is your only sign-in. Link another before removing it.');
      db.ids = db.ids.filter((i) => i.provider !== 'dev'); save();
      return mine();
    }
    case 'DELETE /api/account': {
      if (!authed || !db.exists) throw new HttpError(401, 'unauthorized', 'Sign in again.'); // suspended players may still erase
      for (const i of db.ids) forgetIdentity(i);
      db = fresh(); save();
      return { ok: true };
    }
    case 'POST /api/faction': {
      guard();
      if (db.faction) throw new HttpError(409, 'already_chosen', 'You already chose.');
      const f = need(body, 'faction') as Faction;
      db.faction = f;
      db.items = [makeItem('bat', 'common'), makeItem('hoodie', 'common'), makeItem('flashlight', 'common')];
      db.eq = { weapon: db.items[0].uid, armor: db.items[1].uid, utility: db.items[2].uid };
      db.consumables = { heal_s: 3 }; db.hp = buildMe().max_hp; save();
      return mine();
    }
    case 'GET /api/me': guard(); return buildMe();
    case 'POST /api/avatar': {
      guard();
      const av = body.avatar as Record<string, unknown>;
      const look = CATALOG.avatar_looks?.[Number(av.look ?? 0)];
      if (av.look != null && (!look || look.level > db.level)) throw new HttpError(409, 'look_locked', 'That look is not unlocked yet.');
      db.avatar = av; save(); return mine();
    }
    case 'POST /api/location': {
      guard();
      mockSimulated = body.mock === true;
      const v = world(need(body, 'lat'), need(body, 'lon'), (body.places as PlaceReport[] | undefined) ?? []);
      v.in_transit = observeTransit(body.lat, body.lon);
      if (v.in_transit) v.hostiles_near = false;
      v.me.hp = buildMe().hp;
      db.mprog[2] += 18;
      db.rec.distance_m += 18;
      if (body.sanctuary) { v.enemies = []; v.caches = []; v.echoes = []; v.landmarks = []; v.hostiles_near = false; }
      else if (db.contactPending && db.level >= 5) {
        db.contactPending = false;
        const b = contactBattle();
        db.rec.contacts++;
        v.events.push(pushFeed('contact', `A ${b.b.faction === 'zombie' ? 'Zombie' : 'Human'} found you. ${b.winner === 'a' ? 'You held.' : 'You fell.'}`, { battle: b }));
        v.events.push(pushFeed('echo_report', 'Your echo held against a ' + (db.faction === 'human' ? 'Zombie' : 'Human') + ' (+15 XP).'));
        v.me = { ...v.me, hp: b.me.hp, level: b.me.level, xp: b.me.xp, xp_next: b.me.xp_next, salvage: b.me.salvage };
      }
      save();
      return v;
    }
    case 'POST /api/engage': {
      guard();
      if (inTransit()) throw new HttpError(409, 'in_transit', "You're moving too fast. Fights wait until you're on foot.");
      const id = String(need(body, 'id'));
      const m = /^e:(-?\d+):(-?\d+):(\d+):(\d+)$/.exec(id);
      const isEcho = id.startsWith('echo:');
      const f = oppFaction();
      let foe: Combatant;
      if (m) {
        const sp = enemiesIn(+m[1], +m[2], +m[3], 45)[+m[4]];
        if (!sp || db.defeated.includes(id)) throw new HttpError(404, 'gone', 'That one is gone.');
        const names = CATALOG.enemies.find((e) => e.id === sp.archetype)!.names;
        const lvl = Math.max(1, db.level + (sp.elite ? 3 : sp.off));
        foe = { name: names[db.faction === 'zombie' ? 'zombie' : 'human'], faction: f, level: lvl, title: sp.elite ? 'Elite' : '', kind: 'enemy', archetype: sp.archetype, max_hp: Math.round(maxHp(lvl) * 0.9), hp_start: Math.round(maxHp(lvl) * 0.9), stats: { hp: 0, atk: 8 + 1.8 * lvl, def: 5 + 1.3 * lvl, spd: 9 + 0.5 * lvl }, abilities: [], gear: [] };
      } else if (isEcho) {
        foe = { name: 'Rogue', faction: f, level: db.level + 1, title: 'Stalker', kind: 'rogue', archetype: null, max_hp: maxHp(db.level + 1), hp_start: maxHp(db.level + 1), stats: { hp: 0, atk: 12 + 2 * db.level, def: 7 + 1.5 * db.level, spd: 10 + 0.6 * db.level }, abilities: db.level >= 7 ? ['aimed_shot'] : [], gear: gearFor(f, ['crowbar', 'jacket']), gear_detail: kitFor(f, [['crowbar', 'common', 0], ['jacket', 'uncommon', 0]]) };
      } else throw new HttpError(404, 'gone', 'Nothing there.');
      foe.stats = { hp: foe.max_hp, atk: Math.round(foe.stats.atk), def: Math.round(foe.stats.def), spd: Math.round(foe.stats.spd) };
      const base = isEcho ? 40 + 7 * foe.level : 20 + 6 * foe.level;
      const b = resolve(foe, isEcho ? 'echo' : 'pve', base, isEcho ? 3 : 1, m ? 0 : 0.06);
      b.stance = (body.stance as Stance | undefined) ?? 'careful';
      if (foe.archetype) { db.bestiary = { ...(db.bestiary ?? {}), [foe.archetype]: (db.bestiary?.[foe.archetype] ?? 0) + 1 }; b.me = buildMe(); }
      if (b.winner === 'a' && m) db.defeated.push(id);
      if (b.winner === 'a' && m && foe.title === 'Elite') { collection().elites++; checkAchievements(b.rewards); b.me = buildMe(); }
      save();
      return b;
    }
    case 'POST /api/stance': {
      guard();
      db.stance = need(body, 'stance') as Stance; save();
      return mine();
    }
    case 'POST /api/open': {
      guard();
      if (inTransit()) throw new HttpError(409, 'in_transit', "You're moving too fast. Fights wait until you're on foot.");
      const id = String(need(body, 'id'));
      if (db.defeated.includes(id)) throw new HttpError(404, 'gone', 'Already opened.');
      db.defeated.push(id);
      db.rec.caches++;
      db.mprog[1]++;
      const loot = lootRewards(10 + 2 * db.level, 0.55);
      giveNote(loot, null, id.startsWith('a:') ? 0.35 : 0.12, true);
      giveFinds(loot, id.startsWith('a:'));
      grantXp(loot); checkAchievements(loot); save();
      return { loot, me: buildMe() };
    }

    // ----- notes -----
    case 'GET /api/notes': guard(); return archiveFor(db.faction ?? 'human', db.notes ?? [], db.noteClaims ?? []);
    case 'POST /api/notes/claim': {
      guard();
      const set = String(need(body, 'set'));
      const c = claimable(db.faction ?? 'human', db.notes ?? [], db.noteClaims ?? [], set);
      if (!c) throw new HttpError(409, 'set_incomplete', 'That set cannot be claimed.');
      (db.noteClaims = db.noteClaims ?? []).push(set);
      db.salvage += c.salvage;
      const nr = { ...emptyRewards(), salvage: c.salvage };
      checkAchievements(nr); save();
      return { rewards: nr, title: c.title, me: buildMe() };
    }

    // ----- achievements, collection, cosmetics -----
    case 'GET /api/achievements': {
      guard();
      const col = collection();
      checkAchievements(); save();
      return { earned: col.earned, progress: metricsOf(col, { distance_m: db.rec.distance_m, wins: db.rec.wins, contacts_won: db.rec.contacts_won ?? 0, echoes_won: db.rec.echoes_won ?? 0, caches: db.rec.caches, level: db.level, notes: (db.notes ?? []).length, sets: (db.noteClaims ?? []).length, bestUpgrade: col.bestUp ?? 0 }) };
    }
    case 'GET /api/collection': guard(); return { bases: collection().bases, uniques: collection().uniques, rarities: collection().rarities };
    case 'POST /api/cosmetics/equip': {
      guard();
      const kind = String(need(body, 'kind')) as 'color' | 'frame';
      const id = body.id == null ? null : String(body.id);
      if (kind !== 'color' && kind !== 'frame') throw new HttpError(400, 'bad_kind', 'Colour or frame.');
      if (id) {
        const c = MOCK_COSMETICS.find((x) => x.id === id);
        if (!c) throw new HttpError(404, 'no_cosmetic', 'No such cosmetic.');
        if (c.kind !== kind) throw new HttpError(400, 'bad_kind', 'Wrong kind.');
        if (!collection().owned.includes(id)) throw new HttpError(409, 'not_owned', 'You do not own that.');
      }
      collection()[kind] = id; save();
      return mine();
    }

    // ----- gear -----
    case 'POST /api/equip': {
      guard();
      const it = findItem(String(need(body, 'uid')));
      if (db.level < it.req) throw new HttpError(400, 'level_too_low', `Needs level ${it.req}.`);
      db.eq[it.slot] = it.uid; save();
      return mine();
    }
    case 'POST /api/unequip': guard(); db.eq[need(body, 'slot') as Slot] = null; save(); return mine();
    case 'POST /api/scrap': {
      guard();
      const uids = need(body, 'uids') as string[];
      let gained = 0;
      for (const uid of uids) {
        const it = findItem(uid);
        if (Object.values(equipped()).includes(uid)) throw new HttpError(400, 'equipped', 'Unequip it first.');
        gained += it.scrap_value;
      }
      db.items = db.items.filter((i) => !uids.includes(i.uid));
      db.salvage += gained; save();
      return { salvage_gained: gained, me: buildMe() };
    }
    case 'POST /api/upgrade': {
      guard();
      const it = findItem(String(need(body, 'uid')));
      if (db.level < 4) throw new HttpError(400, 'locked', 'Upgrading unlocks at level 4.');
      if (it.upgrade_cost == null) throw new HttpError(400, 'maxed', 'Already at +10.');
      if (db.salvage < it.upgrade_cost) throw new HttpError(400, 'no_salvage', 'Not enough salvage.');
      db.salvage -= it.upgrade_cost; it.upgrade++; finishItem(it); checkAchievements(); save();
      return mine();
    }
    case 'POST /api/use': {
      guard();
      const id = String(need(body, 'consumable'));
      if (!(db.consumables[id] > 0)) throw new HttpError(400, 'none', 'You have none.');
      if (id === 'xp_token') {
        const r = emptyRewards(20 + 6 * db.level);
        db.consumables[id]--; if (db.consumables[id] <= 0) delete db.consumables[id];
        grantXp(r); checkAchievements(r); save();
        return { me: buildMe(), rewards: r };
      }
      const m = buildMe();
      const heal = id === 'heal_s' ? 0.25 : id === 'heal_m' ? 0.6 : id === 'revive' ? 1 : 0;
      if (heal) {
        if (db.hp >= m.max_hp) throw new HttpError(400, 'full', 'Already at full health.');
        db.hp = Math.min(m.max_hp, db.hp + Math.round(m.max_hp * heal));
      } else if (id.startsWith('buff_')) db.buffs = [...db.buffs.filter((b) => b.kind !== id), { kind: id, until: Date.now() + 30 * 60e3 }];
      else throw new HttpError(400, 'not_usable', 'That cannot be used here.');
      db.consumables[id]--; if (db.consumables[id] <= 0) delete db.consumables[id];
      save();
      return mine();
    }
    case 'POST /api/abilities': {
      guard();
      const eq = (need(body, 'equipped') as string[]);
      const m = buildMe();
      if (eq.length > m.abilities.slots || eq.some((a) => !m.abilities.unlocked.includes(a))) throw new HttpError(400, 'bad_abilities', 'Those do not fit.');
      db.abil = eq; save();
      return mine();
    }
    case 'POST /api/missions/claim': {
      guard();
      const id = String(need(body, 'id'));
      const ms = [...missionList(), ...(weeklyMission() ? [weeklyMission()!] : [])];
      const mi = ms.find((x) => x.id === id);
      if (!mi) throw new HttpError(404, 'no_mission', 'No such mission.');
      if (mi.claimed) throw new HttpError(400, 'claimed', 'Already claimed.');
      if (mi.progress < mi.target) throw new HttpError(400, 'incomplete', 'Not finished yet.');
      const r = { ...mi.rewards };
      db.salvage += r.salvage;
      if (id === 'w1') { db.wclaimed = true; const it = makeItem(CATALOG.items.filter((c) => c.req <= db.level)[0].id, 'rare'); db.items.push(it); r.items = [it]; }
      else db.mclaimed[['d1', 'd2', 'd3'].indexOf(id)] = true;
      if (db.mclaimed.every(Boolean)) { db.consumables.heal_m = (db.consumables.heal_m ?? 0) + 1; r.consumables = { heal_m: 1 }; }
      grantXp(r); checkAchievements(r); save();
      return { rewards: r, me: buildMe() };
    }
    case 'POST /api/store/buy': {
      guard();
      const sku = String(need(body, 'sku'));
      const cos = MOCK_COSMETICS.find((x) => x.id === sku);
      if (cos) {
        if (cos.price === 0) throw new HttpError(409, 'not_for_sale', 'That one is earned, not bought.');
        if (collection().owned.includes(sku)) throw new HttpError(409, 'owned', 'You already own that.');
        if (db.salvage < cos.price) throw new HttpError(409, 'not_enough_salvage', 'Not enough salvage.');
        db.salvage -= cos.price; collection().owned.push(sku); save();
        return mine();
      }
      const s = CATALOG.store.find((x) => x.sku === sku);
      if (!s) throw new HttpError(404, 'no_sku', 'Not for sale.');
      if (db.level < 2) throw new HttpError(403, 'locked', 'The Store opens at level 2.');
      if (db.salvage < s.price) throw new HttpError(400, 'no_salvage', 'Not enough salvage.');
      db.salvage -= s.price;
      if (sku === 'supply') {
        const elig = CATALOG.items.filter((c) => c.req <= db.level);
        const it = makeItem(elig[Math.floor(Math.random() * elig.length)].id, Math.random() < 0.3 ? 'rare' : 'uncommon');
        db.items.push(it);
        const sr = { ...emptyRewards(), items: [it] };
        checkAchievements(sr); save();
        return { rewards: sr, me: buildMe() };
      }
      if (CATALOG.consumables.some((c) => c.id === sku)) db.consumables[sku] = (db.consumables[sku] ?? 0) + 1;
      save();
      return mine();
    }

    // ----- war and social -----
    case 'GET /api/war': {
      guard();
      const flip = db.faction === 'zombie';
      return {
        week: 31, ends_at: Date.now() + (3 * 24 + 4) * 3600e3 + 12 * 60e3,
        global: { human: flip ? 15310 : 18420, zombie: flip ? 18420 : 15310 },
        district: { id: 'c23b', human: flip ? 612 : 884, zombie: flip ? 884 : 612 },
        top: [['Marrow', 31], ['Pike', 22], ['Ness', 14], ['Quill', 19], ['Dorn', 12]].map(([callsign, level], i) => ({ callsign: callsign as string, level: level as number, title: CATALOG.levels.titles[db.faction ?? 'human'][Math.floor((level as number) / 5)], points: 410 - i * 63 })),
        my_points: db.warPoints,
      };
    }
    case 'GET /api/leaderboard': {
      guard();
      const board = String(body?.board ?? 'weekly');
      const weekly = board === 'weekly', contacts = board === 'contacts';
      const rows = [['Marrow', 31, 'human', 'NITE'], ['Vesper', 29, 'zombie', 'HOLO'], ['Pike', 22, 'human', 'NITE'], ['Hush', 21, 'zombie', null], ['Quill', 19, 'human', null], ['Rook', 18, 'zombie', 'ROT'], ['Dorn', 12, 'human', null]] as const;
      const entries: LeaderboardEntry[] = rows.map(([callsign, level, faction, clan_tag], i) => ({ rank: i + 1, callsign, level, title: CATALOG.levels.titles[faction][Math.floor(level / 5)], faction, value: weekly ? 460 - i * 52 : contacts ? 14 - i * 2 : level, clan_tag }));
      entries.push({ rank: 8, callsign: db.callsign ?? 'You', level: db.level, title: buildMe().title, faction: db.faction ?? 'human', value: weekly ? db.warPoints : contacts ? db.rec.contacts_won ?? 0 : db.level, clan_tag: null });
      return { entries: entries.sort((a, b) => b.value - a.value).map((e, i) => ({ ...e, rank: i + 1 })) };
    }
    case 'POST /api/report': {
      guard();
      const kind = String(need(body, 'kind')), target = String(need(body, 'target')), reason = String(need(body, 'reason'));
      if (!['name', 'harassment', 'cheating', 'other'].includes(reason)) throw new HttpError(400, 'bad_request', 'Choose a reason: name, harassment, cheating or other.');
      if (!['player', 'clan', 'message'].includes(kind)) throw new HttpError(400, 'bad_request', 'Report a player, a clan or a message.');
      const key = kind + ':' + target.toLowerCase();
      db.reported = db.reported ?? [];
      if (db.reported.includes(key)) throw new HttpError(409, 'already_reported', 'You already reported this. It is waiting to be reviewed.');
      if (db.reported.length >= 5) throw new HttpError(429, 'report_limit', 'You have sent several reports already. Try again in an hour.');
      db.reported.push(key); save();
      return { ok: true };
    }
    case 'GET /api/feed': guard(); return { events: db.feed.map((e) => ({ ...e, battle: undefined })) };
    case 'GET /api/clans': {
      guard();
      const q = String(body?.q ?? '').toLowerCase();
      return { clans: allClans().filter((c) => !q || c.name.toLowerCase().includes(q) || c.tag.toLowerCase().includes(q)).map((c) => ({ id: c.id, name: c.name, tag: c.tag, members: 8 + c.name.length, level_sum: 140 + c.tag.length * 31, faction: c.faction })) };
    }
    case 'POST /api/clans': {
      guard();
      if (db.level < 10) throw new HttpError(403, 'locked', 'Clans unlock at level 10.');
      if (db.clan) throw new HttpError(409, 'in_clan', 'Leave your clan first.');
      if (db.salvage < 500) throw new HttpError(400, 'no_salvage', 'Creating a clan costs 500 salvage.');
      const name = String(need(body, 'name')).trim(), tag = String(need(body, 'tag')).trim().toUpperCase();
      if (allClans().some((c) => c.tag === tag || c.name.toLowerCase() === name.toLowerCase())) throw new HttpError(409, 'clan_taken', 'That name or tag is taken.');
      const c: Clan = { id: 'u' + db.n++, name, tag, faction: db.faction ?? 'human', code: `${tag}-${1000 + (db.n * 37) % 9000}`, strongholds: 0 };
      db.userClans.push(c); db.salvage -= 500; db.clan = { id: c.id, role: 'Leader' }; seedChat(); save();
      return { clan: clanDetail(c), me: buildMe() };
    }
    case 'POST /api/clans/join': {
      guard();
      if (db.level < 10) throw new HttpError(403, 'locked', 'Clans unlock at level 10.');
      const c = body?.id ? allClans().find((x) => x.id === body.id) : allClans().find((x) => x.code === String(body?.code ?? '').toUpperCase());
      if (!c) throw new HttpError(404, 'no_clan', 'No clan matches that.');
      if (c.faction !== db.faction) throw new HttpError(400, 'wrong_faction', 'That clan is the other side.');
      db.clan = { id: c.id, role: 'Member' }; seedChat(); save();
      return { clan: clanDetail(c), me: buildMe() };
    }
    case 'POST /api/clans/leave': guard(); db.clan = null; save(); return mine();
    case 'GET /api/clan': {
      guard();
      const c = db.clan && allClans().find((x) => x.id === db.clan!.id);
      if (!c) throw new HttpError(404, 'no_clan', 'You are not in a clan.');
      return { clan: clanDetail(c) };
    }
    case 'GET /api/clan/chat': guard(); seedChat(); return { messages: db.chat };
    case 'POST /api/clan/chat': {
      guard(); seedChat();
      const text = String(need(body, 'text')).trim().slice(0, 200);
      db.chat = [...db.chat, { id: 'm' + db.n++, callsign: db.callsign ?? 'You', text, at: Date.now() }].slice(-60); save();
      return { messages: db.chat };
    }

    // ----- dev -----
    case 'POST /api/dev/grant': {
      guard();
      if (body?.xp) { const r = emptyRewards(body.xp); grantXp(r); }
      if (body?.salvage) db.salvage += body.salvage;
      if (body?.item) { const it = makeItem(body.item.base, body.item.rarity, 0, body.item.unique ?? null); db.items.push(it); }
      if (body?.note) {
        const ids = body.note === 'all' ? allVisibleIds(db.faction ?? 'human') : [String(body.note)];
        const held = db.notes ?? (db.notes = []);
        for (const id of ids) if (!held.some((h) => h.id === id)) held.push({ id, at: Date.now() });
      }
      if (body?.consumable) db.consumables[body.consumable.id] = (db.consumables[body.consumable.id] ?? 0) + body.consumable.n;
      save();
      return mine();
    }
    case 'POST /api/dev/heal': guard(); db.hp = buildMe().max_hp; save(); return mine();
    case 'POST /api/dev/reset_cooldowns': guard(); return {};
    case 'POST /api/dev/bot_contact': guard(); db.contactPending = true; save(); return {};
    default: throw new HttpError(404, 'not_found', `Mock server has no ${method} ${path}.`);
  }
}

export function installMock() {
  // Handy from the console: __mockContact() stages a Contact on the next poll.
  (window as unknown as { __mockContact: () => void }).__mockContact = () => { db.contactPending = true; save(); };
  // Console: __mockBan(days?, reason?) suspends this account, __mockUnban() lifts it, __mockRename() forces a new callsign.
  const w = window as unknown as Record<string, unknown>;
  w.__mockBan = (days?: number, reason = 'Using a GPS spoofer.') => { db.banned = { reason, until: days ? Date.now() + days * 86400e3 : null }; save(); };
  w.__mockUnban = () => { db.banned = null; save(); };
  w.__mockRename = () => { db.callsign = 'Survivor4821'; db.mustRename = true; save(); };
  (window as unknown as { __mockRoute: typeof route }).__mockRoute = (m, p, b) => route(m, p, b, true);
  setFetcher(async (url, init) => {
    await new Promise((r) => setTimeout(r, 60 + Math.random() * 120));
    const u = new URL(url, location.origin);
    const auth = (init.headers as Record<string, string> | undefined)?.Authorization === 'Bearer ' + TOKEN;
    const body = init.body ? JSON.parse(String(init.body)) : Object.fromEntries(u.searchParams);
    try {
      const data = route(init.method ?? 'GET', u.pathname, body, auth);
      return new Response(JSON.stringify(data), { status: 200 });
    } catch (e) {
      if (e instanceof HttpError) return new Response(JSON.stringify({ error: e.error, message: e.message, ...e.extra }), { status: e.status });
      throw e;
    }
  });
  console.info('[outbreak] mock server active (src/dev/mock.ts)');
}
