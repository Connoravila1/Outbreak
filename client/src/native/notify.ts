import { LocalNotifications } from '@capacitor/local-notifications';
import { effect } from '@preact/signals';
import { me, lens } from '../state/store';
import { isNative } from './platform';
import { reportPluginError } from '../report/errors';

const DAILY_BASE = 100; // ids 100..106: the next seven resets
const DAILY_DAYS = 7;
const DOWNED_ID = 200;
const DAY = 86_400_000;

const quiet = (p: Promise<unknown>, call: string) => { void p.catch((e) => reportPluginError(call, e)); };

async function allowed(): Promise<boolean> {
  try { return (await LocalNotifications.checkPermissions()).display === 'granted'; } catch { return false; }
}

/** Ask once, after onboarding (never at launch). Resolves to whether alerts are allowed. */
export async function requestNotifyPermission(): Promise<boolean> {
  if (!isNative) return false;
  try {
    const st = await LocalNotifications.checkPermissions();
    if (st.display === 'granted') return true;
    if (st.display === 'denied') return false;
    return (await LocalNotifications.requestPermissions()).display === 'granted';
  } catch { return false; }
}

/** Next 00:00 UTC strictly after `now`. */
export function nextUtcMidnight(now: number): number { return Math.floor(now / DAY) * DAY + DAY; }

/** (Re)schedule the daily-missions reset for the coming week. Call at launch and on every resume. */
export async function scheduleDailyReset() {
  if (!isNative || !(await allowed())) return;
  const first = nextUtcMidnight(Date.now());
  const ids = Array.from({ length: DAILY_DAYS }, (_, i) => ({ id: DAILY_BASE + i }));
  try {
    await LocalNotifications.cancel({ notifications: ids });
    await LocalNotifications.schedule({
      notifications: ids.map(({ id }, i) => ({
        id,
        title: 'Daily missions reset',
        body: 'New missions are waiting.',
        schedule: { at: new Date(first + i * DAY), allowWhileIdle: true },
        smallIcon: 'ic_notify',
      })),
    });
  } catch { /* alerts are a nicety */ }
}

/** Keep one "you are back up" alert in step with the Downed timer. */
async function syncDowned(until: number | null | undefined, heat: boolean) {
  if (!isNative || !(await allowed())) return;
  try {
    await LocalNotifications.cancel({ notifications: [{ id: DOWNED_ID }] });
    if (!until || until <= Date.now()) return;
    await LocalNotifications.schedule({
      notifications: [{
        id: DOWNED_ID,
        title: heat ? 'you rise again.' : 'Back on your feet',
        body: heat ? 'the hunt goes on.' : 'You can fight again.',
        schedule: { at: new Date(until), allowWhileIdle: true },
        smallIcon: 'ic_notify',
      }],
    });
  } catch { /* ignore */ }
}

let watching = false;
/** Start following `me.downed_until`. Idempotent. */
export function watchDowned() {
  if (!isNative || watching) return;
  watching = true;
  let last: number | null | undefined;
  effect(() => {
    const until = me.value?.downed_until;
    const heat = lens.value === 'heat';
    if (until === last) return;
    last = until;
    quiet(syncDowned(until, heat), 'LocalNotifications.schedule');
  });
}
