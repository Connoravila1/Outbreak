import { me } from '../state/store';
import { say } from '../ui/voice';
import { clock } from '../shell/Vitals';
import { signal } from '@preact/signals';
import '../shell/shell.css';

const now = signal(Date.now());
setInterval(() => { now.value = Date.now(); }, 1000);

export function TasksTab() {
  const m = me.value;
  if (!m) return null;
  const { daily, weekly, streak, resets_at } = m.missions;
  return (
    <div class="panel scroll">
      <h2 class="display">{say('Tasks', 'hungers')}</h2>
      <p class="dim">{say('Resets in', 'renews in')} <span class="num">{clock(resets_at - now.value)}</span> · {say('streak', 'streak')} <b>{streak}</b></p>
      <h3 class="display">{say('Daily', 'today')}</h3>
      {daily.length === 0 && <p class="empty">{say('No missions yet.', 'nothing yet.')}</p>}
      {daily.map((t) => (
        <div class="card mission" key={t.id}>
          <div class="kv" style={{ border: 0, padding: 0 }}><span>{t.text}</span><b class="num">{t.progress} / {t.target}</b></div>
          <div class="bar xp"><i class="fill" style={{ width: `${Math.min(100, (t.progress / t.target) * 100)}%` }} /></div>
          <button class="btn" disabled aria-disabled="true">{t.claimed ? say('Claimed', 'taken') : say('Claim', 'claim')}</button>
          {!t.claimed && t.progress < t.target && <p class="reason">{say('Not finished yet.', 'not done.')}</p>}
        </div>
      ))}
      {weekly && (
        <>
          <h3 class="display">{say('Weekly', 'this week')}</h3>
          <div class="card mission"><div class="kv" style={{ border: 0, padding: 0 }}><span>{weekly.text}</span><b class="num">{weekly.progress} / {weekly.target}</b></div></div>
        </>
      )}
    </div>
  );
}
