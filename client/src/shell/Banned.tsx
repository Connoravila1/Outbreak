import { useState } from 'preact/hooks';
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
  if (!b) return null;
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
      </div>
    </div>
  );
}
