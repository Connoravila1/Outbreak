import { useEffect, useState } from 'preact/hooks';
import { api, errorMessage, setToken, type Faction } from '../api';
import { applyMe, me } from '../state/store';
import { termsAccepted } from '../auth/session';
import { say } from '../ui/voice';

/** Quietly creates the guest survivor (if there is no account yet) and commits the faction. */
export function Commit({ faction, onDone }: { faction: Faction; onDone: () => void }) {
  const [err, setErr] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        if (!me.value) {
          const r = await api.register(termsAccepted.value ?? 0);
          setToken(r.token);
          applyMe(r.me);
        }
        if (!me.value?.faction) applyMe((await api.chooseFaction(faction)).me);
        if (alive) onDone();
      } catch (e) { if (alive) setErr(errorMessage(e)); }
    })();
    return () => { alive = false; };
  }, [attempt]);
  return (
    <div class={'ob-screen ob-commit ' + faction}>
      <div class="ob-card">
        {err ? (
          <>
            <p class="ob-hint bad" role="alert">{err}</p>
            <button class="btn primary block" onClick={() => { setErr(null); setAttempt(attempt + 1); }}>{say('Try again', 'again')}</button>
          </>
        ) : <p class="ob-status" role="status">{say('Making it permanent…', 'it is done…')}</p>}
      </div>
    </div>
  );
}
