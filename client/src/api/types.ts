// Types for every shape in docs/ARCHITECTURE.md. Times are unix milliseconds.

export type Faction = 'human' | 'zombie';
export type Slot = 'weapon' | 'armor' | 'utility';
export type Rarity = 'common' | 'uncommon' | 'rare' | 'legendary';

export interface Stats { hp: number; atk: number; def: number; spd: number }

/** How a fight is approached; chosen before engaging. */
export type Stance = 'aggressive' | 'careful' | 'evasive';
/** Kinds of real place that hold a landmark cache. */
export type PlaceKind = 'pharmacy' | 'grocery' | 'hardware' | 'fuel' | 'police' | 'outfitter' | 'diner';

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

/** How a note is drawn: each form gets its own paper. */
export type NoteForm = 'notebook' | 'memo' | 'email' | 'chat' | 'receipt' | 'sticky' | 'radio' | 'poster' | 'letter' | 'review' | 'card';
export type NoteSetId = 'lantern' | 'starlite' | 'ordinary' | 'containment' | 'survey' | 'hunger' | 'zero' | 'road';
/** A note found with a payout; read it through the archive. */
export interface NoteRef { id: string; title: string; set: NoteSetId; rarity: Rarity; form: NoteForm }

export interface Rewards {
  xp: number;
  salvage: number;
  items: Item[];
  consumables: Record<string, number>;
  war_points: number;
  level_up: { from: number; to: number; unlocks: string[] } | null;
  /** Salvage from items that did not fit in the pack (already counted in `salvage`). */
  auto_scrapped?: number;
  /** Notes found with this payout (absent from older servers). */
  notes?: NoteRef[];
  /** Achievements this payout completed; their salvage is paid on top of `salvage`. */
  achievements?: EarnedAchievement[];
}

/** A newly earned achievement, named for the player's own faction. */
export interface EarnedAchievement {
  id: string; name: string; text: string; salvage: number; title: string | null; cosmetic: string | null;
}
export interface AchievementList {
  earned: { id: string; at: number }[];
  /** Where the player stands on everything an achievement counts, by metric. */
  progress: Record<string, number>;
  fresh?: EarnedAchievement[];
}
/** What the player has ever held. Anything not listed is still a silhouette. */
export interface Collection { bases: string[]; uniques: string[]; rarities: Rarity[] }
export type CosmeticKind = 'color' | 'frame';
export interface Cosmetics { owned: string[]; color: string | null; frame: string | null }

export interface NoteSet {
  id: NoteSetId; name: string; title: string; blurb: string;
  total: number; found: number; reward: number; claimed: boolean;
}
/** Locked notes carry only set and rarity. */
export interface ArchiveNote {
  id: string; set: NoteSetId; rarity: Rarity; locked: boolean;
  title: string | null; author: string | null; date: string | null; form: NoteForm | null;
  body: string | null; found_at: number | null;
}
export interface NoteArchive { sets: NoteSet[]; notes: ArchiveNote[] }

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

export interface PlayerRecord {
  wins: number; losses: number; contacts: number; echoes: number; caches: number; distance_m: number;
  /** Real-world fights only: Contact wins and losses, and Echo wins. */
  contacts_won: number; contacts_lost: number; echoes_won: number;
}

/** Lifetime rank from Contact wins. `next_at` / `next_name` are null at the top. */
export interface ContactRank { name: string; tier: number; wins: number; next_at: number | null; next_name: string | null }

/** How this survivor signs back in. A guest has no providers: it lives only on this phone. */
export interface AccountInfo { guest: boolean; providers: string[]; email: string | null }

export interface Me {
  id: string;
  /** Null until the player chooses one. */
  callsign: string | null;
  /** A moderator reset the callsign: the player must choose a new one before playing. */
  must_rename: boolean;
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
  /** Price of the next inventory expansion; it rises with each one bought. */
  expansion_price?: number;
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
  contact_rank: ContactRank;
  account: AccountInfo;
  /** Saved default stance, used in Contact. */
  stance: Stance;
  /** Fights per enemy archetype; hints unlock at 3. */
  bestiary: Record<string, number>;
  /** Notes found, and how many this faction can find in all. */
  notes?: { found: number; total: number };
  /** Cosmetic titles from completed note sets and achievements. */
  titles_extra?: string[];
  /** Callsign colours and avatar frames owned, and the ones worn. */
  cosmetics?: Cosmetics;
  achievements?: { earned: number; total: number };
  /** The phone says its location is simulated (a mock provider): real-world fights, walking XP and war points are off. */
  simulated_location: boolean;
}

export interface MeLite {
  simulated_location: boolean;
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

/** A real place from the map's own data, reported by this client (key: stable OSM id or a coordinate hash). */
export interface PlaceReport { key: string; kind: PlaceKind; lat: number; lon: number; name?: string }
export interface WorldLandmark {
  id: string; kind: PlaceKind; name: string | null; lat: number; lon: number;
  available: boolean; available_at: number | null;
}
export interface WorldTime { phase: 'day' | 'night'; changes_at: number }

export type EventType = 'contact' | 'echo_report' | 'level_up' | 'raid' | 'war_result' | 'clan' | 'achievement';
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
  landmarks: WorldLandmark[];
  time: WorldTime;
  strongholds: WorldStronghold[];
  raids: WorldRaid[];
  events: GameEvent[];
}

