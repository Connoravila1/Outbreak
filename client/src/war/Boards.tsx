import { useEffect, useState } from 'preact/hooks';
import { api, errorMessage, type LeaderboardEntry } from '../api';
import { me } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { ErrorLine, Section, Seg } from '../ui/kit';

type Board = 'weekly' | 'level';

export function Leaderboard() {
  const [board, setBoard] = useState<Board>('weekly');
  const [rows, setRows] = useState<LeaderboardEntry[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    setRows(null); setErr(null);
    api.leaderboard(board).then((r) => { if (live) setRows(r.entries); }, (e) => { if (live) setErr(errorMessage(e)); });
    return () => { live = false; };
  }, [board]);
  const mine = me.value?.callsign;
  return (
    <Section title={say('Leaderboard', 'the ranked')}>
      <Seg label="Leaderboard" value={board} onChange={setBoard} options={[{ id: 'weekly', label: say('This week', 'this week') }, { id: 'level', label: say('By level', 'by level') }]} />
      <ErrorLine text={err} />
      {!rows && !err && <p class="empty dim">{say('Loading…', '…')}</p>}
      {rows && rows.length === 0 && <p class="empty">{say('Nobody ranked yet.', 'nobody yet.')}</p>}
      {rows && rows.length > 0 && (
        <ol class="rank-list">
          {rows.map((e) => (
            <li key={e.rank + e.callsign} class={'rank card' + (e.callsign === mine ? ' me' : '')}>
              <b class="rk num">{e.rank}</b>
              <span class="rk-main">
                <b class="rk-name">{e.clan_tag && <span class="tag">[{e.clan_tag}]</span>} {e.callsign}{e.callsign === mine ? ` (${say('you', 'you')})` : ''}</b>
                <span class="dim">{say('Level', 'level')} {e.level} · {e.title} · <Icon name={e.faction === 'human' ? 'shield' : 'biohazard'} size={12} /> {e.faction === 'human' ? 'Human' : 'Zombie'}</span>
              </span>
              <span class="rk-val num">{e.value.toLocaleString()}<small>{board === 'weekly' ? ' pts' : ''}</small></span>
            </li>
          ))}
        </ol>
      )}
    </Section>
  );
}
