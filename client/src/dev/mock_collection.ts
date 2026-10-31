/*
 * Mock side of achievements, the collection log and cosmetics (see mock.ts). A trimmed copy of the
 * server's lists (server/src/game/achievements.zig, cosmetics.zig) so the screens have something to
 * show offline. Not authoritative; the server is.
 */
import type { CatalogAchievement, CatalogCosmetic, EarnedAchievement, Faction, Rarity } from '../api/types';

const pair = (human: string, zombie: string) => ({ human, zombie });
const km = 1000;

type Row = [id: string, group: string, human: string, zombie: string, text: string, metric: string, need: number, salvage: number, title?: [string, string], cosmetic?: string];
const ROWS: Row[] = [
  ['walk_1', 'On foot', 'First Steps', 'First Shamble', 'Walk 1 km.', 'distance_m', 1 * km, 20],
  ['walk_10', 'On foot', 'Footslogger', 'Restless Legs', 'Walk 10 km.', 'distance_m', 10 * km, 60],
  ['walk_100', 'On foot', 'Long Haul', 'No Rest', 'Walk 100 km.', 'distance_m', 100 * km, 250, ['Wayfarer', 'Drifter']],
  ['wins_1', 'The fight', 'First Kill', 'First Taste', 'Win a fight against an enemy.', 'pve_wins', 1, 10],
  ['wins_25', 'The fight', 'Getting Good', 'Fed', 'Win 25 fights against enemies.', 'pve_wins', 25, 40],
  ['elite_1', 'The fight', 'Gold Ring', 'Marked Prey', 'Defeat an elite.', 'elites', 1, 30],
  ['contact_1', 'Contact', 'Blooded', 'First Blood Drawn', 'Win a Contact.', 'contacts_won', 1, 40],
  ['echo_1', 'Contact', 'Hearing Voices', 'Old Footsteps', 'Beat an Echo.', 'echoes_won', 1, 25],
  ['cache_25', 'Out in the world', 'Scavenger', 'Nose Down', 'Open 25 caches, airdrops or places.', 'caches', 25, 50],
  ['notes_10', 'What was left', 'Reader', 'Page Chewer', 'Find 10 notes.', 'notes_found', 10, 50],
  ['set_1', 'What was left', 'Complete Set', 'Whole Story', 'Claim a finished set of notes.', 'sets_claimed', 1, 100],
  ['set_4', 'What was left', 'Archivist', 'Page-Eater', 'Claim four finished sets of notes.', 'sets_claimed', 4, 300, ['Archivist', 'Page-Eater'], 'frame_bloom'],
  ['level_5', 'Standing', 'Out of the Shelter', 'Out of the Dark', 'Reach level 5.', 'level', 5, 20],
  ['level_10', 'Standing', 'Somebody', 'Somebody Hungry', 'Reach level 10.', 'level', 10, 50],
  ['level_50', 'Standing', 'Still Standing', 'Everlasting', 'Reach level 50.', 'level', 50, 800, undefined, 'frame_wreath'],
  ['rare_1', 'Gear', 'Something Good', 'Something Rich', 'Find a Rare item.', 'best_rarity', 3, 30],
  ['legendary_1', 'Gear', 'Legend in the Pack', 'Legend in the Gut', 'Find a Legendary item.', 'best_rarity', 4, 100],
  ['unique_1', 'Gear', 'A Name on It', 'A Name in It', 'Find a named Legendary.', 'uniques_found', 1, 200, ['Heirloom Bearer', 'Trophy Taker'], 'color_gold'],
  ['upgrade_5', 'Gear', 'Tuned Up', 'Hardened', 'Upgrade an item to +5.', 'best_upgrade', 5, 50],
  ['upgrade_10', 'Gear', 'Masterwork', 'Perfected', 'Upgrade an item to +10.', 'best_upgrade', 10, 200, ['Tinkerer', 'Stitcher']],
];

export const MOCK_ACHIEVEMENTS: CatalogAchievement[] = ROWS.map(([id, group, h, z, text, metric, need, salvage, title, cosmetic]) => ({
  id, group, names: pair(h, z), text, metric, need, salvage, title: title ? pair(title[0], title[1]) : null, cosmetic: cosmetic ?? null,
}));

