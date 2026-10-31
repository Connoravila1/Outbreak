import { useEffect } from 'preact/hooks';
import { say } from '../ui/voice';
import { useNow } from '../ui/hooks';
import { patrolAvailable, patrolStatus, refreshPatrol } from '../native/patrol';
import { patrolLeft, patrolSheetOpen } from './PatrolSheet';
import './patrol.css';

/** The map's Patrol toggle: hazard-tape "Patrol" (survey) / "roam" (heat); pulses while on. Phone app only. */
export function PatrolButton() {
  const st = patrolStatus.value;
  const now = useNow(1000);
  useEffect(() => { if (patrolAvailable) void refreshPatrol(); }, []);
  if (!patrolAvailable) return null;
  const on = !!st?.active && (st.endsAt === 0 || st.endsAt > now);
  return (
    <button
      class={'patrol-btn' + (on ? ' on' : '')}
      aria-pressed={on}
      aria-label={on ? say('Patrol is on. Open patrol controls', 'roaming. open controls') : say('Patrol', 'roam')}
      onClick={() => { patrolSheetOpen.value = true; }}
    >
      <span class="pb-name">{say('Patrol', 'roam')}</span>
      {on && st && <span class="pb-left num">{patrolLeft(st.endsAt, now)}</span>}
    </button>
  );
}
