import { useEffect, useState } from 'preact/hooks';
import { loadProviders, termsAccepted, termsVersion } from '../auth/session';
import { TermsLinks } from '../safety/TermsSheet';
import { say } from '../ui/voice';

/** The house rules in three lines, the full terms and privacy policy one tap away, and an explicit accept. */
export function Terms({ onDone }: { onDone: () => void }) {
  const [agree, setAgree] = useState(false);
  const [failed, setFailed] = useState(false);
  const v = termsVersion.value;
  const load = () => { setFailed(false); void loadProviders().then(() => { if (termsVersion.value == null) setFailed(true); }); };
  useEffect(() => { if (v == null) load(); }, []);

  const accept = () => {
    if (v == null) return;
    termsAccepted.value = v;
    onDone();
  };

  return (
    <div class="ob-screen terms">
      <div class="ob-card">
        <p class="eyebrow">{say('The small print', 'the rules')}</p>
        <h1 class="ob-h">{say('House rules.', 'house rules.')}</h1>
        <ul class="ob-list">
          <li>{say('You play at your own risk, and you play safe.', 'you walk at your own risk. walk carefully.')}</li>
          <li>{say('Be decent. No slurs, no harassment, no cheating. Reports can end in a suspension.', 'be decent. no slurs. no cruelty. no cheating. reports can end a run.')}</li>
          <li>{say('You can delete your account and everything with it at any time.', 'you can erase yourself, any time. all of it.')}</li>
        </ul>
        <TermsLinks />
        <label class="agree">
          <input type="checkbox" checked={agree} onChange={(e) => setAgree((e.target as HTMLInputElement).checked)} />
          <span>{say('I have read the Terms of Service and the Privacy Policy, and I accept them.', 'i have read the terms and the privacy policy. i accept them.')}</span>
        </label>
        {failed && <p class="ob-error" role="alert">{say('Cannot reach the server. Check your connection.', 'no signal. check your connection.')}</p>}
        <div class="ob-actions">
          <button class="btn primary block" disabled={!agree || v == null} onClick={accept}>{say('Accept and continue', 'accept. go on.')}</button>
          {failed && <button class="btn block" onClick={load}>{say('Try again', 'again')}</button>}
        </div>
      </div>
    </div>
  );
}
