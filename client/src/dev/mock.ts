/*
 * TEMPORARY SCAFFOLDING. An in-browser stand-in for the Zig server so the UI can be exercised
 * before the real one exists. Enable with ?mock=1 (sticks in sessionStorage) or VITE_MOCK=1.
 * Delete this file (and the import in main.tsx) once the real server is the default. Nothing
 * here is authoritative game logic and the numbers are not from DESIGN.md's balance tables.
 */
import { setFetcher } from '../api/client';
import type {
  Battle, Catalog, Combatant, Faction, Item, Me, Rarity, Rewards, Slot, Stats, Turn, WorldView,
} from '../api/types';

const KEY = 'outbreak.mock.db';
const TOKEN = 'mock-token';
const RECOVERY = 'MOCK-7QX2-K9PD-41LA';

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
const CATALOG: Catalog = {
  version: 1,
  items: [
    { id: 'bat', slot: 'weapon', req: 1, names: { human: 'Baseball Bat', zombie: 'Rotten Teeth' }, stats: { hp: 0, atk: 7, def: 0, spd: 0 } },
    { id: 'knife', slot: 'weapon', req: 1, names: { human: 'Kitchen Knife', zombie: 'Broken Nails' }, stats: { hp: 0, atk: 5, def: 0, spd: 3 } },
    { id: 'crowbar', slot: 'weapon', req: 3, names: { human: 'Crowbar', zombie: 'Bone Spur' }, stats: { hp: 0, atk: 8, def: 2, spd: 0 } },
    { id: 'hoodie', slot: 'armor', req: 1, names: { human: 'Hoodie', zombie: 'Torn Skin' }, stats: { hp: 5, atk: 0, def: 3, spd: 1 } },
    { id: 'jacket', slot: 'armor', req: 1, names: { human: 'Leather Jacket', zombie: 'Thick Hide' }, stats: { hp: 8, atk: 0, def: 4, spd: 0 } },
    { id: 'flashlight', slot: 'utility', req: 1, names: { human: 'Flashlight', zombie: 'Night Eyes' }, stats: { hp: 0, atk: 0, def: 1, spd: 3 } },
    { id: 'backpack', slot: 'utility', req: 1, names: { human: 'Backpack', zombie: 'Scavenger Gut' }, stats: { hp: 10, atk: 0, def: 2, spd: 0 } },
  ],
  uniques: [],
  rarities: {},
  perks: [{ id: 'keen', name: 'Keen', text: '+6% crit' }, { id: 'sturdy', name: 'Sturdy', text: '+8% DEF' }],
  consumables: [
    { id: 'heal_s', names: { human: 'Bandage', zombie: 'Raw Meat' }, text: 'Heal 25% max HP', price: 20 },
    { id: 'heal_m', names: { human: 'First Aid Kit', zombie: 'Fresh Kill' }, text: 'Heal 60% max HP', price: 50 },
    { id: 'buff_atk', names: { human: 'Adrenaline Shot', zombie: 'Rage Gland' }, text: '+15% ATK for 30 min', price: 60 },
  ],
  abilities: [{ id: 'second_wind', level: 3, names: { human: 'Second Wind', zombie: 'Devour' }, text: 'Once per fight, below 35% HP, heal 30% max HP' }],
  enemies: [
    { id: 'shambler', names: { human: 'Shambler', zombie: 'Scavenger' }, text: 'Slow and common.' },
    { id: 'runner', names: { human: 'Runner', zombie: 'Scout' }, text: 'Fast and fragile.' },
    { id: 'bloater', names: { human: 'Bloater', zombie: 'Barricader' }, text: 'Tanky.' },
    { id: 'brute', names: { human: 'Brute', zombie: 'Soldier' }, text: 'Hits hard.' },
  ],
  levels: {
    xp_to_next: Array.from({ length: 50 }, (_, i) => Math.round((40 * Math.pow(i + 1, 1.55) + 30) / 10) * 10),
    titles: {
      human: ['Survivor', 'Scavenger', 'Defender', 'Ranger', 'Sentinel', 'Warden', 'Vanguard', 'Commander', 'Hero', 'Legend', 'Last Hope'],
      zombie: ['Turned', 'Shambler', 'Lurker', 'Stalker', 'Ravager', 'Brute', 'Alpha', 'Dread', 'Blight', 'Plaguebringer', 'Patient Zero'],
    },
    unlocks: [{ level: 2, text: 'The Store' }, { level: 3, text: 'Ability slot 1 and your first ability' }, { level: 5, text: 'Real-world fights begin' }],
  },
  store: [{ sku: 'heal_s', name: 'Bandage', price: 20, text: 'Heal 25% max HP' }],
};

