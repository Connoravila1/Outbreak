import { useEffect, useState } from 'preact/hooks';
import { api, errorMessage, type WarState } from '../api';
import { me } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { ErrorLine, Section } from '../ui/kit';
import { Callsign } from '../ui/Callsign';
import { longClock, useNow } from '../ui/hooks';
import { FactionBar } from '../war/FactionBar';
import { Leaderboard } from '../war/Boards';
import { ClanSection } from '../war/Clan';
import { EventsCard } from '../events/EventsCard';
import '../shell/shell.css';
import '../war/war.css';

export function WarTab() {
  const m = me.value;
  const now = useNow();
  const [war, setWar] = useState<WarState | null>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    const load = () => api.war().then((w) => { if (live) { setWar(w); setErr(null); } }, (e) => { if (live) setErr(errorMessage(e)); });
    void load();
    const t = window.setInterval(load, 60000);
    return () => { live = false; clearInterval(t); };
  }, []);
  if (!m) return null;
  return (
    <div class="panel scroll war">
      <h2 class="display">{say('The War', 'the war')}</h2>
      <EventsCard />
      <ErrorLine text={err} />
      {!war && !err && <p class="empty dim">{say('Reading the front…', 'listening…')}</p>}
      {war && (
        <>
          <div class="card war-card">
            <div class="war-top">
              <b class="display">{say(`Week ${war.week}`, `week ${war.week}`)}</b>
              <span class="dim"><Icon name="hourglass" size={14} /> {say('resets in', 'ends in')} <b class="num">{longClock(war.ends_at - now)}</b></span>
            </div>
            <FactionBar human={war.global.human} zombie={war.global.zombie} label="Global" />
            {war.district ? (
              <>
                <p class="dim bar-cap">{say('Your district', 'your district')}</p>
                <FactionBar human={war.district.human} zombie={war.district.zombie} label="District" />
              </>
            ) : <p class="dim bar-cap">{say('No district data here yet.', 'no ground counted here yet.')}</p>}
          </div>
          <div class="card my-pts">
            <Icon name="crossed-swords" size={26} />
            <div><b class="num pts">{war.my_points}</b> <span class="dim">{say('your points this week', 'your points this week')}</span></div>
          </div>
          <Section title={say('Top this week', 'strongest this week')}>
            {war.top.length === 0 ? <p class="empty">{say('No points scored yet.', 'nobody has fed yet.')}</p> : (
              <ol class="rank-list">
                {war.top.map((t, i) => (
                  <li key={t.callsign} class={'rank card' + (t.callsign === m.callsign ? ' me' : '')}>
                    <b class="rk num">{i + 1}</b>
                    <span class="rk-main"><b class="rk-name"><Callsign name={t.callsign} color={t.callsign_color} /></b><span class="dim">{say('Level', 'level')} {t.level} · {t.title}</span></span>
                    <span class="rk-val num">{t.points}<small> pts</small></span>
                  </li>
                ))}
              </ol>
            )}
          </Section>
        </>
      )}
      <Leaderboard />
      <ClanSection />
    </div>
  );
}
