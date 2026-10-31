import { useState } from 'preact/hooks';
import { api, errorMessage, setToken, KEYS, storage, type Faction } from '../api';
import { applyMe, me } from '../state/store';
import { say } from '../ui/voice';

const OK = /^[A-Za-z0-9_ -]+$/;

export function validateCallsign(raw: string): string | null {
  const v = raw.trim();
  if (v.length < 3) return 'Three characters at least.';
  if (v.length > 16) return 'Sixteen characters at most.';
  if (!OK.test(v)) return 'Letters, numbers, spaces, - and _ only.';
  return null;
}

/** "What do they call you?" Registers, then commits the faction chosen on the split screen. */
export function Callsign({ faction, accountExists, onDone }: { faction: Faction; accountExists: boolean; onDone: () => void }) {
  const [name, setName] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [registered, setRegistered] = useState(accountExists);
  const problem = name ? validateCallsign(name) : null;

  const submit = async (e: Event) => {
    e.preventDefault();
    const bad = registered ? null : validateCallsign(name);
    if (bad) { setErr(bad); return; }
    setBusy(true); setErr(null);
    try {
      if (!registered) {
        const r = await api.register(name.trim());
        setToken(r.token);
        storage.set(KEYS.recovery, r.recovery_code);
        applyMe(r.me);
        setRegistered(true);
      }
      const r2 = await api.chooseFaction(faction);
      applyMe(r2.me);
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
        <p class="eyebrow">{say('Identity', 'name')}</p>
        <h1 class="ob-h display breathe">{registered ? `${me.value?.callsign ?? ''}` : say('What do they call you?', 'what do they call you?')}</h1>
        {!registered && (
          <>
            <label class="sr-only" for="cs">Callsign</label>
            <input id="cs" class="field big" value={name} maxLength={16} autoFocus autocomplete="off" autocapitalize="off" spellcheck={false}
              placeholder={say('Callsign', 'a name')}
              aria-invalid={!!(problem || err)} aria-describedby="cs-help"
              onInput={(e) => { setName((e.target as HTMLInputElement).value); setErr(null); }} />
            <p id="cs-help" class={'ob-hint' + (problem || err ? ' bad' : '')} role={err ? 'alert' : undefined}>
              {err ?? problem ?? say('3 to 16 characters. Other players will see this on leaderboards, never at a fight.', '3 to 16 characters. seen on boards. never in a fight.')}
            </p>
          </>
        )}
        {registered && err && <p class="ob-hint bad" role="alert">{err}</p>}
        <button class="btn primary block" type="submit" disabled={busy || (!registered && !name.trim())}>
          {busy ? '…' : registered ? say('Try again', 'again') : say('Continue', 'continue')}
        </button>
      </form>
    </div>
  );
}
