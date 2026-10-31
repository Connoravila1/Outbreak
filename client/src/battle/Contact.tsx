import { useEffect, useState } from 'preact/hooks';
import type { Battle } from '../api';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import * as fx from '../audio/fx';

/** The interrupt: alarm, vibration, who is close, and their gear typed in. Then the fight starts by itself. */
export function Contact({ battle, onStart }: { battle: Battle; onStart: () => void }) {
  const foe = battle.b;
  const gear = foe.gear.join('\n');
  const [n, setN] = useState(0);
  const word = foe.faction === 'zombie' ? 'Zombie' : 'Human';
  const line = say(`A ${word} is close. Level ${foe.level}.`, `${foe.faction === 'zombie' ? 'the dead' : 'the living'}. close. level ${foe.level}.`);

  useEffect(() => { fx.contactAlarm(); }, []);
  useEffect(() => {
    if (n < gear.length) {
      const t = window.setTimeout(() => { setN(n + 1); if (gear[n] !== ' ' && gear[n] !== '\n' && n % 2 === 0) fx.tick(); }, 34);
      return () => clearTimeout(t);
    }
    const t = window.setTimeout(onStart, 1300);
    return () => clearTimeout(t);
  }, [n]);

  return (
    <div class="contact" role="alertdialog" aria-label="Contact" onClick={onStart}>
      <div class="contact-pulse" aria-hidden="true" />
      <Icon name="radar-sweep" size={48} class="ct-icon" />
      <h1 class="ct-word display breathe">{say('CONTACT', 'contact')}</h1>
      <p class="ct-line">{line}</p>
      {foe.title && <p class="dim ct-title voice">{foe.title}</p>}
      {gear && <pre class="ct-gear" aria-label={`Carrying ${foe.gear.join(', ')}`}>{gear.slice(0, n)}<span class="caret" aria-hidden="true">▌</span></pre>}
      <p class="dim ct-hint">{say('Fighting. Tap to skip ahead.', 'it is already on you.')}</p>
    </div>
  );
}
