import { signal } from '@preact/signals';
import type { Rewards } from '../api';
import { Sheet } from './Sheet';
import { say } from './voice';
import { RewardLines, rewardsEmpty } from './RewardLines';

const shown = signal<{ title: string; r: Rewards } | null>(null);
export function showRewards(title: string, r: Rewards) { if (!rewardsEmpty(r)) shown.value = { title, r }; }

/** Generic "you received" sheet: mission claims, store purchases. */
export function RewardsSheet() {
  const s = shown.value;
  if (!s) return null;
  const close = () => { shown.value = null; };
  return (
    <Sheet title={s.title} onClose={close}>
      <div class="battle-summary">
        <p class="display result">{s.title}</p>
        <RewardLines r={s.r} />
      </div>
      <div class="sheet-actions"><button class="btn primary block" onClick={close}>{say('Done', 'done')}</button></div>
    </Sheet>
  );
}
