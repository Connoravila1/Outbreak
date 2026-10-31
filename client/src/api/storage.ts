// Tiny key/value store. All access is wrapped so private-mode / blocked storage never throws.
// Swap `backend` for Capacitor Preferences later (it is async there; callers use the sync
// facade backed by an in-memory cache that Capacitor can pre-fill at startup).

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
  server: 'outbreak.server',
  token: 'outbreak.token',
  recovery: 'outbreak.recovery',
  simPos: 'outbreak.sim.pos',
  simActive: 'outbreak.sim.active',
  sound: 'outbreak.sound',
  haptics: 'outbreak.haptics',
  reducedMotion: 'outbreak.reducedMotion',
  briefed: 'outbreak.briefed',
} as const;