type Cos = [id: string, kind: 'color' | 'frame', human: string, zombie: string, text: string, price: number, survey?: string, heat?: string];
const COS: Cos[] = [
  ['color_amber', 'color', 'Hazard Amber', 'Fever Amber', 'Your callsign in amber.', 250, '#A5690B', '#FFB347'],
  ['color_blue', 'color', 'Survey Blue', 'Cold Blue', 'Your callsign in blue.', 250, '#2F6EA3', '#8FB3E8'],
  ['color_moss', 'color', 'Moss', 'Mould', 'Your callsign in green.', 300, '#3E6B36', '#9CCB7E'],
  ['color_oxblood', 'color', 'Oxblood', 'Arterial', 'Your callsign in dark red.', 300, '#8E2424', '#FF7A7A'],
  ['color_violet', 'color', 'Violet Ink', 'Bruise', 'Your callsign in violet.', 400, '#5B459A', '#BBA2F0'],
  ['color_teal', 'color', 'Verdigris', 'Gill', 'Your callsign in teal.', 400, '#1D6E69', '#6FD6CB'],
  ['color_gold', 'color', 'Heirloom Gold', 'Trophy Gold', 'Your callsign in gold. Earned by finding a named Legendary.', 0, '#8F6A00', '#FFD36B'],
  ['frame_grease', 'frame', 'Grease Pencil', 'Scorch Ring', 'A hand-drawn loop around your portrait.', 400],
  ['frame_tape', 'frame', 'Hazard Tape', 'Bandage Wrap', 'Striped tape, wound around the edge.', 500],
  ['frame_stitch', 'frame', 'Stitched', 'Sutured', 'A seam of heavy stitches.', 600],
  ['frame_reticle', 'frame', 'Crosshair', 'Prey Sight', 'Corner brackets and tick marks.', 800],
  ['frame_barbed', 'frame', 'Barbed Wire', 'Bramble', 'A ring of wire and barbs.', 1000],
  ['frame_bloom', 'frame', 'Kessler Bloom', 'The Bloom', 'Spores creeping round the frame. Earned by claiming four sets of notes.', 0],
  ['frame_wreath', 'frame', 'Laurels', 'Thorn Crown', 'A wreath for the last survivor. Earned by reaching level 50.', 0],
  ['color_tag', 'color', 'Bus Stop Tag', 'Livid', 'Your callsign in spray-can magenta. Found in the field.', 0, '#A0246B', '#FF8AC8'],
  ['color_glow', 'color', 'Dead Glowstick', 'Marrow Glow', 'Your callsign in a dying chemical green. Found in the field.', 0, '#5A7A0A', '#D4F26B'],
  ['frame_fence', 'frame', 'Cut Fence', 'Rib Cage', 'A scrap of chain-link, bent round your portrait. Found in the field.', 0],
  ['frame_flare', 'frame', 'Spent Flare', 'Cinder Crown', 'The last sparks of a road flare. Found in the field.', 0],
];

export const MOCK_COSMETICS: CatalogCosmetic[] = COS.map(([id, kind, h, z, text, price, survey, heat]) => ({
  id, kind, names: pair(h, z), text, price, survey: survey ?? null, heat: heat ?? null,
  unlock: ROWS.find((r) => r[9] === id)?.[0] ?? null,
  found: text.endsWith('Found in the field.'),
}));

/** What the mock keeps per player for all of this. */
export interface CollectionState {
  earned: { id: string; at: number }[];
  owned: string[];
  color: string | null;
  frame: string | null;
  bases: string[];
  uniques: string[];
  rarities: Rarity[];
  elites: number;
  bestUp?: number;
}
export const freshCollection = (): CollectionState => ({ earned: [], owned: [], color: null, frame: null, bases: [], uniques: [], rarities: [], elites: 0 });

export interface Inputs {
  distance_m: number; wins: number; contacts_won: number; echoes_won: number; caches: number; level: number;
  notes: number; sets: number; bestUpgrade: number;
}

const RARITY_AT: Record<Rarity, number> = { common: 1, uncommon: 2, rare: 3, legendary: 4 };

export function metricsOf(c: CollectionState, i: Inputs): Record<string, number> {
  return {
    distance_m: i.distance_m,
    pve_wins: Math.max(0, i.wins - i.contacts_won - i.echoes_won),
    elites: c.elites,
    raid_hits: 0, raid_kills: 0,
    contacts_won: i.contacts_won, echoes_won: i.echoes_won,
    caches: i.caches, airdrops: 0, landmarks: 0,
    notes_found: i.notes, sets_claimed: i.sets,
    level: i.level,
    best_rarity: Math.max(0, ...c.rarities.map((r) => RARITY_AT[r])),
    uniques_found: c.uniques.length, bases_found: c.bases.length,
    best_upgrade: i.bestUpgrade,
    missions: 0, best_streak: 0, war_points: 0, days: 0,
  };
}

/** Earn whatever is now met. Returns the new ones; the caller pays the salvage. */
export function earnNew(c: CollectionState, faction: Faction, i: Inputs, now: number): EarnedAchievement[] {
  const m = metricsOf(c, i);
  const out: EarnedAchievement[] = [];
  for (const a of MOCK_ACHIEVEMENTS) {
    if (c.earned.some((e) => e.id === a.id) || (m[a.metric] ?? 0) < a.need) continue;
    c.earned.push({ id: a.id, at: now });
    if (a.cosmetic && !c.owned.includes(a.cosmetic)) c.owned.push(a.cosmetic);
    out.push({ id: a.id, name: a.names[faction], text: a.text, salvage: a.salvage, title: a.title ? a.title[faction] : null, cosmetic: a.cosmetic });
  }
  return out;
}

export function titlesFrom(c: CollectionState, faction: Faction): string[] {
  return c.earned.map((e) => MOCK_ACHIEVEMENTS.find((a) => a.id === e.id)?.title?.[faction]).filter((t): t is string => !!t);
}