/** One worn item as its owner's faction names it. Drawn on a silhouette; carries no id and no stats. */
export interface GearDetail { slot: Slot; name: string; rarity: Rarity; upgrade: number; unique: boolean }

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
  /** The kit by slot, for drawing it. Empty for monsters. */
  gear_detail?: GearDetail[];
  /** How this side fought; only real players (Contact) have one. */
  stance?: Stance | null;
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
  /** The stance you fought in. */
  stance?: Stance | null;
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
  id: string; base: string; names: Record<Faction, string>; lore: string; lore_zombie?: string; perks: string[];
}
export interface CatalogPerk { id: string; name: string; text: string }
export interface CatalogConsumable {
  id: string; names: Record<Faction, string>; text: string; price: number;
}
export interface CatalogAbility {
  id: string; level: number; faction?: Faction; names: Record<Faction, string>; text: string;
}
export interface CatalogEnemy {
  id: string; names: Record<Faction, string>; text: string; text_zombie?: string; note?: string;
  /** The stance that beats it / that it punishes, and the line learned after 3 fights. */
  counter?: Stance | null; punished?: Stance | null; hint?: string; hint_zombie?: string;
}
export interface CatalogStance { id: Stance; names: Record<Faction, string>; text: string }
export interface CatalogPlace { id: PlaceKind; names: Record<Faction, string>; text: string; text_zombie: string }
export interface CatalogAchievement {
  id: string; group: string; names: Record<Faction, string>; text: string;
  /** What it counts (a key of `AchievementList.progress`) and how many it takes. */
  metric: string; need: number; salvage: number;
  title: Record<Faction, string> | null; cosmetic: string | null;
}
export interface CatalogCosmetic {
  id: string; kind: CosmeticKind; names: Record<Faction, string>; text: string;
  /** Salvage; 0 means it is earned, not bought (`unlock` names the achievement). */
  price: number;
  /** Callsign colours: the hex to draw it in on paper (Survey) and on thermal (Heat). */
  survey: string | null; heat: string | null;
  unlock: string | null;
}
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
  stances?: CatalogStance[];
  places?: CatalogPlace[];
  achievements?: CatalogAchievement[];
  cosmetics?: CatalogCosmetic[];
  levels: {
    xp_to_next: number[];
    titles: Record<Faction, string[]>;
    /** `key` names the unlock (e.g. "store", "raids"); the first-time explainers hang off it. */
    unlocks: { level: number; key: string; text: string }[];
  };
  store: CatalogStoreEntry[];
}

// ---- account ----
/** Which sign-in providers the server has set up (and the IDs a browser needs). */
export interface ProviderStatus {
  google: boolean;
  apple: boolean;
  dev: boolean;
  google_web_client_id?: string | null;
  apple_web_service_id?: string | null;
}
/** A self-hosted tile source the server points the map at (absent: OpenFreeMap). */
export interface TilesAdvert { pmtiles: string; glyphs?: string | null }
/** Where to get a newer client; either may be null. */
export interface StoreLinks { android: string | null; ios: string | null }
export interface Health {
  ok: boolean; version: string; players_online: number; providers?: ProviderStatus; tiles?: TilesAdvert | null;
  /** The oldest client the server accepts (null: any). */
  min_client?: string | null;
  store?: StoreLinks | null;
}
export interface FactionShare { share: number; players: number }
export interface Factions {
  human: FactionShare;
  zombie: FactionShare;
  underdog: Faction | null;
  underdog_bonus: number;
}
export interface RegisterResult { token: string; me: Me }
export type AuthProvider = 'google' | 'apple' | 'dev';
/** What the provider hands us to prove who the player is (`subject`/`email` are dev-only). */
export interface Credentials { id_token?: string; nonce?: string; subject?: string; email?: string }
export interface AuthResult { token: string; me: Me; created: boolean }

// ---- war / social ----
export interface WarState {
  week: number;
  ends_at: number;
  global: { human: number; zombie: number };
  district: { id: string; human: number; zombie: number } | null;
  top: { callsign: string; callsign_color?: string | null; level: number; title: string; points: number }[];
  my_points: number;
}
export interface LeaderboardEntry {
  rank: number; callsign: string; callsign_color?: string | null; level: number; title: string;
  faction: Faction; value: number; clan_tag: string | null;
}
export interface ClanSummary {
  id: string; name: string; tag: string; members: number; level_sum: number; faction: Faction;
}
export interface ClanMember {
  callsign: string; callsign_color?: string | null; level: number; title: string; role: string; weekly_points: number;
}
export interface ClanDetail {
  id: string; name: string; tag: string; code: string;
  members: ClanMember[]; strongholds: number; perks: { xp_bonus: number; strongholds: number };
}
export interface ClanMessage { id: string; callsign: string; callsign_color?: string | null; text: string; at: number }

export interface ApiErrorBody { error: string; message: string }

/** The 426 `update_required` answer: where to get a newer client (null: the server named no store). */
export interface UpdateRequired { store: StoreLinks | null }

/** The 403 `banned` answer: why, and until when (null: for good). */
export interface Banned { reason: string; until: number | null }

/** One crash or error report: no position, URL query or request body ever goes in it. */
export interface ClientErrorReport {
  message: string;
  stack: string;
  version: string;
  platform: string;
  screen: string;
  ts: number;
}

export type ReportKind = 'player' | 'clan' | 'message';
export type ReportReason = 'name' | 'harassment' | 'cheating' | 'other';
