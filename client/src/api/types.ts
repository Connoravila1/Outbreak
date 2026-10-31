// Types for every shape in docs/ARCHITECTURE.md. Times are unix milliseconds.

export type Faction = 'human' | 'zombie';
export type Slot = 'weapon' | 'armor' | 'utility';
export type Rarity = 'common' | 'uncommon' | 'rare' | 'legendary';

export interface Stats { hp: number; atk: number; def: number; spd: number }

export interface Item {
  uid: string;
  base: string;
  slot: Slot;
  rarity: Rarity;
  upgrade: number;
  perks: string[];
  unique: string | null;
  req: number;
  stats: Stats;
  power: number;
  scrap_value: number;
  upgrade_cost: number | null;
}

export interface Rewards {
  xp: number;
  salvage: number;
  items: Item[];
  consumables: Record<string, number>;
  war_points: number;
  level_up: { from: number; to: number; unlocks: string[] } | null;
}

export interface Mission {
  id: string;
  kind: string;
  text: string;
  target: number;
  progress: number;
  rewards: Rewards;
  claimed: boolean;
}

export interface Buff { kind: string; until: number }

export interface ClanRef { id: string; name: string; tag: string; role: string }

export interface PlayerRecord { wins: number; losses: number; contacts: number; echoes: number; caches: number; distance_m: number }

export interface Me {
  id: string;
  callsign: string;
  faction: Faction | null;
  level: number;
  xp: number;
  xp_next: number;
  title: string;
  hp: number;
  max_hp: number;
  downed_until: number | null;
  stats: Stats;
  base_stats: Stats;
  salvage: number;
  inventory_cap: number;
  equipped: Record<Slot, string | null>;
  items: Item[];
  consumables: Record<string, number>;
  abilities: { unlocked: string[]; equipped: string[]; slots: number };
  buffs: Buff[];
  missions: { daily: Mission[]; weekly: Mission | null; streak: number; resets_at: number };
  clan: ClanRef | null;
  avatar: Record<string, unknown> | null;
  pvp_protected: boolean;
  underdog_bonus: number;
  war_points_week: number;
  record: PlayerRecord;
}

export interface MeLite {
  hp: number;
  max_hp: number;
  downed_until: number | null;
  level: number;
  xp: number;
  xp_next: number;
  salvage: number;
}

export interface WorldEnemy {
  id: string; archetype: string; level: number; elite: boolean; tutorial?: boolean;
  lat: number; lon: number; expires_at: number;
}
export interface WorldCache {
  id: string; kind: 'cache' | 'airdrop'; lat: number; lon: number; expires_at: number;
}
export interface WorldEcho {
  id: string; level: number; faction: Faction; title: string; rogue: boolean;
  lat: number; lon: number; expires_at: number;
}
export interface WorldStronghold {
  id: string; lat: number; lon: number;
  clan: { tag: string; name: string; faction: Faction } | null;
}
export interface WorldRaid {
  id: string; boss: string; lat: number; lon: number; hp: number; max_hp: number;
  ends_at: number; fighters: number; can_attack_at: number;
}

export type EventType = 'contact' | 'echo_report' | 'level_up' | 'raid' | 'war_result' | 'clan';
export interface GameEvent {
  id: string;
  at: number;
  type: EventType;
  text: string;
  battle?: Battle;
  rewards?: Rewards;
}

export interface WorldView {
  now: number;
  me: MeLite;
  hostiles_near: boolean;
  enemies: WorldEnemy[];
  caches: WorldCache[];
  echoes: WorldEcho[];
  strongholds: WorldStronghold[];
  raids: WorldRaid[];
  events: GameEvent[];
}

export interface Combatant {
  name: string;
  faction: Faction;
  level: number;
  title: string;
  kind: 'player' | 'enemy' | 'echo' | 'rogue' | 'boss';
  archetype: string | null;
  max_hp: number;
  hp_start: number;
  stats: Stats;
  abilities: string[];
  gear: string[];
}

export interface Turn {
  actor: 'a' | 'b';
  ev: 'hit' | 'crit' | 'dodge' | 'ability' | 'dot' | 'heal' | 'revive';
  ability: string | null;
  dmg: number;
  heal: number;
  hp_a: number;
  hp_b: number;
}

export interface Battle {
  id: string;
  kind: 'pve' | 'pvp' | 'echo' | 'raid' | 'garrison';
  a: Combatant;
  b: Combatant;
  turns: Turn[];
  winner: 'a' | 'b';
  rewards: Rewards;
  me: Me;
}

// ---- catalog ----
export interface CatalogItem {
  id: string; slot: Slot; req: number;
  names: Record<Faction, string>; stats: Stats;
}
export interface CatalogUnique {
  id: string; base: string; names: Record<Faction, string>; lore: string; perks: string[];
}
export interface CatalogPerk { id: string; name: string; text: string }
export interface CatalogConsumable {
  id: string; names: Record<Faction, string>; text: string; price: number;
}
export interface CatalogAbility {
  id: string; level: number; names: Record<Faction, string>; text: string;
}
export interface CatalogEnemy { id: string; names: Record<Faction, string>; text: string; text_zombie?: string; note?: string }
export interface CatalogStoreEntry { sku: string; name: string; price: number; text: string }
export interface Catalog {
  version: number | string;
  items: CatalogItem[];
  uniques: CatalogUnique[];
  rarities: unknown;
  perks: CatalogPerk[];
  consumables: CatalogConsumable[];
  abilities: CatalogAbility[];
  enemies: CatalogEnemy[];
  levels: {
    xp_to_next: number[];
    titles: Record<Faction, string[]>;
    unlocks: { level: number; text: string }[];
  };
  store: CatalogStoreEntry[];
}

// ---- account ----
export interface Health { ok: boolean; version: string; players_online: number }
export interface FactionShare { share: number; players: number }
export interface Factions {
  human: FactionShare;
  zombie: FactionShare;
  underdog: Faction | null;
  underdog_bonus: number;
}
export interface RegisterResult { token: string; recovery_code: string; me: Me }
export interface RecoverResult { token: string; me: Me }

// ---- war / social ----
export interface WarState {
  week: number;
  ends_at: number;
  global: { human: number; zombie: number };
  district: { id: string; human: number; zombie: number } | null;
  top: { callsign: string; level: number; title: string; points: number }[];
  my_points: number;
}
export interface LeaderboardEntry {
  rank: number; callsign: string; level: number; title: string;
  faction: Faction; value: number; clan_tag: string | null;
}
export interface ClanSummary {
  id: string; name: string; tag: string; members: number; level_sum: number; faction: Faction;
}
export interface ClanMember {
  callsign: string; level: number; title: string; role: string; weekly_points: number;
}
export interface ClanDetail {
  id: string; name: string; tag: string; code: string;
  members: ClanMember[]; strongholds: number; perks: unknown;
}
export interface ClanMessage { id: string; callsign: string; text: string; at: number }

export interface ApiErrorBody { error: string; message: string }
