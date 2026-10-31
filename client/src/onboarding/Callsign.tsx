import { useState } from 'preact/hooks';
import { api, errorMessage, type Faction } from '../api';
import { applyMe } from '../state/store';
import { say } from '../ui/voice';

const OK = /^[A-Za-z0-9_-]+$/;

export function validateCallsign(raw: string): string | null {
  const v = raw.trim();
  if (v.length < 3) return 'Three characters at least.';
  if (v.length > 16) return 'Sixteen characters at most.';
  if (!OK.test(v)) return 'Letters, numbers, - and _ only.';
  return null;
}

/** "What do they call you?" The name is chosen once, after the faction is committed. */
export function Callsign({ faction, onDone, renaming }: { faction: Faction; onDone: () => void; renaming?: boolean }) {
  const [name, setName] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const problem = name ? validateCallsign(name) : null;

  const submit = async (e: Event) => {
    e.preventDefault();
    const bad = validateCallsign(name);
    if (bad) { setErr(bad); return; }
    setBusy(true); setErr(null);
    try {
      applyMe((await api.setCallsign(name.trim())).me);
      onDone();
    } catch (ex) {
      setErr(errorMessage(ex));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div class={'ob-screen ob-callsign ' + faction}>
      <form class="ob-card" onSubmit={submit} noValidate>
        <p class="eyebrow">{renaming ? say('Callsign reset', 'name taken back') : say('Identity', 'name')}</p>
        <h1 class="ob-h display breathe">{renaming ? say('Choose a new callsign.', 'choose a new name.') : say('What do they call you?', 'what do they call you?')}</h1>
        {renaming && <p class="ob-hint">{say('Your old callsign broke the naming rules, so it was reset. Pick another; your progress is kept.', 'the old name broke the rules and was taken. pick another. you keep everything.')}</p>}
        <label class="sr-only" for="cs">Callsign</label>
        <input id="cs" class="field big" value={name} maxLength={16} autoFocus autocomplete="off" autocapitalize="off" spellcheck={false}
          placeholder={say('Callsign', 'a name')}
          aria-invalid={!!(problem || err)} aria-describedby="cs-help"
          onInput={(e) => { setName((e.target as HTMLInputElement).value); setErr(null); }} />
        <p id="cs-help" class={'ob-hint' + (problem || err ? ' bad' : '')} role={err ? 'alert' : undefined}>
          {err ?? problem ?? say('3 to 16 characters. Other players will see this on leaderboards, never at a fight.', '3 to 16 characters. seen on boards. never in a fight.')}
        </p>
        <button class="btn primary block" type="submit" disabled={busy || !name.trim()}>
          {busy ? '…' : say('Continue', 'continue')}
        </button>
      </form>
    </div>
  );
}
