import { ProviderButtons, type Done } from '../auth/ProviderButtons';
import { say } from '../ui/voice';

/** After the faction is committed: tie the survivor to an account, or play as a guest for now. */
export function Save({ onDone, onGuest }: { onDone: (d: Done) => void; onGuest: () => void }) {
  return (
    <div class="ob-screen save">
      <div class="ob-card">
        <p class="eyebrow">{say('Account', 'the way back')}</p>
        <h1 class="ob-h display breathe">{say('Save your survivor', 'save your survivor')}</h1>
        <p>{say('Sign in once and you can pick this character up on any phone. We keep only a sign-in ID and, if you allow it, your email.', 'sign in once and this body follows you to any phone. we keep an id. an email, if you let us.')}</p>
        <ProviderButtons intent="signin" onDone={onDone} />
        <button class="ob-link" type="button" onClick={onGuest}>{say('Play as guest', 'play as guest')}</button>
        <p class="ob-hint">{say('Guests can link an account later under You, Settings.', 'you can tie it down later. you, settings.')}</p>
      </div>
    </div>
  );
}