// ---------- database ----------
interface DB { callsign: string | null; faction: Faction | null; level: number; xp: number; hp: number; salvage: number; items: Item[]; consumables: Record<string, number>; defeated: string[]; n: number }
function fresh(): DB { return { callsign: null, faction: null, level: 1, xp: 0, hp: 100, salvage: 0, items: [], consumables: {}, defeated: [], n: 1 }; }
function load(): DB {
  try { const r = localStorage.getItem(KEY); if (r) return { ...fresh(), ...JSON.parse(r) }; } catch { /* ignore */ }
  return fresh();
}
let db = load();
const save = () => { try { localStorage.setItem(KEY, JSON.stringify(db)); } catch { /* ignore */ } };

const maxHp = (l: number) => 100 + 14 * (l - 1);
const sum = (a: Stats, b: Stats): Stats => ({ hp: a.hp + b.hp, atk: a.atk + b.atk, def: a.def + b.def, spd: a.spd + b.spd });
const MULT: Record<Rarity, number> = { common: 1, uncommon: 1.2, rare: 1.45, legendary: 1.8 };

function makeItem(base: string, rarity: Rarity, f: Faction): Item {
  const c = CATALOG.items.find((i) => i.id === base)!;
  const m = MULT[rarity];
  const stats = { hp: Math.round(c.stats.hp * m), atk: Math.round(c.stats.atk * m), def: Math.round(c.stats.def * m), spd: Math.round(c.stats.spd * m) };
  void f;
  return {
    uid: 'it' + db.n++, base, slot: c.slot, rarity, upgrade: 0,
    perks: rarity === 'rare' ? ['keen'] : rarity === 'legendary' ? ['keen', 'sturdy'] : [],
    unique: null, req: c.req, stats, power: stats.atk * 2 + stats.def * 2 + stats.spd + Math.round(stats.hp / 4),
    scrap_value: { common: 3, uncommon: 8, rare: 20, legendary: 50 }[rarity], upgrade_cost: 8,
  };
}

function equipped(): Record<Slot, string | null> {
  const e: Record<Slot, string | null> = { weapon: null, armor: null, utility: null };
  for (const s of ['weapon', 'armor', 'utility'] as Slot[]) e[s] = db.items.find((i) => i.slot === s)?.uid ?? null;
  return e;
}

