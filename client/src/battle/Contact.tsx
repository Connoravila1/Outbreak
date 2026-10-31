import { useEffect } from 'preact/hooks';
import type { Battle } from '../api';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import * as fx from '../audio/fx';

/** The interrupt: alarm, vibration, who is close. Then the stage opens by itself and shows what they carry. */
export function Contact({ battle, onStart }: { battle: Battle; onStart: () => void }) {
  const foe = battle.b;
  const word = foe.faction === 'zombie' ? 'Zombie' : 'Human';
  const line = say(`A ${word} is close. Level ${foe.level}.`, `${foe.faction === 'zombie' ? 'the dead' : 'the living'}. close. level ${foe.level}.`);

  useEffect(() => { fx.contactAlarm(); }, []);
  useEffect(() => {
    const t = window.setTimeout(onStart, 1700);
    return () => clearTimeout(t);
  }, []);

  return (
    <div class="contact" role="alertdialog" aria-label="Contact" onClick={onStart}>
      <div class="contact-pulse" aria-hidden="true" />
      <Icon name="radar-sweep" size={48} class="ct-icon" />
      <h1 class="ct-word display breathe">{say('CONTACT', 'contact')}</h1>
      <p class="ct-line">{line}</p>
      {foe.title && <p class="dim ct-title voice">{foe.title}</p>}
      <p class="dim ct-hint">{say('Fighting. Tap to skip ahead.', 'it is already on you.')}</p>
    </div>
  );
}
