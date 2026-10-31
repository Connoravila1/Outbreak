import { useState } from 'preact/hooks';
import { api, errorMessage } from '../api';
import { applyMe, catalog, me } from '../state/store';
import { Icon } from '../ui/Icon';
import { say } from '../ui/voice';
import { Action, ErrorLine, pushToast, Section } from '../ui/kit';
import { heal } from '../audio/fx';
import { consumableName } from './util';

function whyNot(id: string, hp: number, max: number, downed: boolean): string | null {
  if (id === 'flag') return say('Used at a Stronghold on the map.', 'used on held ground.');
  if (/^heal_/.test(id) && downed) return say('You are down. Only a revive gets you up.', 'down. only a revive lifts you.');
  if (/^heal_/.test(id) && hp >= max) return say('Full health.', 'nothing to mend.');
  if (id === 'revive' && !downed && hp >= max) return say('Full health.', 'nothing to mend.');
  return null;
}

export function Consumables() {
  const m = me.value;
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  if (!m) return null;
  const rows = Object.entries(m.consumables).filter(([, n]) => n > 0);
  const downed = !!m.downed_until && m.downed_until > Date.now();
  const use = async (id: string) => {
    setBusy(id); setErr(null);
    try {
      const r = await api.use(id);
      applyMe(r.me);
      heal();
      pushToast(say(`Used ${consumableName(id)}.`, `${consumableName(id)}. consumed.`), 'good');
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(null); }
  };
  return (
    <Section title={say('Consumables', 'to consume')}>
      {rows.length === 0 ? <p class="empty">{say('None. Fights and caches drop them.', 'none. feed.')}</p> : (
        <ul class="cons-list">
          {rows.map(([id, n]) => (
            <li class="card cons" key={id}>
              <Icon name="medical-pack" size={26} />
              <div class="cons-text">
                <b>{consumableName(id)} <span class="num">×{n}</span></b>
                <span class="dim">{catalog.value?.consumables.find((c) => c.id === id)?.text ?? ''}</span>
              </div>
              <Action id={'why-' + id} busy={busy === id} reason={whyNot(id, m.hp, m.max_hp, downed)} onClick={() => use(id)}>Use</Action>
            </li>
          ))}
        </ul>
      )}
      <ErrorLine text={err} />
    </Section>
  );
}
