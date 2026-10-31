import type { Stance } from '../api';
import { Icon, type IconName } from '../ui/Icon';
import { say } from '../ui/voice';
import { faction } from '../state/store';
import { STANCES, chooseStance, lastStance, stanceHint, stanceName, stanceText } from '../state/stance';
import './stance.css';

const ICON: Record<Stance, IconName> = { aggressive: 'fist', careful: 'shield', evasive: 'sprint' };

/** The three-way choice above Engage. The hint line appears once this enemy type has been fought a few times. */
export function StanceControl({ archetype }: { archetype?: string | null }) {
  const f = faction.value ?? 'human';
  const cur = lastStance.value;
  const hint = archetype ? stanceHint(archetype, f) : null;
  return (
    <div class="stance">
      <p class="stance-label">{say('Stance', 'how you hunt')}</p>
      <div class="stance-seg" role="radiogroup" aria-label={say('Stance', 'how you hunt')}>
        {STANCES.map((s) => (
          <button key={s} class="stance-btn" role="radio" aria-checked={cur === s} onClick={() => chooseStance(s)}>
            <Icon name={ICON[s]} size={22} />
            <span>{stanceName(s, f)}</span>
          </button>
        ))}
      </div>
      <p class="stance-text dim">{stanceText(cur)}</p>
      {hint && <p class="stance-hint" role="note">{hint}</p>}
    </div>
  );
}
