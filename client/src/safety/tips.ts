// The safety reminder on the boot screen: one short line, only now and then.
import { KEYS, storage } from '../api';

export const TIPS = [
  'Eyes up. Traffic first, screen second.',
  'Never play while driving or cycling.',
  'Stay off private property.',
  'After dark, go with others.',
  'Sanctuaries are off limits. Keep clear.',
];

/** Every third launch shows one; the next one in turn each time. */
const EVERY = 3;
let counted: number | null = null;

/** This launch's reminder, or null. Counts the launch the first time it is asked. */
export function bootTip(): string | null {
  if (counted == null) {
    counted = (Number(storage.get(KEYS.launches)) || 0) + 1;
    storage.set(KEYS.launches, String(counted));
  }
  if (counted % EVERY !== 0) return null;
  return TIPS[(counted / EVERY - 1) % TIPS.length];
}