function buildMe(): Me {
  const base: Stats = { hp: maxHp(db.level), atk: 10 + 2 * (db.level - 1), def: 6 + 1.5 * (db.level - 1), spd: 10 + 0.6 * (db.level - 1) };
  const eq = equipped();
  let total = base;
  for (const uid of Object.values(eq)) { const it = db.items.find((i) => i.uid === uid); if (it) total = sum(total, it.stats); }
  const titles = CATALOG.levels.titles[db.faction ?? 'human'];
  return {
    id: 'mock-1', callsign: db.callsign ?? '', faction: db.faction, level: db.level, xp: db.xp,
    xp_next: CATALOG.levels.xp_to_next[db.level - 1], title: titles[Math.min(titles.length - 1, Math.floor(db.level / 5))],
    hp: Math.min(db.hp, total.hp), max_hp: total.hp, downed_until: null,
    stats: { hp: total.hp, atk: Math.round(total.atk), def: Math.round(total.def), spd: Math.round(total.spd) },
    base_stats: { hp: base.hp, atk: Math.round(base.atk), def: Math.round(base.def), spd: Math.round(base.spd) },
    salvage: db.salvage, inventory_cap: 30 + 2 * (db.level - 1), equipped: eq, items: db.items,
    consumables: db.consumables, abilities: { unlocked: [], equipped: [], slots: 0 }, buffs: [],
    missions: {
      daily: [
        { id: 'd1', kind: 'defeat', text: 'Defeat 5 enemies', target: 5, progress: 1, rewards: emptyRewards(40), claimed: false },
        { id: 'd2', kind: 'cache', text: 'Open 2 caches', target: 2, progress: 0, rewards: emptyRewards(30), claimed: false },
        { id: 'd3', kind: 'walk', text: 'Walk 1000 m', target: 1000, progress: 240, rewards: emptyRewards(30), claimed: false },
      ],
      weekly: null, streak: 1, resets_at: Date.now() + 6 * 3600e3,
    },
    clan: null, avatar: null, pvp_protected: db.level < 5, underdog_bonus: 0.15, war_points_week: 0,
  };
}

