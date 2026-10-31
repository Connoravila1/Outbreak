import { effect, signal } from '@preact/signals';
import { api, errorMessage } from '../api';
import { position } from '../location';
import { locationIsMocked } from '../location/mock';
import { gameMap } from '../map/instance';
import { isInSanctuary } from '../map/sanctuary';
import { collectPlaces } from '../map/places';
import { eventLog, me, world, applyMe } from './store';
import { pushToast } from '../ui/kit';
import { battleActive, enqueueBattle, enqueueLevelUp } from '../battle/session';
import { showRewards } from '../ui/RewardsSheet';
import { say } from '../ui/voice';
import { recordBattle } from './record';
import { addToReport, AWAY_MS } from '../patrol/PatrolReport';
import { notesFound } from '../notes/store';
import { achievementsEarned } from '../collection/store';
import { appActive } from '../native/active';

export const inSanctuary = signal(false);
export const pollError = signal<string | null>(null);

let timer: number | null = null;
let busy = false;

async function tick() {
  const fix = position.peek();
  if (!fix || busy || !appActive.peek() || battleActive()) return;
  busy = true;
  try {
    const m = gameMap.peek();
    const sanctuary = m ? isInSanctuary(m, { lng: fix.lon, lat: fix.lat }) : false;
    inSanctuary.value = sanctuary;
    // Real places near you from the tiles already on screen (the server never reads the map itself).
    const places = m && !sanctuary ? collectPlaces(m, fix) : [];
    const mock = await locationIsMocked();
    const w = await api.location(fix.lat, fix.lon, fix.acc, sanctuary, places, mock);
    world.value = w;
    pollError.value = null;
    // A contact interrupts everything; take it before the HP numbers move so the fight is not spoiled.
    for (const ev of w.events) {
      if (w.now - ev.at > AWAY_MS) {
        // Happened while the app was closed (Patrol): listed in "While you were patrolling" instead of taking over the screen.
        if (ev.type === 'contact' && ev.battle) recordBattle(ev.battle, true);
        addToReport([ev]);
      } else if (ev.type === 'contact' && ev.battle) enqueueBattle(ev.battle, true);
      else if (ev.type === 'achievement') achievementsEarned(ev.rewards?.achievements);
      else if (ev.type === 'level_up' && ev.rewards?.level_up) {
        // Gained while walking (or from an item): same takeover as a fight, with the fresh Me.
        const up = ev.rewards.level_up;
        void api.me().then((m) => { applyMe(m); enqueueLevelUp(up, m); }, () => pushToast(ev.text, 'info'));
      } else if (ev.type === 'raid' && ev.rewards) {
        showRewards(say('Raid won', 'the horde falls'), ev.rewards);
        notesFound(ev.rewards.notes);
        pushToast(ev.text, 'good');
      } else pushToast(ev.text, ev.type === 'echo_report' ? 'echo' : 'info');
    }
    if (w.events.length) eventLog.value = [...w.events, ...eventLog.value].slice(0, 50);
    const cur = me.peek();
    if (cur && !battleActive()) {
      const levelChanged = w.me.level !== cur.level;
      applyMe({ ...cur, ...w.me });
      if (levelChanged) void api.me().then(applyMe).catch(() => undefined);
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
// Back in the app: catch up at once instead of waiting out the interval.
effect(() => { if (appActive.value && timer != null) queueMicrotask(() => void tick()); });
export function stopPolling() {
  if (timer != null) window.clearInterval(timer);
  timer = null;
}
