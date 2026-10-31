import { useState } from 'preact/hooks';
import { api } from '../api';
import { banned } from '../state/moderation';
import { boot, signOut } from '../state/store';

/** `until` as a plain date: "12 November 2026". */
export function endDate(until: number): string {
  return new Date(until).toLocaleDateString(undefined, { day: 'numeric', month: 'long', year: 'numeric' });
}

/** The whole screen for a suspended account. No game behind it; the server refuses every request. */
export function Banned() {
  const b = banned.value;
  const [busy, setBusy] = useState(false);
  const [erase, setErase] = useState(false);
  const [typed, setTyped] = useState('');
  const [err, setErr] = useState<string | null>(null);
  if (!b) return null;
  const remove = async () => {
    setBusy(true); setErr(null);
    try {
      await api.deleteAccount();
      banned.value = null;
      signOut();
    } catch { setErr('Could not delete the account. Try again.'); setBusy(false); }
  };
  const again = async () => {
    setBusy(true);
    banned.value = null;
    await boot(); // a request that is still refused puts this screen straight back
    setBusy(false);
  };
  return (
    <div class="ob-screen banned">
      <div class="ob-card" role="alert">
        <p class="eyebrow">Account suspended</p>
        <h1 class="ob-h">You are suspended.</h1>
        <p>{b.reason || 'Breaking the community rules.'}</p>
        <p class="ob-hint">
          {b.until ? `Your account is back on ${endDate(b.until)}.` : 'This suspension has no end date.'}
        </p>
        <div class="ob-actions">
          <button class="btn primary block" disabled={busy} onClick={again}>{busy ? '…' : 'Check again'}</button>
          <button class="btn block" onClick={signOut}>Sign out of this phone</button>
        </div>
        {!erase && <button class="btn danger block" onClick={() => setErase(true)}>Delete my account</button>}
        {erase && (
          <div class="ob-actions">
            <p class="ob-hint">This erases your character and everything tied to it. Type DELETE to confirm.</p>
            <input class="field" value={typed} autocomplete="off" spellcheck={false} onInput={(e) => setTyped((e.target as HTMLInputElement).value)} placeholder="DELETE" autocapitalize="characters" />
            {err && <p class="ob-hint">{err}</p>}
            <button class="btn danger block" disabled={busy || typed.trim() !== 'DELETE'} onClick={remove}>Delete account</button>
          </div>
        )}
      </div>
    </div>
  );
}
