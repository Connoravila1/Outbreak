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

async function request<R>(method: 'GET' | 'POST' | 'DELETE', path: string, body?: unknown, base?: string): Promise<R> {
  const headers: Record<string, string> = { Accept: 'application/json' };
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
  register: () => post<T.RegisterResult>('/api/register', {}),
  setCallsign: (callsign: string) => post<{ me: T.Me }>('/api/callsign', { callsign }),
  /** Sign in (or create) with a provider; a guest's token, if sent, is linked or replaced. */
  authSignIn: (provider: T.AuthProvider, c: T.Credentials, opts: { switch?: boolean } = {}) =>
    post<T.AuthResult>('/api/auth/' + provider, { ...c, ...(opts.switch ? { switch: true } : {}) }),
  authLink: (provider: T.AuthProvider, c: T.Credentials) => post<{ me: T.Me }>('/api/auth/link/' + provider, c),
  authUnlink: (provider: T.AuthProvider) => post<{ me: T.Me }>('/api/auth/unlink/' + provider),
  deleteAccount: () => del<{ ok: boolean }>('/api/account'),
  chooseFaction: (faction: T.Faction) => post<{ me: T.Me }>('/api/faction', { faction }),
  me: () => get<T.Me>('/api/me'),
  setAvatar: (avatar: Record<string, unknown>) => post<{ me: T.Me }>('/api/avatar', { avatar }),

  // world
  location: (lat: number, lon: number, acc: number, sanctuary: boolean) =>
    post<T.WorldView>('/api/location', { lat, lon, acc, sanctuary }),
  engage: (id: string) => post<T.Battle>('/api/engage', { id }),
  open: (id: string) => post<{ loot: T.Rewards; me: T.Me }>('/api/open', { id }),

  // gear and character
  equip: (uid: string) => post<{ me: T.Me }>('/api/equip', { uid }),
  unequip: (slot: T.Slot) => post<{ me: T.Me }>('/api/unequip', { slot }),
  scrap: (uids: string[]) => post<{ salvage_gained: number; me: T.Me }>('/api/scrap', { uids }),
  upgrade: (uid: string) => post<{ me: T.Me }>('/api/upgrade', { uid }),
  use: (consumable: string) => post<{ me: T.Me }>('/api/use', { consumable }),
  setAbilities: (equipped: string[]) => post<{ me: T.Me }>('/api/abilities', { equipped }),
  claimMission: (id: string) => post<{ rewards: T.Rewards; me: T.Me }>('/api/missions/claim', { id }),
  buy: (sku: string) => post<{ rewards?: T.Rewards; me: T.Me }>('/api/store/buy', { sku }),

  // social and war
  war: () => get<T.WarState>('/api/war'),
  leaderboard: (board: 'weekly' | 'level') =>
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
  claimStronghold: (id: string) =>
    post<{ battles: T.Battle[]; claimed: boolean; me: T.Me }>('/api/stronghold/claim', { id }),
  raidAttack: (id: string) => post<T.Battle>('/api/raid/attack', { id }),

  // dev only (--dev)
  dev: {
    grant: (b: { xp?: number; salvage?: number; item?: { base: string; rarity: T.Rarity }; consumable?: { id: string; n: number } }) =>
      post<{ me: T.Me }>('/api/dev/grant', b),
    heal: () => post<{ me: T.Me }>('/api/dev/heal'),
    resetCooldowns: () => post<unknown>('/api/dev/reset_cooldowns'),
    botContact: () => post<unknown>('/api/dev/bot_contact'),
  },
};

export function errorMessage(e: unknown): string {
  return e instanceof ApiError || e instanceof Error ? e.message : 'Something went wrong.';
}
