import { signal } from '@preact/signals';
import { CLIENT_VERSION, type Health, type UpdateRequired } from '../api';

/** Set when the server says this client is too old (426 `update_required`, or `min_client` in /api/health). */
export const updateRequired = signal<UpdateRequired | null>(null);

/** "1.2.3" (a leading v and a -beta or +build suffix are ignored) as numbers; null if it is not a version. */
export function parseVersion(text: string): [number, number, number] | null {
  const core = text.trim().replace(/^v/i, '').split(/[-+]/)[0];
  if (!core) return null;
  const parts = core.split('.');
  if (parts.length > 3 || parts.some((p) => !/^\d+$/.test(p))) return null;
  const [a, b, c] = parts.map(Number);
  return [a ?? 0, b ?? 0, c ?? 0];
}

/** True when version `a` is older than `b`. Unreadable versions are never "older". */
export function olderThan(a: string, b: string): boolean {
  const x = parseVersion(a);
  const y = parseVersion(b);
  if (!x || !y) return false;
  for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] < y[i];
  return false;
}

/** The boot-time check: the server advertises the oldest client it accepts. */
export function checkMinClient(h: Pick<Health, 'min_client' | 'store'>) {
  if (h.min_client && olderThan(CLIENT_VERSION, h.min_client)) updateRequired.value = { store: h.store ?? null };
}
