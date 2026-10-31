import { say } from '../ui/voice';
import { Icon, type IconName } from '../ui/Icon';
import { Meter } from '../ui/kit';
import { longClock, useNow } from '../ui/hooks';
import { faction, tab, world } from '../state/store';
import { eventDef, eventName, goalUnit } from './store';
import type { WorldEventType } from '../api';
import './events.css';

export const EVENT_ICON: Record<WorldEventType, IconName> = {
  blood_moon: 'moon', supply_run: 'parachute', horde: 'shambling-zombie', echo_week: 'ghost', last_light: 'lantern', day_zero: 'biohazard',
};

/** The strip at the top of the map while a world event is running. Tap it for the War tab's Events card. */
export function EventBanner({ low }: { low?: boolean }) {
  const now = useNow();
  const ev = world.value?.event;
  if (!ev || ev.ends_at <= now) return null;
  const def = eventDef(ev.type);
  return (
    <button class={'event-banner' + (low ? ' low' : '')} onClick={() => { tab.value = 'war'; }} aria-label={say(`${eventName(ev.type)}. Open the event.`, `${eventName(ev.type)}. open it.`)}>
      <span class="eb-top">
        <Icon name={EVENT_ICON[ev.type]} size={20} />
        <b class="eb-name">{eventName(ev.type)}</b>
        <span class="eb-time num"><Icon name="hourglass" size={14} /> {longClock(ev.ends_at - now)}</span>
      </span>
      {def && <span class="eb-text">{def.blurb[faction.value ?? 'human']}</span>}
      <Meter value={ev.progress} max={ev.target} label={say('Community goal', 'the shared hunt')} />
      <span class="eb-goal"><b class="num">{ev.progress}</b> / <span class="num">{ev.target}</span> {goalUnit(ev.type, ev.kind)} · <span class="num">{ev.mine}</span> {say('yours', 'yours')}</span>
    </button>
  );
}
