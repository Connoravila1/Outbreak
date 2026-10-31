// First-time explainers for what each level unlocks. The levels and keys come from the server's
// catalog (`levels.unlocks`); the wording is UI copy and lives here, one voice per faction.
// What has been shown is stored as the level last synced plus the cards still waiting.
import { computed, effect, signal } from '@preact/signals';
import type { Faction } from '../api';
import { KEYS, storage } from '../api/storage';
import { catalog, faction, me, tab, type TabId } from '../state/store';
import { abilityName } from '../gear/util';

export interface Entry { key: string; level: number; text: string }
export interface Card { title: string; body: string; act?: string; tab?: TabId; anchor?: string }

interface Saved { level: number; pending: string[] }

/** Where the card's button goes. Cards without one only dismiss. */
const GO: Record<string, { tab: TabId; anchor?: string }> = {
  store: { tab: 'you', anchor: 'store' },
  ability_slot_1: { tab: 'gear', anchor: 'abilities' },
  ability_7: { tab: 'gear', anchor: 'abilities' },
  ability_18: { tab: 'gear', anchor: 'abilities' },
  ability_33: { tab: 'gear', anchor: 'abilities' },
  ability_42: { tab: 'gear', anchor: 'abilities' },
  ability_slot_2: { tab: 'gear', anchor: 'abilities' },
  ability_slot_3: { tab: 'gear', anchor: 'abilities' },
  upgrading: { tab: 'gear' },
  contact: { tab: 'map' },
  missions: { tab: 'tasks' },
  echoes: { tab: 'map' },
  airdrops: { tab: 'map' },
  clans: { tab: 'war' },
  territory: { tab: 'map' },
  raids: { tab: 'map' },
};

/** The ability (or abilities) that arrive at a level, as "Name: what it does". */
function abilitiesAt(level: number, f: Faction): string {
  const c = catalog.value;
  if (!c) return '';
  return c.abilities
    .filter((a) => a.level === level && (!a.faction || a.faction === f))
    .map((a) => `${abilityName(a.id, f)}: ${a.text}.`.replace(/\.\.$/, '.'))
    .join(' ');
}

type Copy = (level: number, f: Faction) => { h: [string, string, string?]; z: [string, string, string?] };

const abilityCard = (h: string, z: string): Copy => (level, f) => {
  const a = abilitiesAt(level, f);
  const lc = a.toLowerCase();
  return {
    h: [h, `${a} Slots are limited, so equip it only if it fits how you fight.`.trim(), 'Open Gear'],
    z: [z, `${lc} your slots are few. take it only if it suits the hunt.`.trim(), 'feel for it'],
  };
};

const COPY: Record<string, Copy> = {
  store: () => ({
    h: ['The Store', 'Salvage buys heals, buffs and more room in your pack. You earn it by scrapping spare gear and winning fights. Spend a little on a heal so one bad fight does not end your day.', 'Open the Store'],
    z: ['trade', 'salvage buys what your body will not make: meals, strength, room to carry. tear down a spare claw, then trade for something to eat.', 'go and trade'],
  }),
  ability_slot_1: abilityCard('Your first ability', 'a first instinct'),
  ability_slot_2: abilityCard('Ability slot 2', 'a second instinct'),
  ability_slot_3: abilityCard('Ability slot 3', 'a third instinct'),
  ability_7: abilityCard('New ability', 'a new instinct'),
  ability_18: abilityCard('New ability', 'a new instinct'),
  ability_33: abilityCard('New ability', 'a new instinct'),
  ability_42: abilityCard('New ability', 'a new instinct'),
  upgrading: () => ({
    h: ['Item upgrading', 'Salvage can raise a piece of gear up to +10, four percent stronger a step. It is the best use of salvage on a favourite you do not plan to replace. Start with your weapon.', 'Open Gear'],
    z: ['sharpen', 'feed salvage to a piece of you and it grows, a little each time, up to ten. start with whatever does the killing.', 'go to your kit'],
  }),
  contact: () => ({
    h: ['Real-world fights', 'Your protection is over. Another player in range can now find you, and you them. They are anonymous: only faction, level, title and gear show. Wins build your Contact rank, so keep your kit current.', 'Back to the map'],
    z: ['hunted now', 'the gentle start is over. someone real can smell you from here, and you them. no names, only what they carry. win and your rank climbs.', 'back to the map'],
  }),
  missions: () => ({
    h: ['Weekly mission', 'A weekly mission now joins your three dailies. It pays well, with a guaranteed Rare or better item. Check Tasks and start on it early.', 'Open Tasks'],
    z: ['the long hunt', 'one long hunt now sits beside the daily ones. it pays richly, and a good piece of gear. see what it asks and start early.', 'see the hunts'],
  }),
  echoes: () => ({
    h: ['Echoes', 'An Echo is a recorded copy of a real player of your level, always labelled as one. Beat it for XP and loot with nobody on the other end. Tap one on the map when it is in range.', 'Back to the map'],
    z: ['echoes', 'an echo is what is left of a real player, and it always says so. beat it for blood and loot, and no one is hurt. look for one on the map.', 'back to the map'],
  }),
  airdrops: () => ({
    h: ['Airdrops', 'Airdrops now show on the map. They hold better loot than crates, with three times the Legendary chance, but they only last 45 minutes. Walk to one and open it.', 'Back to the map'],
    z: ['drops from above', 'things fall from the sky now, and you can feel them. richer than remains, and gone in forty-five minutes. go and open one.', 'back to the map'],
  }),
  clans: () => ({
    h: ['Clans', 'A clan is a team of up to 50 Survivors with its own chat and board. Its members\' points count together, and clans can hold ground. Join one with an invite code, or found your own.', 'Open the War tab'],
    z: ['the pack', 'a pack is up to fifty of you, hunting under one tag. what you take, it takes. join one with a code, or start your own.', 'find a pack'],
  }),
  territory: () => ({
    h: ['Strongholds', 'You can now plant a flag on a Stronghold, a fixed point on the map. Held ground pays your whole clan salvage and war points every day. Buy a flag in the Store, then walk to one.', 'Back to the map'],
    z: ['claim ground', 'old strongholds sit on the map and you can take them now. held ground feeds the whole pack. trade for a marker, then go and plant it.', 'back to the map'],
  }),
  raids: () => ({
    h: ['Raids', 'On weekends a boss appears at a Stronghold, and everyone nearby fights it together. Your damage counts toward its shared HP, and your share decides your reward. You can strike once an hour.', 'Back to the map'],
    z: ['the big kill', 'on weekends something huge walks out of a stronghold. everyone nearby tears at it, and your share is your reward. once an hour.', 'back to the map'],
  }),
  legendary: () => ({
    h: ['Legendary luck', 'Legendary items now drop half again as often. Nothing to do but keep opening caches and winning fights.'],
    z: ['luckier', 'the rarest things find you half again as often now. keep feeding. keep opening.'],
  }),
};

