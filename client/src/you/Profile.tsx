import { faction, me } from '../state/store';
import { record } from '../state/record';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { Meter, Section } from '../ui/kit';
import { LevelRing } from '../shell/TopBar';
import { STAT_KEYS, STAT_LABEL } from '../gear/util';

export function Profile() {
  const m = me.value;
  if (!m) return null;
  const f = faction.value;
  const rec = record.value;
  return (
    <>
      <div class="id-card card">
        <div class="avatar" aria-hidden="true"><Icon name={f === 'zombie' ? 'fangs' : 'person'} size={34} /></div>
        <div class="id-main">
          <p class="display callsign-big">{m.callsign}</p>
          <p class="dim voice">{f === 'zombie' ? say('Zombie', 'infected') : say('Human', 'living')} · {say('avatar coming soon', 'a face, later')}</p>
        </div>
      </div>

      <div class="lvl-block">
        <LevelRing level={m.level} xp={m.xp} next={m.xp_next} />
        <div>
          <p class="display big-level">{m.level}</p>
          <p class="title">{m.title}</p>
        </div>
      </div>
      <Meter value={m.xp} max={m.xp_next} label="Experience to next level" />
      <p class="dim xp-line"><span class="num">{m.xp} / {m.xp_next}</span> {say('XP to next level', 'to the next hunger')}{m.underdog_bonus > 0 ? ` · ${say('underdog bonus', 'underdog')} +${Math.round(m.underdog_bonus * 100)}%` : ''}</p>

      <Section title={say('Stats', 'body')}>
        <div class="stat-block">
          {STAT_KEYS.map((k) => {
            const gear = m.stats[k] - m.base_stats[k];
            return (
              <div class="card stat-cell" key={k}>
                <span class="sl">{STAT_LABEL[k]}</span>
                <b class="sv num">{m.stats[k]}</b>
                <span class="sb dim num">{say('base', 'base')} {m.base_stats[k]}</span>
                <span class="sg num">{gear === 0 ? '+0 gear' : `${gear > 0 ? '+' : ''}${gear} gear`}</span>
              </div>
            );
          })}
        </div>
      </Section>

      <Section title={say('Record', 'record')} aside={say('this device', 'this device')}>
        <dl class="record">
          {([['wins', say('Wins', 'fed')], ['losses', say('Losses', 'starved')], ['contacts', say('Contacts', 'contacts')], ['echoes', say('Echoes', 'echoes')], ['caches', say('Caches', 'caches')]] as const).map(([k, label]) => (
            <div class="card rec" key={k}><dd class="num">{rec[k]}</dd><dt>{label}</dt></div>
          ))}
        </dl>
      </Section>
    </>
  );
}
