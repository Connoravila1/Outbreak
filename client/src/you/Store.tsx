import { useState } from 'preact/hooks';
import { api, errorMessage } from '../api';
import { applyMe, catalog, faction, lens, me } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { Action, ErrorLine, pushToast, Section } from '../ui/kit';
import { showRewards } from '../ui/RewardsSheet';
import { enqueueLevelUp } from '../battle/session';
import { purchase } from '../audio/fx';
import { achievementsEarned } from '../collection/store';
import { FramedAvatar } from '../avatar/Frame';
import { colorHex } from '../ui/Callsign';
import { wear } from './Wardrobe';
import { Exchange } from '../events/Exchange';
import type { CatalogCosmetic } from '../api';
import '../collection/collection.css';

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
      if (r.rewards) { showRewards(name, r.rewards); enqueueLevelUp(r.rewards.level_up, r.me); achievementsEarned(r.rewards.achievements); }
      else pushToast(say(`Bought ${name}.`, `${name}. yours.`), 'good');
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  };
  return (
    <Section id="store" title={say('Store', 'trade')} aside={<span class="salv-line"><Icon name="recycle" size={14} /> {m.salvage} {say('salvage', 'salvage')}</span>}>
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
      <Looks buy={buy} pick={pick} setPick={setPick} busy={busy} />
      <Exchange />
      <ErrorLine text={err} />
    </Section>
  );
}

/** Callsign colours and avatar frames for sale. Owned ones offer to be worn. */
function Looks({ buy, pick, setPick, busy }: { buy: (sku: string, name: string) => void; pick: string | null; setPick: (s: string | null) => void; busy: boolean }) {
  const m = me.value!;
  const f = faction.value ?? 'human';
  const sale = (catalog.value?.cosmetics ?? []).filter((c) => c.price > 0);
  if (!sale.length) return null;
  const owned = new Set(m.cosmetics?.owned ?? []);
  const worn = (c: CatalogCosmetic) => (c.kind === 'color' ? m.cosmetics?.color : m.cosmetics?.frame) === c.id;
  return (
    <>
      <h4 class="cos-sub">{say('Looks', 'looks')}</h4>
      <ul class="store">
        {sale.map((c) => {
          const have = owned.has(c.id);
          const reason = m.level < STORE_LEVEL ? say(`The Store opens at level ${STORE_LEVEL}.`, `opens at level ${STORE_LEVEL}.`)
            : m.salvage < c.price ? say(`Need ${c.price - m.salvage} more salvage.`, `${c.price - m.salvage} more salvage.`) : null;
          return (
            <li class="card store-row cos-row" key={c.id}>
              {c.kind === 'color' ? (
                // The sample callsign is the description; a side column would squeeze the name to one word a line.
                <div class="st-main"><b>{c.names[f]}</b><span class="cos-sample" style={{ color: colorHex(c.id) }}>{m.callsign ?? 'Callsign'}</span></div>
              ) : (
                <>
                  <span class="cos-ico"><FramedAvatar frame={c.id} spec={m.avatar} faction={f} level={m.level} lens={lens.value} size={56} /></span>
                  <div class="st-main"><b>{c.names[f]}</b><span class="dim">{c.text}</span></div>
                </>
              )}
              {have ? (
                worn(c)
                  ? <span class="cos-owned">{say('Worn', 'worn')}</span>
                  : <button class="btn" onClick={() => { void wear(c.kind, c.id); }}>{say('Wear', 'wear')}</button>
              ) : pick === c.id ? (
                <div class="st-confirm">
                  <span class="st-ask">{say(`Spend ${c.price}?`, `pay ${c.price}?`)}</span>
                  <div class="confirm-row">
                    <button class="btn" onClick={() => setPick(null)}>{say('No', 'no')}</button>
                    <button class="btn primary" disabled={busy} onClick={() => buy(c.id, c.names[f])}>{busy ? '…' : say('Buy', 'Buy')}</button>
                  </div>
                </div>
              ) : (
                <Action id={'why-' + c.id} reason={reason} onClick={() => setPick(c.id)}>
                  Buy<span class="cost num"><Icon name="recycle" size={16} />{c.price}</span>
                </Action>
              )}
            </li>
          );
        })}
      </ul>
    </>
  );
}
