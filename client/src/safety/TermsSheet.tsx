import { useEffect, useState } from 'preact/hooks';
import { api, errorMessage } from '../api';
import { applyMe, me } from '../state/store';
import { Sheet } from '../ui/Sheet';
import { say } from '../ui/voice';

/** The terms and privacy pages, side by side. */
export function TermsLinks() {
  return (
    <p class="ob-hint terms-links">
      <a href="terms.html" target="_blank" rel="noopener">{say('Terms of service', 'terms')}</a>
      {' · '}
      <a href="privacy.html" target="_blank" rel="noopener">{say('Privacy policy', 'privacy')}</a>
    </p>
  );
}

/**
 * Asked once: a player from before the terms existed, or after they changed. Closing it leaves the
 * question for next launch; nothing is blocked meanwhile.
 */
export function TermsSheet() {
  const t = me.value?.terms;
  const [late, setLate] = useState(false);
  const [skipped, setSkipped] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  // Let a level-up or a fight result finish first.
  useEffect(() => { const h = window.setTimeout(() => setLate(true), 2500); return () => window.clearTimeout(h); }, []);
  if (!t?.needs_accept || skipped || !late) return null;

  const accept = async () => {
    setBusy(true); setErr(null);
    try { applyMe((await api.acceptTerms(t.current)).me); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  };
  const first = t.accepted === 0;
  return (
    <Sheet title={say('Terms of service', 'terms')} onClose={() => setSkipped(true)}>
      <h2 class="display">{first ? say('One last thing', 'one last thing') : say('The terms changed', 'the terms changed')}</h2>
      <p>{first
        ? say('Outbreak now has written terms and a privacy policy. Read them, and accept to keep playing with this survivor.', 'there are written terms now. read them. accept to keep walking.')
        : say('We updated the terms. The short version is on the page. Accept to keep playing.', 'the terms shifted. read what changed. accept to keep walking.')}</p>
      <TermsLinks />
      <div class="sheet-actions">
        <button class="btn primary block" disabled={busy} onClick={accept}>{busy ? '…' : say('Accept', 'accept')}</button>
        <button class="ob-link" type="button" onClick={() => setSkipped(true)}>{say('Not now', 'not now')}</button>
        {err && <p class="reason" role="alert" style={{ color: 'var(--danger)' }}>{err}</p>}
      </div>
    </Sheet>
  );
}
