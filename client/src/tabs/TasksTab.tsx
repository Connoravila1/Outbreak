import { me } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { Section } from '../ui/kit';
import { useNow, longClock } from '../ui/hooks';
import { MissionCard } from '../tasks/MissionCard';
import '../shell/shell.css';
import '../tasks/tasks.css';

const WEEKLY_LEVEL = 5;

export function TasksTab() {
  const m = me.value;
  const now = useNow();
  if (!m) return null;
  const { daily, weekly, streak, resets_at } = m.missions;
  const bonus = Math.min(50, streak * 10);
  const claimed = daily.filter((d) => d.claimed).length;
  const allDone = daily.length > 0 && claimed === daily.length;
  return (
    <div class="panel scroll tasks">
      <h2 class="display">{say('Tasks', 'hungers')}</h2>
      <div class="card streak">
        <Icon name="flame-claws" size={30} />
        <div>
          <b>{say(`${streak}-day streak`, `${streak} days running`)}</b>
          <p class="dim">{streak > 0 ? say(`+${bonus}% mission XP`, `+${bonus}% xp from hungers`) : say('Claim a mission today to start one.', 'feed today to start.')}</p>
        </div>
      </div>

      <Section title={say('Daily', 'daily')} aside={<span><Icon name="hourglass" size={14} /> {say('resets in', 'again in')} {longClock(resets_at - now)}</span>}>
        <ul class="mission-list">
          {daily.map((d) => <MissionCard key={d.id} m={d} />)}
        </ul>
        <p class={'bonus-hint' + (allDone ? ' got' : '')}>
          <Icon name="medical-pack" size={18} />
          {allDone ? say('All three claimed. Bonus supply earned.', 'all three. the bonus is yours.') : say(`Claim all three for a bonus supply (${claimed} / ${daily.length || 3}).`, `take all three for a bonus (${claimed} / ${daily.length || 3}).`)}
        </p>
      </Section>

      <Section title={say('Weekly', 'weekly')}>
        {m.level < WEEKLY_LEVEL ? (
          <div class="card locked-card"><Icon name="padlock" size={26} /><p>{say(`Weekly missions unlock at level ${WEEKLY_LEVEL}. You are level ${m.level}.`, `the long hunt opens at level ${WEEKLY_LEVEL}. you are ${m.level}.`)}</p></div>
        ) : weekly ? (
          <ul class="mission-list"><MissionCard m={weekly} weekly /></ul>
        ) : <p class="empty">{say('No weekly mission yet.', 'nothing long yet.')}</p>}
      </Section>
    </div>
  );
}
