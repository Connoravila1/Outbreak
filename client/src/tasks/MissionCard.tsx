import { useState } from 'preact/hooks';
import { api, errorMessage, type Mission } from '../api';
import { applyMe } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { Action, ErrorLine, Meter } from '../ui/kit';
import { enqueueLevelUp } from '../battle/session';
import { showRewards } from '../ui/RewardsSheet';
import { claim as claimSound } from '../audio/fx';

function rewardBits(m: Mission, weekly?: boolean): string {
  const r = m.rewards;
  const bits = [`${r.xp} XP`];
  if (r.salvage) bits.push(`${r.salvage} salvage`);
  if (r.items.length) bits.push(`${r.items.length} item${r.items.length > 1 ? 's' : ''}`);
  if (weekly && !r.items.length) bits.push(say('Rare+ item', 'a rare+ spoil'));
  const c = Object.values(r.consumables).reduce((a, b) => a + b, 0);
  if (c) bits.push(`${c} supply`);
  return bits.join(' · ');
}

export function MissionCard({ m, weekly }: { m: Mission; weekly?: boolean }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const done = m.progress >= m.target;
  const left = Math.max(0, m.target - m.progress);
  const claim = async () => {
    setBusy(true); setErr(null);
    try {
      const r = await api.claimMission(m.id);
      applyMe(r.me);
      claimSound();
      showRewards(say('Mission done', 'taken'), r.rewards);
      enqueueLevelUp(r.rewards.level_up, r.me);
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  };
  return (
    <li class={'card mission' + (m.claimed ? ' claimed' : done ? ' ready' : '')}>
      <div class="m-top">
        {weekly && <span class="label-tape">{say('Weekly', 'weekly')}</span>}
        <p class="m-text">{m.text}</p>
      </div>
      <Meter value={Math.min(m.progress, m.target)} max={m.target} label={`${m.text} progress`} />
      <div class="m-row">
        <span class="num dim">{Math.min(m.progress, m.target)} / {m.target}</span>
        <span class="m-rewards"><Icon name="star-medal" size={16} />{rewardBits(m, weekly)}</span>
      </div>
      {m.claimed
        ? <p class="m-claimed"><Icon name="check-mark" size={18} />{say('Claimed.', 'taken.')}</p>
        : <Action id={'why-' + m.id} primary={done} block reason={done ? null : say(`${left} more to go.`, `${left} more.`)} busy={busy} onClick={claim}>Claim</Action>}
      <ErrorLine text={err} />
    </li>
  );
}
