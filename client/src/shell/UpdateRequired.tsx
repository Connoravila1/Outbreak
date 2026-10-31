import { useState } from 'preact/hooks';
import { Capacitor } from '@capacitor/core';
import { api } from '../api';
import { isNative } from '../native/platform';
import { boot } from '../state/store';
import { checkMinClient, updateRequired } from '../state/update';
import '../onboarding/onboarding.css';

/** The store page for this phone, if the server named one. */
function storeUrl(): string | null {
  const s = updateRequired.value?.store;
  if (!s) return null;
  const p = Capacitor.getPlatform();
  return p === 'ios' ? s.ios : p === 'android' ? s.android : null;
}

/** The whole screen for a client the server no longer accepts. No game behind it. */
export function UpdateRequired() {
  const u = updateRequired.value;
  const [busy, setBusy] = useState(false);
  if (!u) return null;
  const url = storeUrl();
  const store = Capacitor.getPlatform() === 'ios' ? 'App Store' : 'Google Play';
  // Maybe the server's minimum was lowered, or the page is the web build and a reload fetches the new one.
  const again = async () => {
    setBusy(true);
    updateRequired.value = null;
    try { checkMinClient(await api.health()); } catch { /* offline: the next request decides */ }
    if (!updateRequired.value) await boot(); // a request that is still refused puts this screen straight back
    setBusy(false);
  };
  return (
    <div class="ob-screen update">
      <div class="ob-card" role="alert">
        <p class="eyebrow">New version needed</p>
        <h1 class="ob-h">Update to keep playing.</h1>
        <p>This version of Outbreak is too old to join the game. Get the new one, then open it again. Your character and progress are kept.</p>
        <div class="ob-actions">
          {url && <button class="btn primary block" onClick={() => window.open(url, '_blank')}>Open {store}</button>}
          {!isNative && <button class="btn primary block" onClick={() => location.reload()}>Reload the page</button>}
          <button class={'btn block' + (url || !isNative ? '' : ' primary')} disabled={busy} onClick={again}>{busy ? '…' : 'Check again'}</button>
        </div>
      </div>
    </div>
  );
}