function emptyRewards(xp = 0): Rewards {
  return { xp, salvage: 0, items: [], consumables: {}, war_points: 0, level_up: null };
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

function world(lat: number, lon: number): WorldView {
  const now = Date.now();
  const { dlat, dlon } = dims(lat);
  const ci = Math.floor(lat / dlat), cj = Math.floor(lon / dlon);
  const w10 = Math.floor(now / 600e3), w30 = Math.floor(now / 1800e3);
  const v: WorldView = { now, me: { hp: db.hp, max_hp: buildMe().max_hp, downed_until: null, level: db.level, xp: db.xp, xp_next: CATALOG.levels.xp_to_next[db.level - 1], salvage: db.salvage }, hostiles_near: false, enemies: [], caches: [], echoes: [], strongholds: [], raids: [], events: [] };
  const R = 3; // 450 m / 150 m
  for (let i = ci - R; i <= ci + R; i++) for (let j = cj - R; j <= cj + R; j++) {
    for (const e of enemiesIn(i, j, w10, lat)) {
      if (db.defeated.includes(e.id)) continue;
      v.enemies.push({ id: e.id, archetype: e.archetype, level: Math.max(1, db.level + (e.elite ? 3 : e.off)), elite: e.elite, lat: e.lat, lon: e.lon, expires_at: (w10 + 1) * 600e3 });
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
  return { name: m.callsign, faction: m.faction ?? 'human', level: m.level, title: m.title, kind: 'player', archetype: null, max_hp: m.max_hp, hp_start: m.hp, stats: m.stats, abilities: [], gear: m.items.map((i) => CATALOG.items.find((c) => c.id === i.base)!.names[m.faction ?? 'human']) };
}

function fight(foe: Combatant, seed: number): { turns: Turn[]; win: boolean } {
  const r = rng(seed);
  const me = combatantMe();
  let hpA = me.hp_start, hpB = foe.max_hp;
  const turns: Turn[] = [];
  for (let t = 0; t < 30 && hpA > 0 && hpB > 0; t++) {
    for (const actor of ['a', 'b'] as const) {
      if (hpA <= 0 || hpB <= 0) break;
      const att = actor === 'a' ? me.stats : foe.stats;
      const def = actor === 'a' ? foe.stats : me.stats;
      const dodge = r() < 0.08;
      const crit = !dodge && r() < 0.1;
      let dmg = dodge ? 0 : Math.max(1, Math.round(1.4 * att.atk ** 2 / (att.atk + def.def) * (0.85 + r() * 0.3) * (crit ? 1.6 : 1)));
      if (actor === 'a') hpB = Math.max(0, hpB - dmg); else hpA = Math.max(0, hpA - dmg);
      turns.push({ actor, ev: dodge ? 'dodge' : crit ? 'crit' : 'hit', ability: null, dmg, heal: 0, hp_a: hpA, hp_b: hpB });
      dmg = 0;
    }
  }
  return { turns, win: hpB <= 0 || (hpA > 0 && hpA / me.max_hp >= hpB / foe.max_hp) };
}

function grantXp(r: Rewards) {
  db.xp += r.xp;
  const from = db.level;
  while (db.xp >= CATALOG.levels.xp_to_next[db.level - 1] && db.level < 50) { db.xp -= CATALOG.levels.xp_to_next[db.level - 1]; db.level++; }
  if (db.level > from) r.level_up = { from, to: db.level, unlocks: CATALOG.levels.unlocks.filter((u) => u.level > from && u.level <= db.level).map((u) => u.text) };
}

function lootRewards(xp: number, items: number): Rewards {
  const r = emptyRewards(xp);
  r.salvage = 3 + Math.floor(db.level / 2);
  db.salvage += r.salvage;
  if (Math.random() < items) {
    const base = CATALOG.items[Math.floor(Math.random() * CATALOG.items.length)].id;
    const roll = Math.random();
    const it = makeItem(base, roll < 0.02 ? 'legendary' : roll < 0.12 ? 'rare' : roll < 0.4 ? 'uncommon' : 'common', db.faction ?? 'human');
    db.items.push(it);
    r.items.push(it);
  }
  if (Math.random() < 0.5) { db.consumables.heal_s = (db.consumables.heal_s ?? 0) + 1; r.consumables.heal_s = 1; }
  return r;
}

// ---------- routing ----------
class HttpError { constructor(public status: number, public error: string, public message: string) {} }
const need = (b: any, k: string) => { if (b?.[k] == null) throw new HttpError(400, 'bad_request', `Missing ${k}.`); return b[k]; };

function route(method: string, path: string, body: any, authed: boolean): unknown {
  const guard = () => { if (!authed || !db.callsign) throw new HttpError(401, 'unauthorized', 'Sign in again.'); };
  switch (`${method} ${path}`) {
    case 'GET /api/health': return { ok: true, version: 'mock', players_online: 41 };
    case 'GET /api/catalog': return CATALOG;
    case 'GET /api/factions': return { human: { share: 0.62, players: 310 }, zombie: { share: 0.38, players: 190 }, underdog: 'zombie', underdog_bonus: 0.12 };
    case 'POST /api/register': {
      const cs = String(need(body, 'callsign')).trim();
      if (cs.length < 3 || cs.length > 16) throw new HttpError(400, 'bad_callsign', 'Callsign must be 3 to 16 characters.');
      if (!/^[A-Za-z0-9_ -]+$/.test(cs)) throw new HttpError(400, 'bad_callsign', 'Letters, numbers, spaces, - and _ only.');
      if (cs.toLowerCase() === 'taken') throw new HttpError(409, 'callsign_taken', 'That callsign is taken.');
      db = { ...fresh(), callsign: cs }; save();
      return { token: TOKEN, recovery_code: RECOVERY, me: buildMe() };
    }
    case 'POST /api/recover': {
      if (String(need(body, 'recovery_code')).trim().toUpperCase() !== RECOVERY || !db.callsign) throw new HttpError(404, 'bad_recovery', 'No account matches that code. (Mock code: ' + RECOVERY + ')');
      return { token: TOKEN, me: buildMe() };
    }
    case 'POST /api/faction': {
      guard();
      if (db.faction) throw new HttpError(409, 'already_chosen', 'You already chose.');
      const f = need(body, 'faction') as Faction;
      db.faction = f;
      db.items = [makeItem('bat', 'common', f), makeItem('hoodie', 'common', f), makeItem('flashlight', 'common', f)];
      db.consumables = { heal_s: 3 }; db.hp = buildMe().max_hp; save();
      return { me: buildMe() };
    }
    case 'GET /api/me': guard(); return buildMe();
    case 'POST /api/location': {
      guard();
      const v = world(need(body, 'lat'), need(body, 'lon'));
      if (body.sanctuary) { v.enemies = []; v.caches = []; v.echoes = []; v.hostiles_near = false; }
      return v;
    }
    case 'POST /api/engage': {
      guard();
      const id = String(need(body, 'id'));
      const m = /^e:(-?\d+):(-?\d+):(\d+):(\d+)$/.exec(id);
      const isEcho = id.startsWith('echo:');
      let foe: Combatant;
      if (m) {
        const sp = enemiesIn(+m[1], +m[2], +m[3], 45)[+m[4]];
        if (!sp || db.defeated.includes(id)) throw new HttpError(404, 'gone', 'That one is gone.');
        const names = CATALOG.enemies.find((e) => e.id === sp.archetype)!.names;
        const lvl = Math.max(1, db.level + (sp.elite ? 3 : sp.off));
        foe = { name: names[db.faction === 'zombie' ? 'zombie' : 'human'], faction: db.faction === 'human' ? 'zombie' : 'human', level: lvl, title: sp.elite ? 'Elite' : '', kind: 'enemy', archetype: sp.archetype, max_hp: maxHp(lvl) * 0.9, hp_start: maxHp(lvl) * 0.9, stats: { hp: 0, atk: 8 + 1.8 * lvl, def: 5 + 1.3 * lvl, spd: 9 + 0.5 * lvl }, abilities: [], gear: [] };
      } else if (isEcho) {
        foe = { name: 'Rogue', faction: db.faction === 'human' ? 'zombie' : 'human', level: db.level + 1, title: 'Stalker', kind: 'rogue', archetype: null, max_hp: maxHp(db.level + 1), hp_start: maxHp(db.level + 1), stats: { hp: 0, atk: 12 + 2 * db.level, def: 7 + 1.5 * db.level, spd: 10 + 0.6 * db.level }, abilities: [], gear: ['Crowbar'] };
      } else throw new HttpError(404, 'gone', 'Nothing there.');
      foe.stats = { ...foe.stats, atk: Math.round(foe.stats.atk), def: Math.round(foe.stats.def), spd: Math.round(foe.stats.spd), hp: Math.round(foe.max_hp) };
      const a = combatantMe();
      const { turns, win } = fight(foe, hash(db.n++, foe.level));
      const last = turns[turns.length - 1];
      db.hp = Math.max(1, last ? last.hp_a : db.hp);
      const base = 20 + 6 * foe.level;
      const rewards = win ? lootRewards(base, 0.35) : lootRewards(Math.round(base / 4), 0);
      if (win && m) db.defeated.push(id);
      grantXp(rewards); save();
      return { id: 'b' + db.n, kind: isEcho ? 'echo' : 'pve', a, b: foe, turns, winner: win ? 'a' : 'b', rewards, me: buildMe() } satisfies Battle;
    }
    case 'POST /api/open': {
      guard();
      const id = String(need(body, 'id'));
      if (db.defeated.includes(id)) throw new HttpError(404, 'gone', 'Already opened.');
      db.defeated.push(id);
      const loot = lootRewards(10 + 2 * db.level, 0.55);
      grantXp(loot); save();
      return { loot, me: buildMe() };
    }
    default: throw new HttpError(404, 'not_found', `Mock server has no ${method} ${path}.`);
  }
}

export function installMock() {
  setFetcher(async (url, init) => {
    await new Promise((r) => setTimeout(r, 60 + Math.random() * 120));
    const u = new URL(url, location.origin);
    const auth = (init.headers as Record<string, string> | undefined)?.Authorization === 'Bearer ' + TOKEN;
    const body = init.body ? JSON.parse(String(init.body)) : undefined;
    try {
      const data = route(init.method ?? 'GET', u.pathname, body, auth);
      return new Response(JSON.stringify(data), { status: 200 });
    } catch (e) {
      if (e instanceof HttpError) return new Response(JSON.stringify({ error: e.error, message: e.message }), { status: e.status });
      throw e;
    }
  });
  console.info('[outbreak] mock server active (src/dev/mock.ts)');
}
