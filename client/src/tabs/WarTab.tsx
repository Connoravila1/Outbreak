import { me } from '../state/store';
import { say } from '../ui/voice';
import '../shell/shell.css';

export function WarTab() {
  const m = me.value;
  if (!m) return null;
  return (
    <div class="panel scroll">
      <h2 class="display">{say('War', 'the spread')}</h2>
      <div class="card">
        <div class="kv" style={{ borderTop: 0 }}><span>{say('Your points this week', 'your share this week')}</span><b class="num">{m.war_points_week}</b></div>
        <div class="kv"><span>{say('Underdog bonus', 'underdog bonus')}</span><b class="num">+{Math.round(m.underdog_bonus * 100)}%</b></div>
        <div class="kv" style={{ borderBottom: 0 }}><span>{say('Clan', 'pack')}</span><b>{m.clan ? `[${m.clan.tag}] ${m.clan.name}` : say('None. Clans open at level 10.', 'none. opens at level 10.')}</b></div>
      </div>
      <p class="settings-note">{say('The global and district fronts, leaderboards and clans arrive in the next pass.', 'the wider war comes later.')}</p>
    </div>
  );
}
