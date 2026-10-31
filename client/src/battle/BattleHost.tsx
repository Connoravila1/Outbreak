import { useState } from 'preact/hooks';
import { current, finishBattle, type Session } from './session';
import { Contact } from './Contact';
import { Fight } from './Fight';
import { Result } from './Result';
import { LevelUp } from './LevelUp';
import './battle.css';

type Stage = 'contact' | 'fight' | 'result';

function BattleFlow({ s }: { s: Extract<Session, { kind: 'battle' }> }) {
  const [stage, setStage] = useState<Stage>(s.contact ? 'contact' : 'fight');
  return (
    <div class="battle-layer" role="dialog" aria-modal="true" aria-label="Fight">
      {stage === 'contact' && <Contact battle={s.battle} onStart={() => setStage('fight')} />}
      {stage === 'fight' && <Fight battle={s.battle} onDone={() => setStage('result')} />}
      {stage === 'result' && <Result battle={s.battle} onContinue={finishBattle} />}
    </div>
  );
}

/** Full-screen layer over the whole phone: CONTACT, fight playback, result, level-up. One at a time. */
export function BattleHost() {
  const s = current.value;
  if (!s) return null;
  if (s.kind === 'levelup') {
    return (
      <div class="battle-layer" role="dialog" aria-modal="true" aria-label="Level up">
        <LevelUp key={s.key} up={s.up} title={s.me.title} onContinue={finishBattle} />
      </div>
    );
  }
  return <BattleFlow key={s.key} s={s} />;
}
