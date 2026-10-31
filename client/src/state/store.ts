import { signal, computed, effect } from '@preact/signals';
import { api, ApiError, getToken, setToken, type Battle, type Catalog, type Faction, type GameEvent, type Me, type WorldView } from '../api';
import { KEYS, storage } from '../api/storage';

export type Lens = 'neutral' | 'survey' | 'heat';
export type TabId = 'map' | 'gear' | 'tasks' | 'war' | 'you';

export const me = signal<Me | null>(null);
export const catalog = signal<Catalog | null>(null);
export const world = signal<WorldView | null>(null);
export const tab = signal<TabId>('map');
/** boot: checking the token. onboarding: no account / no faction. app: ready. */
export const phase = signal<'boot' | 'onboarding' | 'app'>('boot');
export const lensOverride = signal<Lens | null>(null);
export const faction = computed<Faction | null>(() => me.value?.faction ?? null);
export const lens = computed<Lens>(() => lensOverride.value ?? (faction.value === 'human' ? 'survey' : faction.value === 'zombie' ? 'heat' : 'neutral'));

effect(() => { document.documentElement.dataset.lens = lens.value; });

// ---- settings ----
const flag = (k: string, d: boolean) => { const v = storage.get(k); return v == null ? d : v === '1'; };
export const soundOn = signal(flag(KEYS.sound, true));
export const hapticsOn = signal(flag(KEYS.haptics, true));
const systemReduced = typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
export const reducedMotion = signal(flag(KEYS.reducedMotion, systemReduced));
effect(() => { document.documentElement.dataset.motion = reducedMotion.value ? 'reduced' : 'full'; });
export function setSetting(sig: typeof soundOn, key: string, v: boolean) { sig.value = v; storage.set(key, v ? '1' : '0'); }

// ---- battles and events: hook for the fight-playback screen built later ----
export const pendingBattle = signal<Battle | null>(null);
export const eventLog = signal<GameEvent[]>([]);
export type BattleHandler = (battle: Battle) => void;
let battleHandler: BattleHandler = (b) => { pendingBattle.value = b; };
/** The fight playback screen registers itself here. Until then results land in `pendingBattle`. */
export function onBattle(b: Battle) { battleHandler(b); }
export function setBattleHandler(h: BattleHandler) { battleHandler = h; }

export function applyMe(m: Me) { me.value = m; }

export async function loadCatalog() {
  if (catalog.value) return;
  try { catalog.value = await api.catalog(); } catch { /* retried by callers on demand */ }
}

/** Decide where to land at launch. */
export async function boot() {
  const token = getToken();
  if (!token) { phase.value = 'onboarding'; return; }
  try {
    const m = await api.me();
    me.value = m;
    phase.value = m.faction ? 'app' : 'onboarding';
    if (m.faction) void loadCatalog();
  } catch (e) {
    if (e instanceof ApiError && e.status === 401) setToken(null);
    phase.value = 'onboarding';
  }
}

export function signOut() {
  setToken(null);
  storage.remove(KEYS.recovery);
  me.value = null;
  world.value = null;
  location.reload();
}
