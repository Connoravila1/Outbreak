import { signal } from '@preact/signals';
import type { GameEvent } from '../api';
import { Sheet } from '../ui/Sheet';
import { say } from '../ui/voice';
import { ago } from '../ui/hooks';
import { current, enqueueBattle } from '../battle/session';
import './patrol.css';

/** Events that were waiting when the app opened (they happened more than a minute before this poll). */
export const patrolReport = signal<GameEvent[]>([]);

/** An event older than this when it reaches the app was held while the player was away. */
export const AWAY_MS = 60_000;

export function addToReport(evs: GameEvent[]) {
  if (evs.length) patrolReport.value = [...patrolReport.peek(), ...evs].slice(-50);
}

/** "While you were patrolling": what happened with the app closed. Each Contact replays its fight. */
export function PatrolReport() {
  const list = patrolReport.value;
  // The fight plays full-screen over this; the card is back when it ends.
  if (!list.length || current.value) return null;
  const close = () => { patrolReport.value = []; };
  return (
    <Sheet title={say('While you were patrolling', 'while you were out')} onClose={close}>
      <h2 class="display pt-title">{say('While you were patrolling', 'while you were out')}</h2>
      <ul class="pt-list">
        {list.map((e) => (
          <li class="pt-item" key={e.id}>
            <span class="pt-text">
              <span>{e.text}</span>
              <small>{ago(e.at)}</small>
            </span>
            {e.type === 'contact' && e.battle && (
              <button class="btn" onClick={() => enqueueBattle(e.battle!, true, true)}>{say('Replay', 'again')}</button>
            )}
          </li>
        ))}
      </ul>
      <div class="sheet-actions">
        <button class="btn primary block" onClick={close}>{say('Done', 'done')}</button>
      </div>
    </Sheet>
  );
}
