import { useState } from 'preact/hooks';
import { faction } from '../state/store';
import { Icon, type IconName } from '../ui/Icon';
import { KEYS, storage } from '../api';

const CARDS: Record<'human' | 'zombie', { icon: IconName; head: string; body: string }[]> = {
  human: [
    { icon: 'boot-prints', head: 'Walk', body: 'The map is your street. Crates, drops and the infected turn up as you move. Walk a block and it changes.' },
    { icon: 'crossed-swords', head: 'Tap to fight', body: 'Tap anything on the map. Close enough, you can engage. Fights resolve on their own. Read the threat first.' },
    { icon: 'radar-sweep', head: 'They find you', body: 'Other players are out there. When one gets close, you will fight without knowing who. Nobody sees where you are.' },
  ],
  zombie: [
    { icon: 'boot-prints', head: 'walk', body: 'the streets are warm. prey and remains glow where you pass. walk a block and it shifts.' },
    { icon: 'fangs', head: 'tap to bite', body: 'tap what glows. close enough, you can take it. the fight finishes itself. feel its heat first.' },
    { icon: 'eyeball', head: 'they find you', body: 'something living is always near. when it is close you fight without knowing who. no one sees where you are.' },
  ],
};

/** Three cards in the faction's voice, then the game. */
export function Briefing({ onDone }: { onDone: () => void }) {
  const f = faction.value ?? 'human';
  const cards = CARDS[f];
  const [i, setI] = useState(0);
  const c = cards[i];
  const last = i === cards.length - 1;
  return (
    <div class="ob-screen briefing">
      <div class="ob-card wide">
        <p class="eyebrow">{f === 'human' ? `Briefing ${i + 1} of 3` : `${i + 1} of 3`}</p>
        <div class="brief-card card" key={i}>
          <Icon name={c.icon} size={64} />
          <h1 class="ob-h display breathe">{c.head}</h1>
          <p>{c.body}</p>
        </div>
        <div class="dots" aria-hidden="true">{cards.map((_, k) => <i key={k} class={k === i ? 'on' : ''} />)}</div>
        <button class="btn primary block" autoFocus onClick={() => { if (last) { storage.set(KEYS.briefed, '1'); onDone(); } else setI(i + 1); }}>
          {last ? (f === 'human' ? 'Go outside' : 'go hunt') : (f === 'human' ? 'Next' : 'next')}
        </button>
      </div>
    </div>
  );
}
