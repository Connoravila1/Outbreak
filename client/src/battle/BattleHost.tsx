import { useRef, useState } from 'preact/hooks';
import { useModalFocus } from '../ui/a11y';
import { current, finishBattle, type Session } from './session';
import { Contact } from './Contact';
import { Fight } from './Fight';
import { Result } from './Result';
import { LevelUp } from './LevelUp';
import { isPvp } from './names';
import './battle.css';

type Stage = 'contact' | 'fight' | 'result';

function BattleFlow({ s }: { s: Extract<Session, { kind: 'battle' }> }) {
  const [stage, setStage] = useState<Stage>(s.contact ? 'contact' : 'fight');
  const ref = useRef<HTMLDivElement>(null);
  useModalFocus(ref, stage);
  return (
    <div ref={ref} tabIndex={-1} class={'battle-layer' + (stage === 'fight' && isPvp(s.battle) ? ' pvp-layer' : '')} role="dialog" aria-modal="true" aria-label="Fight">
      {stage === 'contact' && <Contact battle={s.battle} onStart={() => setStage('fight')} />}
      {stage === 'fight' && <Fight battle={s.battle} onDone={() => setStage('result')} />}
      {stage === 'result' && <Result battle={s.battle} onContinue={finishBattle} />}
    </div>
  );
}

/** Full-screen layer over the whole phone: CONTACT, fight playback, result, level-up. One at a time. */
function LevelUpLayer({ s }: { s: Extract<Session, { kind: 'levelup' }> }) {
  const ref = useRef<HTMLDivElement>(null);
  useModalFocus(ref);
  return (
    <div ref={ref} tabIndex={-1} class="battle-layer" role="dialog" aria-modal="true" aria-label="Level up">
      <LevelUp up={s.up} title={s.me.title} onContinue={finishBattle} />
    </div>
  );
}

export function BattleHost() {
  const s = current.value;
  if (!s) return null;
  if (s.kind === 'levelup') return <LevelUpLayer key={s.key} s={s} />;
  return <BattleFlow key={s.key} s={s} />;
}
