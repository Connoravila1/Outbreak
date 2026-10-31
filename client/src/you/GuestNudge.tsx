import { useEffect, useState } from 'preact/hooks';
import { KEYS, storage } from '../api';
import { me } from '../state/store';
import { ProviderButtons } from '../auth/ProviderButtons';
import { Sheet } from '../ui/Sheet';
import { pushToast } from '../ui/kit';
import { say } from '../ui/voice';

/** Level 3 and level 10: once each, offer to keep the survivor. A sheet that can always be closed. */
export function GuestNudge() {
  const [open, setOpen] = useState(false);
  const guest = !!me.value?.account.guest;
  const level = me.value?.level ?? 0;

  useEffect(() => {
    if (!guest) return;
    const stage = level >= 10 ? 10 : level >= 3 ? 3 : 0;
    if (stage <= Number(storage.get(KEYS.guestNudge) ?? 0)) return;
    // Let a level-up or a fight result finish first.
    const h = window.setTimeout(() => { storage.set(KEYS.guestNudge, String(stage)); setOpen(true); }, 4000);
    return () => window.clearTimeout(h);
  }, [guest, level]);

  if (!open || !guest) return null;
  return (
    <Sheet title={say('Keep your survivor', 'keep this body')} onClose={() => setOpen(false)}>
      <h2 class="display">{say('Keep your survivor', 'keep this body')}</h2>
      <p>{say('Your survivor lives only on this phone. Link an account to keep it.', 'this body lives only on this phone. tie it to an account to keep it.')}</p>
      <ProviderButtons intent="link" onDone={() => { setOpen(false); pushToast(say('Account linked.', 'tied down.'), 'good'); }} />
      <button class="ob-link" onClick={() => setOpen(false)}>{say('Not now', 'not now')}</button>
    </Sheet>
  );
}
