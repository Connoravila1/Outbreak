import { useEffect } from 'preact/hooks';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { Meter, Section } from '../ui/kit';
import { longClock, useNow } from '../ui/hooks';
import { faction, me } from '../state/store';
import { cosmeticName, eventDef, eventName, eventsState, goalUnit, kindName, refreshEvents } from './store';
import { EVENT_ICON } from './EventBanner';
import type { EventLive, EventUpcoming } from '../api';
import './events.css';

const DAY = 86_400_000;

/** "Thu 12:00" in the player's own clock. */
function whenText(at: number, now: number): string {
  const d = new Date(at);
  const day = at - now < DAY ? say('Today', 'today') : d.toLocaleDateString(undefined, { weekday: 'short' });
  return `${day} ${d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })}`;
}

function Rewards({ live }: { live: EventLive }) {
  const def = eventDef(live.type);
  if (!def) return null;
  const f = faction.value ?? 'human';
  const cos = cosmeticName(def.cosmetic);
  const rows: { tier: number; text: string }[] = [1, 2, 3].map((t) => ({
    tier: t,
    text: [
      `${def.salvage[t - 1]} ${say('salvage', 'salvage')}`,
      t >= 2 && cos ? cos : null,
      t === 3 ? say('a Rare or better item', 'a prize of a rarer kind') : null,
      t === 3 && def.title ? `${say('title', 'title')}: ${def.title[f]}` : null,
    ].filter(Boolean).join(' · '),
  }));
  return (
    <ul class="ev-tiers">
      {rows.map((r) => {
        const need = def.tiers[r.tier - 1];
        const got = live.mine.n >= need;
        return (
          <li key={r.tier} class={got ? 'got' : ''}>
            <span class="ev-tier num">{got ? <Icon name="check-mark" size={14} /> : r.tier}</span>
            <span class="ev-tier-main"><span><b class="num">{need}</b> {goalUnit(live.type, live.kind)}</span><span class="dim">{r.text}</span></span>
          </li>
        );
      })}
    </ul>
  );
}

function Live({ live, now }: { live: EventLive; now: number }) {
  const def = eventDef(live.type);
  const f = faction.value ?? 'human';
  const unit = goalUnit(live.type, live.kind);
  const k = kindName(live.kind);
  return (
    <div class="card ev-card">
      <div class="ev-head">
        <Icon name={EVENT_ICON[live.type]} size={28} />
        <div class="ev-title">
          <b class="display">{eventName(live.type)}{live.type === 'horde' && k ? ` · ${k}` : ''}</b>
          <span class="dim"><Icon name="hourglass" size={14} /> {say('ends in', 'ends in')} <b class="num">{longClock(live.ends_at - now)}</b>{def?.monthly ? ` · ${say('monthly', 'monthly')}` : ''}</span>
        </div>
      </div>
      {def && <p class="ev-blurb">{def.blurb[f]}</p>}
      <p class="ev-cap dim">{say('Everyone together', 'the whole pack')} · <span class="num">{live.goal.progress}</span> / <span class="num">{live.goal.target}</span> {unit}{live.goal.done ? ` · ${say('goal met', 'done')}` : ''}</p>
      <Meter value={live.goal.progress} max={live.goal.target} label={say('Community goal', 'the shared hunt')} />
      {live.district && (
        <>
          <p class="ev-cap dim">{say('Your district', 'your ground')} · <span class="num">{live.district.progress}</span> / <span class="num">{live.district.target}</span>{live.district.done ? ` · ${say('goal met', 'done')}` : ''}</p>
          <Meter value={live.district.progress} max={live.district.target} label={say('District goal', 'the ground goal')} />
        </>
      )}
      <p class="ev-mine">
        <b class="num">{live.mine.n}</b> {unit} {say('from you', 'from you')}
        {live.mine.next_at != null
          ? <span class="dim"> · {say(`${live.mine.next_at - live.mine.n} to the next reward`, `${live.mine.next_at - live.mine.n} more for the next prize`)}</span>
          : <span class="dim"> · {say('every reward earned', 'every prize earned')}</span>}
      </p>
      <h4 class="cos-sub">{say('Rewards', 'prizes')}</h4>
      <Rewards live={live} />
      <p class="ev-fine dim">
        {say(`Paid when it ends, once the goal is met. Miss it and you still get ${Math.round((def?.consolation ?? 0.5) * 100)}% of the salvage.`, `paid when it ends if the goal is met. miss it and you still take ${Math.round((def?.consolation ?? 0.5) * 100)}% of the salvage.`)}
      </p>
    </div>
  );
}

function Upcoming({ list, now }: { list: EventUpcoming[]; now: number }) {
  return (
    <ul class="ev-up">
      {list.map((u) => {
        const k = kindName(u.kind);
        return (
          <li key={u.starts_at} class="card">
            <Icon name={EVENT_ICON[u.type]} size={22} />
            <span class="ev-up-main"><b>{eventName(u.type)}{u.type === 'horde' && k ? ` · ${k}` : ''}</b><span class="dim">{eventDef(u.type)?.monthly ? `${say('Monthly', 'monthly')} · ` : ''}{Math.round((u.ends_at - u.starts_at) / 3_600_000)} h</span></span>
            <span class="ev-up-when dim">{say('starts', 'starts')} {whenText(u.starts_at, now)}</span>
          </li>
        );
      })}
    </ul>
  );
}

/** The War tab's events card: what is running, how the community and you are doing, what it pays, and what comes next. */
export function EventsCard() {
  const now = useNow();
  const st = eventsState.value;
  useEffect(() => {
    void refreshEvents(true);
    const t = window.setInterval(() => void refreshEvents(true), 60_000);
    return () => clearInterval(t);
  }, []);
  if (!me.value) return null;
  return (
    <Section title={say('World events', 'the turning')}>
      {!st && <p class="empty dim">…</p>}
      {st && st.live && <Live live={st.live} now={now} />}
      {st && !st.live && <p class="empty">{say('Nothing is running. The next one is below.', 'quiet. the next stirring is below.')}</p>}
      {st && st.upcoming.length > 0 && (
        <>
          <h4 class="cos-sub">{say('Upcoming', 'coming')}</h4>
          <Upcoming list={st.upcoming} now={now} />
        </>
      )}
    </Section>
  );
}
