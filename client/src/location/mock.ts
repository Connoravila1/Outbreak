import { signal } from '@preact/signals';
import { Patrol } from '../native/patrol';
import { isNative } from '../native/platform';
import { reportPluginError } from '../report/errors';
import { simActive } from './index';

/**
 * Dev panel switch: make the desktop simulator report itself as a mock provider, to try the server's
 * fake-GPS policy. Off by default, so the simulator keeps working as it always has.
 */
export const devMockGps = signal(false);

const within = <T>(p: Promise<T>, ms: number) => Promise.race([p, new Promise<never>((_, no) => setTimeout(() => no(new Error('timeout')), ms))]);

/**
 * Does the phone say its latest fix came from a mock provider (a fake-GPS app)? Android asks
 * `Location.isMock()` (API 31+) or `isFromMockProvider()`, iOS asks `sourceInformation.isSimulatedBySoftware`;
 * both live in the Patrol plugin. Browsers cannot tell, so this is false there. Any failure is "no":
 * a doubtful reading must never punish a player.
 */
export async function locationIsMocked(): Promise<boolean> {
  if (simActive.value) return devMockGps.value;
  if (!isNative) return false;
  try {
    const r = await within(Patrol.mockCheck(), 1500);
    return r.mock === true;
  } catch (e) {
    if ((e as Error).message !== 'timeout') reportPluginError('Patrol.mockCheck', e);
    return false;
  }
}
