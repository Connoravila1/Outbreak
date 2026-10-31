// Tiny key/value store. All access is wrapped so private-mode / blocked storage never throws.
// On native, Capacitor Preferences is async, so `hydrateStorage()` loads every key into memory
// before the app renders and writes go through to Preferences (callers stay synchronous).
import { Preferences } from '@capacitor/preferences';
import { isNative } from '../native/platform';

export interface StorageBackend {
  get(key: string): string | null;
  set(key: string, value: string): void;
  remove(key: string): void;
}

const memory = new Map<string, string>();

const localBackend: StorageBackend = {
  get(key) {
    try {
      const v = localStorage.getItem(key);
      return v ?? memory.get(key) ?? null;
    } catch {
      return memory.get(key) ?? null;
    }
  },
  set(key, value) {
    memory.set(key, value);
    try { localStorage.setItem(key, value); } catch { /* blocked: memory only */ }
  },
  remove(key) {
    memory.delete(key);
    try { localStorage.removeItem(key); } catch { /* ignore */ }
  },
};

let backend: StorageBackend = localBackend;
export function setStorageBackend(b: StorageBackend) { backend = b; }

/** Preferences-backed store: sync reads from a cache filled at startup, writes go through. */
function preferencesBackend(cache: Map<string, string>): StorageBackend {
  return {
    get: (key) => cache.get(key) ?? null,
    set(key, value) {
      cache.set(key, value);
      void Preferences.set({ key, value }).catch(() => undefined);
    },
    remove(key) {
      cache.delete(key);
      void Preferences.remove({ key }).catch(() => undefined);
    },
  };
}

/** Await before anything reads storage. A no-op in the browser. */
export async function hydrateStorage(): Promise<void> {
  if (!isNative) return;
  const cache = new Map<string, string>();
  try {
    const { keys } = await Preferences.keys();
    await Promise.all(keys.map(async (key) => {
      const { value } = await Preferences.get({ key });
      if (value != null) cache.set(key, value);
    }));
  } catch { /* start empty */ }
  setStorageBackend(preferencesBackend(cache));
}

export const storage = {
  get: (k: string) => backend.get(k),
  set: (k: string, v: string) => backend.set(k, v),
  remove: (k: string) => backend.remove(k),
  getJSON<T>(k: string, fallback: T): T {
    const raw = backend.get(k);
    if (raw == null) return fallback;
    try { return JSON.parse(raw) as T; } catch { return fallback; }
  },
  setJSON(k: string, v: unknown) { backend.set(k, JSON.stringify(v)); },
};

export const KEYS = {
  /** First-time explainers: the level they were last synced at and the ones still to show. */
  guide: 'outbreak.guide',
  server: 'outbreak.server',
  token: 'outbreak.token',
  simPos: 'outbreak.sim.pos',
  simActive: 'outbreak.sim.active',
  sound: 'outbreak.sound',
  haptics: 'outbreak.haptics',
  reducedMotion: 'outbreak.reducedMotion',
  briefed: 'outbreak.briefed',
  /** Highest level at which the guest reminder has been shown (3, then 10). */
  guestNudge: 'outbreak.guestNudge',
  /** The stance chosen last, offered again next fight. */
  stance: 'outbreak.stance',
  /** Ids of the found notes the player has opened. */
  notesSeen: 'outbreak.notesSeen',
  /** Callsigns whose clan chat messages this player chose to hide (lowercase). */
  hiddenChat: 'outbreak.hiddenChat',
} as const;

/** Device settings that outlive a sign-out: they are about the phone, not the player. */
const KEEP: string[] = [KEYS.server, KEYS.sound, KEYS.haptics, KEYS.reducedMotion];

/** Forget everything this device holds about the player (token, progress flags, simulator spot). */
export function wipeLocal() {
  for (const k of Object.values(KEYS)) if (!KEEP.includes(k)) backend.remove(k);
  try {
    for (const k of Object.keys(localStorage)) {
      if (k.startsWith('outbreak.') && !k.startsWith('outbreak.mock') && !KEEP.includes(k)) localStorage.removeItem(k);
    }
  } catch { /* blocked */ }
}