/** The card for an unlock, in this faction's voice. Null for keys with no copy (new server, old client). */
export function cardFor(e: Entry, f: Faction): Card | null {
  const make = COPY[e.key];
  if (!make) return null;
  const c = make(e.level, f)[f === 'zombie' ? 'z' : 'h'];
  const go = GO[e.key];
  return { title: c[0], body: c[1], ...(c[2] && go ? { act: c[2], tab: go.tab, ...(go.anchor ? { anchor: go.anchor } : {}) } : {}) };
}

/** Every unlock that has a card, lowest level first. */
export const entries = computed<Entry[]>(() => (catalog.value?.levels.unlocks ?? [])
  .filter((u) => u.level > 1 && u.key in COPY)
  .map((u) => ({ key: u.key, level: u.level, text: u.text })));

const load = (): Saved | null => {
  const s = storage.getJSON<Partial<Saved> | null>(KEYS.guide, null);
  return s && typeof s.level === 'number' && Array.isArray(s.pending) ? { level: s.level, pending: s.pending.filter((k) => typeof k === 'string') } : null;
};

const saved = signal<Saved | null>(load());
const persist = (s: Saved) => { saved.value = s; storage.setJSON(KEYS.guide, s); };

/** Keys whose card is waiting, in order. */
export const pending = computed<Entry[]>(() => {
  const keys = saved.value?.pending ?? [];
  return keys.map((k) => entries.value.find((e) => e.key === k)).filter((e): e is Entry => !!e);
});

/**
 * Work out what is new since last time. Crossing a threshold queues its card. The very first sync on
 * a device only queues the newest unlock group, so a veteran gets one reminder, not seventeen.
 */
export function syncGuide(level: number, list: Entry[]) {
  const s = saved.peek();
  if (!list.length) return;
  if (!s) {
    const top = list.filter((e) => e.level <= level).reduce((m, e) => Math.max(m, e.level), 0);
    persist({ level, pending: top ? list.filter((e) => e.level === top).map((e) => e.key) : [] });
    return;
  }
  if (level <= s.level) return;
  const fresh = list.filter((e) => e.level > s.level && e.level <= level).map((e) => e.key);
  persist({ level, pending: [...s.pending, ...fresh.filter((k) => !s.pending.includes(k))] });
}

/** The player has read the first waiting card. */
export function dismissCard(key: string) {
  const s = saved.peek();
  if (s) persist({ ...s, pending: s.pending.filter((k) => k !== key) });
}

/** A card opened from the Field manual, not from the queue. */
export const reading = signal<string | null>(null);

/**
 * Set when a card's button took the player somewhere: the cards still waiting hold back until they
 * move on to another tab, so the next one does not cover the place they were just sent to.
 */
export const holdAt = signal<TabId | null>(null);
effect(() => { if (holdAt.value && tab.value !== holdAt.value) holdAt.value = null; });

/** Opens the screen a card points to, then scrolls to the section if it names one. */
export function goTo(c: Card) {
  if (!c.tab) return;
  tab.value = c.tab;
  holdAt.value = c.tab;
  const a = c.anchor;
  if (a) window.setTimeout(() => document.getElementById(a)?.scrollIntoView({ block: 'start', behavior: 'smooth' }), 80);
}

effect(() => {
  const lvl = me.value?.level;
  const list = entries.value;
  if (lvl != null && faction.value) syncGuide(lvl, list);
});

/** For tests. */
export function resetGuide() { saved.value = null; storage.remove(KEYS.guide); reading.value = null; }
