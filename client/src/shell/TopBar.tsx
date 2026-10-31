import { faction, lens, me, world } from './../state/store';
import { Avatar } from '../avatar/Avatar';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import './shell.css';

const C = 2 * Math.PI * 18;

/** Level progress ring; with an avatar the portrait sits inside and the level moves to a badge. */
export function LevelRing({ level, xp, next, avatar }: { level: number; xp: number; next: number; avatar?: unknown }) {
  const frac = next > 0 ? Math.min(1, xp / next) : 0;
  return (
    <div class="ring" role="img" aria-label={`Level ${level}, ${xp} of ${next} XP`}>
      <svg viewBox="0 0 44 44" aria-hidden="true">
        <circle class="track" cx="22" cy="22" r="18" />
        <circle class="prog" cx="22" cy="22" r="18" stroke-dasharray={C} stroke-dashoffset={C * (1 - frac)} />
      </svg>
      {avatar !== undefined ? (
        <>
          <span class="ring-face"><Avatar spec={avatar as Record<string, unknown> | null} faction={faction.value ?? 'human'} level={level} lens={lens.value} size={34} /></span>
          <b class="num lvl-badge">{level}</b>
        </>
      ) : <b class="num">{level}</b>}
    </div>
  );
}

export function TopBar() {
  const m = me.value;
  if (!m) return null;
  const hostile = world.value?.hostiles_near;
  return (
    <header class="topbar">
      <div class="id-plate">
        <LevelRing level={m.level} xp={m.xp} next={m.xp_next} avatar={m.avatar} />
        <div class="id-text">
          <span class="callsign display">{m.callsign ?? ""}</span>
          <span class="title">{m.title}</span>
        </div>
      </div>
      {hostile && (
        <div class="hostiles hazard-tape" role="status">
          <Icon name="radar-sweep" size={18} />
          <span>{say('Hostiles near', 'something hunts')}</span>
        </div>
      )}
    </header>
  );
}
