import { signal } from '@preact/signals';
import { api, type CatalogEvent, type EventsState, type Faction, type WorldEventType } from '../api';
import { catalog, faction } from '../state/store';
import { scheduleEventStarts } from '../native/notify';

/** What `GET /api/events` last said: the live event, the next ones, the Exchange. */
export const eventsState = signal<EventsState | null>(null);

const STALE_MS = 5 * 60_000;
let loadedAt = 0;
let loading = false;

/** Fetch the events state (at most every five minutes unless `force`), and keep the start alerts in step with it. */
export async function refreshEvents(force = false): Promise<void> {
  if (loading || (!force && eventsState.peek() && Date.now() - loadedAt < STALE_MS)) return;
  loading = true;
  try {
    const s = await api.events();
    eventsState.value = s;
    loadedAt = Date.now();
    void scheduleEventStarts(s.upcoming.slice(0, 4).map((u) => ({ at: u.starts_at, ...startAlert(u.type, u.kind) })));
  } catch { /* the card says nothing is running until the next try */ } finally { loading = false; }
}

/** A banner or poll saw an event id the card has not loaded yet. */
export function noteLiveEvent(id: number | null | undefined): void {
  const have = eventsState.peek()?.live?.id ?? null;
  if ((id ?? null) !== have) void refreshEvents(true);
  else if (id != null) void refreshEvents();
}

export function eventDef(type: WorldEventType): CatalogEvent | undefined {
  return catalog.value?.events?.find((e) => e.id === type);
}

const side = (): Faction => faction.value ?? 'human';

/** "The Swarm" / "Pack Hunt": the event as the player's side names it. */
export function eventName(type: WorldEventType): string {
  return eventDef(type)?.names[side()] ?? type.replace('_', ' ');
}

/** The swarm's archetype in the player's words ("Bloaters"), or null. */
export function kindName(kind: string | null | undefined): string | null {
  if (!kind) return null;
  const e = catalog.value?.enemies.find((x) => x.id === kind);
  return e?.names[side()] ?? kind;
}

/** What the goal counts, in words: "elites defeated", "Bloaters defeated". */
export function goalUnit(type: WorldEventType, kind: string | null | undefined): string {
  const def = eventDef(type);
  if (!def) return '';
  const k = kindName(kind);
  return type === 'horde' && k ? `${k}${k.endsWith('s') ? '' : 's'} ${def.unit[side()]}` : def.unit[side()];
}

export function cosmeticName(id: string | null | undefined): string | null {
  if (!id) return null;
  return catalog.value?.cosmetics?.find((c) => c.id === id)?.names[side()] ?? null;
}

function startAlert(type: WorldEventType, kind: string | null): { title: string; body: string } {
  const def = eventDef(type);
  const heat = side() === 'zombie';
  const name = def?.names[side()] ?? type;
  const k = type === 'horde' ? kindName(kind) : null;
  return {
    title: heat ? `${name.toLowerCase()} begins.` : `${name} has begun`,
    body: (heat ? def?.blurb.zombie.toLowerCase() : def?.blurb.human) ?? (k ? `${k} everywhere.` : ''),
  };
}
