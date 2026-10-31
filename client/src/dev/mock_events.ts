// World events for the offline mock (DESIGN.md section 18): the catalog rows, the Exchange and one event that is always running.
import type { CatalogCosmetic, CatalogEvent, CatalogExchangeItem, EventBrief, EventLive, EventUpcoming, EventsState, Faction, WorldEventType } from '../api';

const pair = (human: string, zombie: string): Record<Faction, string> => ({ human, zombie });

const ev = (
  id: WorldEventType, h: string, z: string, bh: string, bz: string, uh: string, uz: string, goal: string,
  per_player: number, min_target: number, tiers: [number, number, number], cosmetic: string | null, monthly = false,
): CatalogEvent => ({
  id, names: pair(h, z), blurb: pair(bh, bz), unit: pair(uh, uz), monthly, goal, per_player, min_target, tiers,
  salvage: monthly ? [500, 1400, 3000] : [250, 700, 1500], consolation: 0.5, cosmetic,
  title: monthly ? pair('Day Zero Survivor', 'Of the Turning') : null,
});

export const MOCK_EVENT_DEFS: CatalogEvent[] = [
  ev('blood_moon', 'Blood Moon', 'The Red Feast', 'After dark the elites walk and the streets fill up.', 'After dark the big ones wake and the streets run thick.', 'elites defeated', 'big ones put down', 'elites', 10, 15, [3, 10, 25], 'color_bloodmoon'),
  ev('supply_run', 'Supply Run', 'Carrion Rush', 'Caches and airdrops are everywhere, and richer.', 'Remains and drops everywhere, and fatter.', 'caches opened', 'remains opened', 'caches', 25, 30, [6, 20, 50], 'color_supply'),
  ev('horde', 'The Swarm', 'Pack Hunt', 'The whole district is moving. One kind of enemy is everywhere.', 'The whole district moves as one. One kind of prey is everywhere.', 'defeated', 'put down', 'archetype', 40, 50, [10, 40, 100], 'frame_horde'),
  ev('echo_week', 'Ghost Signal', 'The Hive Remembers', 'Echoes come thick and pay double.', 'The echoes crowd in and give more.', 'Echoes defeated', 'echoes put down', 'echo_wins', 6, 10, [2, 6, 14], 'frame_echo'),
  ev('last_light', 'Last Light', 'Feeding Frenzy', 'War points count double. Dawn patrols turn up bandages.', 'War points count double. Every kill feeds you.', 'war points', 'war points', 'war_points', 60, 90, [20, 60, 150], 'color_lastlight'),
  ev('day_zero', 'Day Zero', 'The Turning', 'Everything surges at once: elites, drops, double the work.', 'Everything surges at once: big ones, drops, more to feed on.', 'fights won and caches opened', 'kills and remains taken', 'actions', 150, 200, [25, 80, 200], 'frame_dayzero', true),
];

const colour = (id: string, h: string, z: string, text: string, survey: string, heat: string, event: WorldEventType | null, exchange = false): CatalogCosmetic =>
  ({ id, kind: 'color', names: pair(h, z), text, price: 0, survey, heat, unlock: null, event, exchange });
const frame = (id: string, h: string, z: string, text: string, event: WorldEventType | null, exchange = false): CatalogCosmetic =>
  ({ id, kind: 'frame', names: pair(h, z), text, price: 0, survey: null, heat: null, unlock: null, event, exchange });

export const MOCK_EVENT_COSMETICS: CatalogCosmetic[] = [
  colour('color_bloodmoon', 'Blood Moon Red', 'Red Feast', 'Earned in the Blood Moon event.', '#9B1C1C', '#FF5A5A', 'blood_moon'),
  colour('color_supply', 'Crate Orange', 'Carrion Orange', 'Earned in the Supply Run event.', '#B54A00', '#FF9A3D', 'supply_run'),
  colour('color_lastlight', 'Dawn Pink', 'Frenzy Pink', 'Earned in the Last Light event.', '#9A2F68', '#FF9CCB', 'last_light'),
  frame('frame_horde', 'Tally Marks', 'Claw Marks', 'Earned in the Swarm event.', 'horde'),
  frame('frame_echo', 'Static', 'Afterimage', 'Earned in the Echo event.', 'echo_week'),
  frame('frame_dayzero', 'Quarantine Seal', 'Open Wound', 'Earned in the monthly Day Zero event.', 'day_zero'),
  colour('color_gilt', 'Gilt Ink', 'Gilded Rot', 'Sold only at the Event Exchange.', '#6B5A12', '#F2E28B', null, true),
  frame('frame_gilt', 'Gilt Frame', 'Gilded Frame', 'Sold only at the Event Exchange.', null, true),
];

