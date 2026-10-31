import { useState } from 'preact/hooks';
import { api, errorMessage } from '../api';
import { applyMe, catalog, faction, me } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { Action, ErrorLine, pushToast, Section } from '../ui/kit';
import { showRewards } from '../ui/RewardsSheet';
import { enqueueLevelUp } from '../battle/session';
import { purchase } from '../audio/fx';

const STORE_LEVEL = 2;

export function Store() {
  const m = me.value;
  const items = catalog.value?.store ?? [];
  const [pick, setPick] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  if (!m) return null;
  const buy = async (sku: string, name: string) => {
    setBusy(true); setErr(null);
    try {
      const r = await api.buy(sku);
      applyMe(r.me);
      purchase();
      setPick(null);
      if (r.rewards) { showRewards(name, r.rewards); enqueueLevelUp(r.rewards.level_up, r.me); }
      else pushToast(say(`Bought ${name}.`, `${name}. yours.`), 'good');
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  };
  return (
    <Section title={say('Store', 'trade')} aside={<span class="salv-line"><Icon name="recycle" size={14} /> {m.salvage} {say('salvage', 'salvage')}</span>}>
      {items.length === 0 && <p class="empty">{say('Nothing for sale.', 'nothing to trade.')}</p>}
      <ul class="store">
        {items.map((raw) => {
          const cons = catalog.value?.consumables.find((c) => c.id === raw.sku);
          // Consumables go by the name your side knows them by; the rest keep the store's own wording.
          const s = {
            ...raw,
            ...(cons ? { name: cons.names[faction.value ?? 'human'], ...(raw.sku === 'flag' ? {} : { text: cons.text }) } : {}),
            ...(raw.sku === 'inventory' && m.expansion_price ? { price: m.expansion_price } : {}),
          };
          const reason = m.level < STORE_LEVEL ? say(`The Store opens at level ${STORE_LEVEL}.`, `opens at level ${STORE_LEVEL}.`)
            : s.sku === 'flag' && m.level < 15 ? say('Flags unlock at level 15.', 'level 15 first.')
            : s.sku === 'flag' && !m.clan ? say('Join a clan to buy a flag.', 'join a clan first.')
            : s.sku === 'requisition' && m.items.length >= m.inventory_cap ? say('Your pack is full.', 'no room left.')
            : m.salvage < s.price ? say(`Need ${s.price - m.salvage} more salvage.`, `${s.price - m.salvage} more salvage.`) : null;
          return (
            <li class="card store-row" key={s.sku}>
              <div class="st-main"><b>{s.name}</b><span class="dim">{s.text}</span></div>
              {pick === s.sku ? (
                <div class="st-confirm">
                  <span class="st-ask">{say(`Spend ${s.price}?`, `pay ${s.price}?`)}</span>
                  <div class="confirm-row">
                    <button class="btn" onClick={() => setPick(null)}>{say('No', 'no')}</button>
                    <button class="btn primary" disabled={busy} onClick={() => buy(s.sku, s.name)}>{busy ? '…' : say('Buy', 'Buy')}</button>
                  </div>
                </div>
              ) : (
                <Action id={'why-' + s.sku} reason={reason} onClick={() => setPick(s.sku)}>
                  Buy<span class="cost num"><Icon name="recycle" size={16} />{s.price}</span>
                </Action>
              )}
            </li>
          );
        })}
      </ul>
      <ErrorLine text={err} />
    </Section>
  );
}
