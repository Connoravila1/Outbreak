import { useState } from 'preact/hooks';
import { faction, lens, me } from '../state/store';
import { record } from '../state/record';
import { say } from '../ui/voice';
import { Sheet } from '../ui/Sheet';
import { Avatar } from '../avatar/Avatar';
import { Creator } from '../avatar/Creator';
import { hasAvatar } from '../avatar/spec';
import { Meter, Section } from '../ui/kit';
import { Icon } from '../ui/Icon';
import { LevelRing } from '../shell/TopBar';
import { STAT_KEYS, STAT_LABEL } from '../gear/util';

export function Profile() {
  const m = me.value;
  const [editing, setEditing] = useState(false);
  if (!m) return null;
  const f = faction.value;
  const server = m.record;
  const rec = server ?? record.value;
  const km = server ? (server.distance_m / 1000).toFixed(1) : null;
  return (
    <>
      <div class="id-card card">
        <div class="avatar-frame"><Avatar spec={m.avatar} faction={f ?? 'human'} level={m.level} lens={lens.value} size={72} label={`${m.callsign} portrait`} /></div>
        <div class="id-main">
          <p class="display callsign-big">{m.callsign ?? ''}</p>
          <p class="dim voice">{f === 'zombie' ? say('Zombie', 'infected') : say('Human', 'living')} </p>
          <button type="button" class="btn" onClick={() => setEditing(true)}>{hasAvatar(m.avatar) ? say('Edit', 'change') : say('Create avatar', 'make a face')}</button>
        </div>
      </div>

      {editing && (
        <Sheet title={say('Avatar', 'face')} onClose={() => setEditing(false)} tall>
          <Creator faction={f ?? 'human'} level={m.level} initial={m.avatar} onDone={() => setEditing(false)} onCancel={() => setEditing(false)} />
        </Sheet>
      )}

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

      {m.contact_rank && (
        <div class={`card rank-badge tier-${m.contact_rank.tier}`}>
          <Icon name="crossed-swords" size={26} />
          <div>
            <p class="display rb-name">{say(m.contact_rank.name, m.contact_rank.name.toLowerCase())}</p>
            <p class="dim rb-sub">
              {say('Contact rank', 'hunt rank')} · {m.contact_rank.wins} {say('wins', 'kills')}
              {m.contact_rank.next_at != null && ` · ${m.contact_rank.next_at - m.contact_rank.wins} ${say('to', 'to')} ${say(m.contact_rank.next_name ?? '', (m.contact_rank.next_name ?? '').toLowerCase())}`}
            </p>
          </div>
          <p class="rb-wl num" title="Contact wins / losses"><b>{server?.contacts_won ?? 0}</b>W <b>{server?.contacts_lost ?? 0}</b>L</p>
        </div>
      )}

      <Section title={say('Record', 'record')} aside={server ? undefined : say('this device', 'this device')}>
        <dl class="record">
          {([['wins', say('Wins', 'fed')], ['losses', say('Losses', 'starved')], ['contacts', say('Contacts', 'contacts')], ['echoes', say('Echoes', 'echoes')], ['caches', say('Caches', 'caches')]] as const).map(([k, label]) => (
            <div class="card rec" key={k}><dd class="num">{rec[k]}</dd><dt>{label}</dt></div>
          ))}
          {km != null && <div class="card rec"><dd class="num">{km}<small> km</small></dd><dt>{say('Walked', 'walked')}</dt></div>}
        </dl>
      </Section>
    </>
  );
}