export const MOCK_EXCHANGE: CatalogExchangeItem[] = [
  { sku: 'ex_requisition', names: pair('Priority Requisition', 'Priority Cache'), text: 'Three item rolls at your level, Uncommon or better. You keep the best one.', price: 1200, limit: 5 },
  { sku: 'ex_crate', names: pair('Event Crate', 'Event Remains'), text: 'One item at your level, Rare or better with a better chance of Legendary, and two consumables.', price: 4000, limit: 2 },
  { sku: 'color_gilt', names: pair('Gilt Ink', 'Gilded Rot'), text: 'A callsign colour sold only at the Exchange.', price: 6000, limit: 1 },
  { sku: 'frame_gilt', names: pair('Gilt Frame', 'Gilded Frame'), text: 'A portrait frame sold only at the Exchange.', price: 9000, limit: 1 },
];

const HOUR = 3_600_000;
/** The event that is always on in the mock: started 20 hours ago, 28 to go, so the banner and card always have something to show. */
const SPAN = { start: -20 * HOUR, end: 28 * HOUR };

export interface MockEventState { mine: number; bought: Record<string, number> }

function target(): number { return 120; }

function progress(now: number): number {
  // The community moves a little every minute so the bar is not a still picture.
  return Math.min(target(), 38 + Math.floor((now / 60_000) % 40));
}

export function mockBrief(anchor: number, st: MockEventState, now = Date.now()): EventBrief {
  return { id: 1, type: 'blood_moon', kind: null, starts_at: anchor + SPAN.start, ends_at: anchor + SPAN.end, target: target(), progress: progress(now), mine: st.mine };
}

export function mockEvents(anchor: number, st: MockEventState, owned: string[], now = Date.now()): EventsState {
  const tiers = MOCK_EVENT_DEFS[0].tiers;
  const tier = (st.mine >= tiers[2] ? 3 : st.mine >= tiers[1] ? 2 : st.mine >= tiers[0] ? 1 : 0) as 0 | 1 | 2 | 3;
  const live: EventLive = {
    id: 1, type: 'blood_moon', kind: null, admin: false,
    starts_at: anchor + SPAN.start, ends_at: anchor + SPAN.end, active_players: 12,
    goal: { target: target(), progress: progress(now), done: progress(now) >= target() },
    district: { id: 'c23b', target: 8, progress: Math.min(8, 3 + Math.floor(st.mine / 2)), done: false },
    mine: { n: st.mine, tier, next_at: tier < 3 ? tiers[tier as 0 | 1 | 2] : null, goal_met: false },
  };
  const upcoming: EventUpcoming[] = [
    { type: 'last_light', kind: null, starts_at: anchor + 40 * HOUR, ends_at: anchor + 60 * HOUR },
    { type: 'supply_run', kind: null, starts_at: anchor + 7 * 24 * HOUR, ends_at: anchor + 9 * 24 * HOUR },
    { type: 'horde', kind: 'brute', starts_at: anchor + 9 * 24 * HOUR + 12 * HOUR, ends_at: anchor + 11 * 24 * HOUR },
  ];
  return {
    now,
    live,
    upcoming,
    exchange: {
      open: true,
      min_level: 10,
      items: MOCK_EXCHANGE.map((x) => ({ sku: x.sku, price: x.price, limit: x.limit, bought: st.bought[x.sku] ?? 0, owned: owned.includes(x.sku) })),
    },
  };
}
