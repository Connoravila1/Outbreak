import { signal } from '@preact/signals';
import { api, errorMessage } from '../api';
import { position } from '../location';
import { gameMap } from '../map/instance';
import { isInSanctuary } from '../map/sanctuary';
import { eventLog, me, onBattle, world, applyMe } from './store';
import { haptic } from '../audio/fx';

export const inSanctuary = signal(false);
export const pollError = signal<string | null>(null);
export const contactAlert = signal<string | null>(null);

let timer: number | null = null;
let busy = false;

async function tick() {
  const fix = position.peek();
  if (!fix || busy || document.hidden) return;
  busy = true;
  try {
    const m = gameMap.peek();
    const sanctuary = m ? isInSanctuary(m, { lng: fix.lon, lat: fix.lat }) : false;
    inSanctuary.value = sanctuary;
    const w = await api.location(fix.lat, fix.lon, fix.acc, sanctuary);
    world.value = w;
    pollError.value = null;
    const cur = me.peek();
    if (cur) {
      const levelChanged = w.me.level !== cur.level;
      applyMe({ ...cur, ...w.me });
      if (levelChanged) void api.me().then(applyMe).catch(() => undefined);
    }
    if (w.events.length) {
      eventLog.value = [...w.events, ...eventLog.value].slice(0, 50);
      for (const ev of w.events) {
        if (ev.type === 'contact' && ev.battle) {
          haptic([200, 80, 200, 80, 400]);
          contactAlert.value = ev.text;
          onBattle(ev.battle);
        }
      }
    }
  } catch (e) {
    pollError.value = errorMessage(e);
  } finally {
    busy = false;
  }
}

/** Poll POST /api/location every 5 s while the app is open. */
export function startPolling() {
  if (timer != null) return;
  timer = window.setInterval(() => void tick(), 5000);
  void tick();
  // the first fix usually arrives after the first tick; poll as soon as it does
  let first = true;
  const un = position.subscribe((v) => {
    if (!v || !first) return;
    first = false;
    queueMicrotask(() => { un(); void tick(); });
  });
}
export function pollNow() { void tick(); }
export function stopPolling() {
  if (timer != null) window.clearInterval(timer);
  timer = null;
}
