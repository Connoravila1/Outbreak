// The age screen's rules. The answer never leaves the phone: nothing here touches the network, and
// only the moment someone was turned away is remembered (so the answer cannot be changed at once).
import { KEYS, storage } from '../api';

/** Players must be at least this old. */
const MIN_AGE = 13;
/** After turning someone away, the age screen stays shut this long. */
export const BLOCK_MS = 24 * 60 * 60 * 1000;

export const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

/** A message for an impossible date, or null. `month` is 1 to 12. */
export function birthProblem(year: number, month: number, now = new Date()): string | null {
  if (!Number.isInteger(month) || month < 1 || month > 12) return 'Choose the month.';
  if (!Number.isInteger(year) || year < 1900 || year > now.getFullYear()) return 'Check the year.';
  if (year * 12 + month > now.getFullYear() * 12 + now.getMonth() + 1) return 'Check the date.';
  return null;
}

/**
 * Old enough, counting from the end of the birth month: with no day asked, the youngest the person
 * could be is assumed.
 */
export function oldEnough(year: number, month: number, now = new Date()): boolean {
  const months = (now.getFullYear() * 12 + now.getMonth() + 1) - (year * 12 + month);
  return months > MIN_AGE * 12;
}

export function ageBlocked(now = Date.now()): boolean {
  const at = Number(storage.get(KEYS.ageBlock));
  return at > 0 && now - at < BLOCK_MS;
}

export function blockAge(now = Date.now()) {
  storage.set(KEYS.ageBlock, String(now));
}
