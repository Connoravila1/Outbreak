import { useState } from 'preact/hooks';
import { api, errorMessage, setToken, KEYS, storage } from '../api';
import { applyMe } from '../state/store';

/** "I already have an account": restore with a recovery code. */
export function Recover({ onBack, onRecovered }: { onBack: () => void; onRecovered: (hasFaction: boolean) => void }) {
  const [code, setCode] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const submit = async (e: Event) => {
    e.preventDefault();
    const c = code.trim();
    if (!c) { setErr('Enter your recovery code.'); return; }
    setBusy(true); setErr(null);
    try {
      const r = await api.recover(c);
      setToken(r.token);
      storage.set(KEYS.recovery, c);
      applyMe(r.me);
      onRecovered(!!r.me.faction);
    } catch (ex) {
      setErr(errorMessage(ex));
    } finally { setBusy(false); }
  };
  return (
    <div class="ob-screen recover">
      <form class="ob-card" onSubmit={submit} noValidate>
        <p class="eyebrow">Returning</p>
        <h1 class="ob-h">Welcome back.</h1>
        <p>Enter the recovery code you were given when you started.</p>
        <label class="sr-only" for="rc">Recovery code</label>
        <input id="rc" class="field big" value={code} autoFocus autocomplete="off" autocapitalize="characters" spellcheck={false}
          placeholder="XXXX-XXXX-XXXX" onInput={(e) => { setCode((e.target as HTMLInputElement).value); setErr(null); }} aria-invalid={!!err} />
        {err && <p class="ob-hint bad" role="alert">{err}</p>}
        <div class="ob-actions">
          <button class="btn primary block" type="submit" disabled={busy}>{busy ? '…' : 'Restore'}</button>
          <button class="btn block" type="button" onClick={onBack}>Back</button>
        </div>
      </form>
    </div>
  );
}
