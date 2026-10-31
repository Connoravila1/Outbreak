import { useState } from 'preact/hooks';
import { signal } from '@preact/signals';
import { api, errorMessage } from '../api';
import { me, signOut } from '../state/store';
import { ProviderButtons } from '../auth/ProviderButtons';
import { providerLabel } from '../auth/session';
import { say } from '../ui/voice';
import { Section, pushToast } from '../ui/kit';

const reminderDismissed = signal(false);

/** The gentle guest reminder at the top of the You tab. Dismissible, never blocking. */
export function GuestNote() {
  const m = me.value;
  if (!m?.account.guest || reminderDismissed.value) return null;
  return (
    <aside class="guest-note" role="note">
      <span class="gn-text">{say('Your survivor lives only on this phone. Link an account to keep it.', 'this body lives only on this phone. tie it to an account to keep it.')}</span>
      <span class="gn-act">
        <button class="btn" onClick={() => document.getElementById('account')?.scrollIntoView({ behavior: 'smooth', block: 'start' })}>{say('Link', 'link')}</button>
        <button class="btn" aria-label={say('Dismiss reminder', 'dismiss')} onClick={() => { reminderDismissed.value = true; }}>×</button>
      </span>
    </aside>
  );
}

type Panel = null | 'signout' | 'delete';

/** Settings, Account: who you are signed in as, linking, signing out, deleting. */
export function Account() {
  const m = me.value;
  const [panel, setPanel] = useState<Panel>(null);
  const [typed, setTyped] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  if (!m) return null;
  const acct = m.account;

  const remove = async () => {
    setBusy(true); setErr(null);
    try {
      await api.deleteAccount();
      signOut();
    } catch (e) { setErr(errorMessage(e)); setBusy(false); }
  };

  return (
    <Section title={say('Account', 'account')}>
      <div id="account" class="acct-list">
        <div class="acct-row">
          <span class="dim">{say('Signed in with', 'tied to')}</span>
          <b>{acct.guest ? say('Guest (this phone only)', 'nothing. this phone only') : acct.providers.map(providerLabel).join(', ')}</b>
        </div>
        {acct.email && <div class="acct-row"><span class="dim">{say('Email', 'email')}</span><b>{acct.email}</b></div>}
      </div>

      <p class="acct-sub">{acct.guest ? say('Keep your survivor', 'keep this body') : say('Add another sign-in', 'add another way back')}</p>
      <ProviderButtons intent="link" skip={acct.providers} onDone={() => pushToast(say('Account linked.', 'tied down.'), 'good')} />

      <div class="set-actions">
        <button class="btn block" aria-expanded={panel === 'signout'} onClick={() => { setPanel(panel === 'signout' ? null : 'signout'); setErr(null); }}>{say('Sign out', 'sign out')}</button>
        {panel === 'signout' && (
          <div class="acct-panel" role="group" aria-label={say('Sign out', 'sign out')}>
            {acct.guest ? (
              <>
                <p><b>{say('This will lose your character.', 'this will lose your body.')}</b></p>
                <p>{say('A guest survivor lives only on this phone. Link an account first if you want to come back to it.', 'a guest body lives only on this phone. tie it to an account first if you want it back.')}</p>
                <button class="btn block" onClick={() => { setPanel(null); document.getElementById('account')?.scrollIntoView({ behavior: 'smooth' }); }}>{say('Link an account instead', 'tie it down instead')}</button>
                <button class="btn danger block" onClick={() => signOut()}>{say('Sign out and lose it', 'sign out and lose it')}</button>
              </>
            ) : (
              <>
                <p>{say('You can sign back in with the same account any time.', 'you can come back with the same account.')}</p>
                <button class="btn primary block" onClick={() => signOut()}>{say('Sign out', 'sign out')}</button>
              </>
            )}
          </div>
        )}

        <button class="btn danger block" aria-expanded={panel === 'delete'} onClick={() => { setPanel(panel === 'delete' ? null : 'delete'); setTyped(''); setErr(null); }}>{say('Delete account', 'delete account')}</button>
        {panel === 'delete' && (
          <form class="acct-panel" onSubmit={(e) => { e.preventDefault(); if (typed === 'DELETE') void remove(); }}>
            <p><b>{say('This deletes your survivor for good.', 'this ends your body for good.')}</b></p>
            <p>{say('Your character, gear, record and sign-in are erased from the server and from this phone. Clan chat lines you wrote stay, as "[deleted]". It cannot be undone.', 'the body, the gear, the record, the sign-in: gone from the server and this phone. old clan chat stays as "[deleted]". no undo.')}</p>
            <label class="dim lab" for="del-confirm">{say('Type DELETE to confirm', 'type DELETE to confirm')}</label>
            <input id="del-confirm" class="field" value={typed} autocomplete="off" autocapitalize="characters" spellcheck={false}
              onInput={(e) => setTyped((e.target as HTMLInputElement).value)} />
            <button class="btn danger block" type="submit" disabled={busy || typed !== 'DELETE'}>{busy ? '…' : say('Delete my account', 'delete it')}</button>
            {err && <p class="ob-hint bad" role="alert">{err}</p>}
          </form>
        )}
      </div>
    </Section>
  );
}
