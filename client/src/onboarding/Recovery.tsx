import { useState } from 'preact/hooks';
import { KEYS, storage } from '../api';
import { say } from '../ui/voice';

/** The recovery code, shown once here and always in Settings. */
export function RecoveryCode({ onDone }: { onDone: () => void }) {
  const code = storage.get(KEYS.recovery) ?? '';
  const [copied, setCopied] = useState(false);
  return (
    <div class="ob-screen recovery">
      <div class="ob-card">
        <p class="eyebrow">{say('Recovery', 'the way back')}</p>
        <h1 class="ob-h display breathe">{say('Keep this code.', 'keep this code.')}</h1>
        <p>{say('It is the only way to get this character back on a new phone. There is no email and no password.', 'it is the only way back to this body on a new phone. no email. no password.')}</p>
        <p class="code num" aria-label="Recovery code">{code.split('-').map((g, i, a) => <span key={i}><span class="grp">{i < a.length - 1 ? g + '-' : g}</span><wbr /></span>)}</p>
        <div class="ob-actions">
          <button class="btn block" onClick={() => { void navigator.clipboard?.writeText(code).then(() => setCopied(true), () => undefined); }}>{copied ? say('Copied', 'copied') : say('Copy', 'copy')}</button>
          <button class="btn primary block" onClick={onDone}>{say('I have it', 'i have it')}</button>
        </div>
        <p class="ob-hint">{say('You can find it again under You, Settings.', 'it also lives under you, settings.')}</p>
      </div>
    </div>
  );
}
