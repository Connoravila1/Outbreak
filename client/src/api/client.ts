import { KEYS, storage } from './storage';
import type * as T from './types';

export class ApiError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
  /** `{error, message}` as the server sends it. */
  toJSON(): T.ApiErrorBody { return { error: this.code, message: this.message }; }
}

export type Fetcher = (url: string, init: RequestInit) => Promise<Response>;
let fetcher: Fetcher = (url, init) => fetch(url, init);
/** Used by src/dev/mock.ts to stand in for the server. */
export function setFetcher(f: Fetcher) { fetcher = f; }

export function getServerUrl(): string {
  const stored = storage.get(KEYS.server);
  const env = (import.meta.env.VITE_SERVER_URL as string | undefined) ?? '';
  return (stored ?? env).replace(/\/+$/, '');
}
export function setServerUrl(url: string) {
  const clean = url.trim();
  if (clean) storage.set(KEYS.server, clean); else storage.remove(KEYS.server);
}

export const getToken = () => storage.get(KEYS.token);
export function setToken(token: string | null) {
  if (token) storage.set(KEYS.token, token); else storage.remove(KEYS.token);
}

let onUnauthorized: (() => void) | null = null;
export function setUnauthorizedHandler(h: () => void) { onUnauthorized = h; }
/** Called for the 403 `banned` answer, which any authed request can get. */
let onBanned: ((b: T.Banned) => void) | null = null;
export function setBannedHandler(h: (b: T.Banned) => void) { onBanned = h; }
/** Called for the 426 `update_required` answer, which any request can get once the server raises its minimum. */
let onUpdateRequired: ((u: T.UpdateRequired) => void) | null = null;
export function setUpdateHandler(h: (u: T.UpdateRequired) => void) { onUpdateRequired = h; }

/** This build's version (package.json), sent on every request so the server can ask old clients to update. */
export const CLIENT_VERSION: string = __APP_VERSION__;

