import './safety.css';
import { KEYS, storage } from '../api';
import { say } from '../ui/voice';

/** [lead, rest] in each lens's voice. */
function lines(): [string, string][] {
  return [
    [say('Eyes up.', 'eyes up.'), say('Watch traffic and your surroundings, not the screen.', 'the road kills faster than the dead do.')],
    [say('Stay off private property.', 'not your ground.'), say('Fences, gates and signs mean no. Nothing here is worth trespassing for.', 'fences, gates, signs. leave them be.')],
    [say('Never play while driving or cycling.', 'no wheels.'), say('Fights will not start while you are moving fast, anyway.', 'not driving. not cycling. nothing fights until you are on foot.')],
    [say('Take care after dark.', 'dark is hungrier.'), say('Go with others and keep to lit, public places.', 'go with others. stay where there is light.')],
    [say('Sanctuaries are off limits.', 'quiet places.'), say('Hospitals, schools and places of worship stay quiet. So do you.', 'hospitals, schools, where people pray. leave them quiet.')],
  ];
}

/** The five rules of the road, in the lens voice. */
export function SafetyRules() {
  return (
    <>
      <div class="safety-tape" aria-hidden="true" />
      <p class="eyebrow">{say('Field rules', 'before you hunt')}</p>
      <h1 class="ob-h">{say('Stay alive out there.', 'keep breathing out there.')}</h1>
      <ol class="safety-list">
        {lines().map(([lead, rest]) => <li key={lead}><b>{lead}</b> {rest}</li>)}
      </ol>
    </>
  );
}

export const safetySeen = () => storage.get(KEYS.safety) === '1';
export const markSafetySeen = () => storage.set(KEYS.safety, '1');

/** Before the first map: the rules, one button. Shown in onboarding, and once on a phone that signed in to an existing account. */
export function SafetyStep({ onDone }: { onDone: () => void }) {
  return (
    <div class="ob-screen safety">
      <div class="ob-card safety-card">
        <SafetyRules />
        <button class="btn primary block" autoFocus onClick={() => { markSafetySeen(); onDone(); }}>{say('I understand', 'i understand')}</button>
      </div>
    </div>
  );
}