async function request<R>(method: 'GET' | 'POST' | 'DELETE', path: string, body?: unknown, base?: string): Promise<R> {
  const headers: Record<string, string> = { Accept: 'application/json', 'X-Outbreak-Client': CLIENT_VERSION };
  const token = getToken();
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  let res: Response;
  try {
    res = await fetcher((base ?? getServerUrl()) + path, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new ApiError(0, 'network', 'Cannot reach the server.');
  }
  let data: unknown = null;
  const text = await res.text();
  if (text) {
    try { data = JSON.parse(text); } catch { /* non-JSON body */ }
  }
  if (!res.ok) {
    const e = (data ?? {}) as Partial<T.ApiErrorBody>;
    if (res.status === 401 && onUnauthorized) onUnauthorized();
    if (res.status === 426 && e.error === 'update_required' && onUpdateRequired) {
      const s = (data as { store?: Partial<T.StoreLinks> | null } | null)?.store;
      onUpdateRequired({ store: s ? { android: s.android ?? null, ios: s.ios ?? null } : null });
    }
    if (res.status === 403 && e.error === 'banned' && onBanned) {
      const b = data as Partial<T.Banned>;
      onBanned({ reason: b.reason ?? '', until: typeof b.until === 'number' ? b.until : null });
    }
    throw new ApiError(res.status, e.error ?? 'http_' + res.status, e.message ?? `Server error (${res.status}).`);
  }
  return data as R;
}

const get = <R>(p: string, base?: string) => request<R>('GET', p, undefined, base);
const post = <R>(p: string, b: unknown = {}) => request<R>('POST', p, b);
const del = <R>(p: string) => request<R>('DELETE', p);

export const api = {
  // account
  /** `base` tests a server URL that is not saved yet. */
  health: (base?: string) => get<T.Health>('/api/health', base?.trim().replace(/\/+$/, '')),
  catalog: () => get<T.Catalog>('/api/catalog'),
  factions: () => get<T.Factions>('/api/factions'),
  /** Creates a guest. The callsign comes later (`setCallsign`). */
  register: (terms: number) => post<T.RegisterResult>('/api/register', { terms }),
  /** Accept the terms now in force (the re-accept sheet). */
  acceptTerms: (version: number) => post<{ me: T.Me }>('/api/terms', { version }),
  setCallsign: (callsign: string) => post<{ me: T.Me }>('/api/callsign', { callsign }),
  /** Sign in (or create) with a provider; a guest's token, if sent, is linked or replaced. */
  authSignIn: (provider: T.AuthProvider, c: T.Credentials, opts: { switch?: boolean; terms?: number } = {}) =>
    post<T.AuthResult>('/api/auth/' + provider, { ...c, ...(opts.switch ? { switch: true } : {}), ...(opts.terms ? { terms: opts.terms } : {}) }),
  authLink: (provider: T.AuthProvider, c: T.Credentials) => post<{ me: T.Me }>('/api/auth/link/' + provider, c),
  authUnlink: (provider: T.AuthProvider) => post<{ me: T.Me }>('/api/auth/unlink/' + provider),
  deleteAccount: () => del<{ ok: boolean }>('/api/account'),
  chooseFaction: (faction: T.Faction) => post<{ me: T.Me }>('/api/faction', { faction }),
  me: () => get<T.Me>('/api/me'),
  setAvatar: (avatar: Record<string, unknown>) => post<{ me: T.Me }>('/api/avatar', { avatar }),

  // world
  /** `mock`: the phone says this fix came from a mock provider (sent only when true). */
  location: (lat: number, lon: number, acc: number, sanctuary: boolean, places: T.PlaceReport[] = [], mock = false) =>
    post<T.WorldView>('/api/location', { lat, lon, acc, sanctuary, places, ...(mock ? { mock: true } : {}) }),
  engage: (id: string, stance?: T.Stance) => post<T.Battle>('/api/engage', { id, ...(stance ? { stance } : {}) }),
  /** The default stance Contact fights use. */
  setStance: (stance: T.Stance) => post<{ me: T.Me }>('/api/stance', { stance }),
  open: (id: string) => post<{ loot: T.Rewards; me: T.Me }>('/api/open', { id }),

  // gear and character
  equip: (uid: string) => post<{ me: T.Me }>('/api/equip', { uid }),
  unequip: (slot: T.Slot) => post<{ me: T.Me }>('/api/unequip', { slot }),
  scrap: (uids: string[]) => post<{ salvage_gained: number; me: T.Me }>('/api/scrap', { uids }),
  upgrade: (uid: string) => post<{ me: T.Me }>('/api/upgrade', { uid }),
  use: (consumable: string) => post<{ me: T.Me; rewards?: T.Rewards }>('/api/use', { consumable }),
  setAbilities: (equipped: string[]) => post<{ me: T.Me }>('/api/abilities', { equipped }),
  claimMission: (id: string) => post<{ rewards: T.Rewards; me: T.Me }>('/api/missions/claim', { id }),
  buy: (sku: string) => post<{ rewards?: T.Rewards; me: T.Me }>('/api/store/buy', { sku }),

  // notes
  notes: () => get<T.NoteArchive>('/api/notes'),
  claimNotes: (set: T.NoteSetId) => post<{ rewards: T.Rewards; title: string; me: T.Me }>('/api/notes/claim', { set }),

  // achievements, collection log, cosmetics
  achievements: () => get<T.AchievementList>('/api/achievements'),
  collection: () => get<T.Collection>('/api/collection'),
  /** Wear an owned colour or frame; `id` null takes it off. */
  equipCosmetic: (kind: T.CosmeticKind, id: string | null) => post<{ me: T.Me }>('/api/cosmetics/equip', { kind, id }),

  // world events
  events: () => get<T.EventsState>('/api/events'),
  exchangeBuy: (sku: string) => post<{ rewards: T.Rewards; me: T.Me }>('/api/events/exchange', { sku }),

  // social and war
  war: () => get<T.WarState>('/api/war'),
  leaderboard: (board: 'weekly' | 'contacts' | 'level') =>
    get<{ entries: T.LeaderboardEntry[] }>('/api/leaderboard?board=' + board),
  feed: () => get<{ events: T.GameEvent[] }>('/api/feed'),
  clans: (q = '') => get<{ clans: T.ClanSummary[] }>('/api/clans?q=' + encodeURIComponent(q)),
  createClan: (name: string, tag: string) =>
    post<{ clan: T.ClanDetail; me: T.Me }>('/api/clans', { name, tag }),
  joinClan: (target: { id: string } | { code: string }) =>
    post<{ clan: T.ClanDetail; me: T.Me }>('/api/clans/join', target),
  leaveClan: () => post<{ me: T.Me }>('/api/clans/leave'),
  clan: () => get<{ clan: T.ClanDetail }>('/api/clan'),
  clanChat: () => get<{ messages: T.ClanMessage[] }>('/api/clan/chat'),
  sendClanChat: (text: string) => post<{ messages: T.ClanMessage[] }>('/api/clan/chat', { text }),
  claimStronghold: (id: string, stance?: T.Stance) =>
    post<{ battles: T.Battle[]; claimed: boolean; me: T.Me }>('/api/stronghold/claim', { id, ...(stance ? { stance } : {}) }),
  /** Tell the server's owner about a player, a clan (by id) or a clan chat message (by id). */
  report: (kind: T.ReportKind, target: string, reason: T.ReportReason, note?: string) =>
    post<{ ok: boolean }>('/api/report', { kind, target, reason, ...(note ? { note } : {}) }),
  /** Anonymous crash and error reports (see src/report/errors.ts). */
  clientErrors: (reports: T.ClientErrorReport[]) => post<{ ok: boolean; stored: number }>('/api/client-error', { reports }),
  raidAttack: (id: string, stance?: T.Stance) => post<T.Battle>('/api/raid/attack', { id, ...(stance ? { stance } : {}) }),

  // dev only (--dev)
  dev: {
    grant: (b: { xp?: number; salvage?: number; item?: { base: string; rarity: T.Rarity }; consumable?: { id: string; n: number }; note?: string }) =>
      post<{ me: T.Me }>('/api/dev/grant', b),
    heal: () => post<{ me: T.Me }>('/api/dev/heal'),
    resetCooldowns: () => post<unknown>('/api/dev/reset_cooldowns'),
    botContact: () => post<unknown>('/api/dev/bot_contact'),
    startEvent: (type: T.WorldEventType, hours = 6) => post<unknown>('/api/dev/event', { type, hours }),
    stopEvent: () => post<unknown>('/api/dev/event_stop'),
  },
};

export function errorMessage(e: unknown): string {
  return e instanceof ApiError || e instanceof Error ? e.message : 'Something went wrong.';
}
