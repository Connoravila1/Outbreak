import { useState } from 'preact/hooks';
import { api, errorMessage, type Slot } from '../api';
import { applyMe, me } from '../state/store';
import { Icon } from '../ui/Icon';
import { say } from '../ui/voice';
import { Action, ErrorLine, pushToast, Seg } from '../ui/kit';
import { ItemCard } from '../gear/ItemCard';
import { ItemSheet } from '../gear/ItemSheet';
import { Consumables } from '../gear/Consumables';
import { Abilities } from '../gear/Abilities';
import { isRarePlus, itemTitle, RARITY_ORDER, SLOTS, slotLabel } from '../gear/util';
import { clunk } from '../audio/fx';
import '../shell/shell.css';
import '../gear/gear.css';

type Filter = 'all' | Slot;
type Sort = 'power' | 'rarity';

export function GearTab() {
  const m = me.value;
  const [filter, setFilter] = useState<Filter>('all');
  const [sort, setSort] = useState<Sort>('power');
  const [open, setOpen] = useState<string | null>(null);
  const [scrapMode, setScrapMode] = useState(false);
  const [picked, setPicked] = useState<string[]>([]);
  const [confirm, setConfirm] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  if (!m) return null;

  const worn = new Set(Object.values(m.equipped).filter(Boolean));
  const spare = m.items
    .filter((i) => !worn.has(i.uid) && (filter === 'all' || i.slot === filter))
    .sort((a, b) => sort === 'power' ? b.power - a.power : RARITY_ORDER[b.rarity] - RARITY_ORDER[a.rarity] || b.power - a.power);
  const chosen = m.items.filter((i) => picked.includes(i.uid));
  const total = chosen.reduce((s, i) => s + i.scrap_value, 0);
  const risky = chosen.some((i) => isRarePlus(i.rarity));

  const endScrap = () => { setScrapMode(false); setPicked([]); setConfirm(false); setErr(null); };
  const doScrap = async () => {
    setBusy(true); setErr(null);
    try {
      const r = await api.scrap(picked);
      applyMe(r.me);
      clunk();
      pushToast(say(`Scrapped ${picked.length}. +${r.salvage_gained} salvage.`, `torn down. +${r.salvage_gained} salvage.`), 'good');
      endScrap();
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  };
  const tap = (uid: string) => {
    if (!scrapMode) { setOpen(uid); return; }
    setConfirm(false);
    setPicked((p) => (p.includes(uid) ? p.filter((x) => x !== uid) : [...p, uid]));
  };

  return (
    <div class="panel scroll gear">
      <div class="gear-head">
        <h2 class="display">{say('Gear', 'what you carry')}</h2>
        <span class="chip salv" title="Salvage"><Icon name="recycle" size={16} /><b class="num">{m.salvage}</b> {say('salvage', 'salvage')}</span>
      </div>

      <div class="slot-row">
        {SLOTS.map((s) => {
          const it = m.items.find((i) => i.uid === m.equipped[s]);
          return it
            ? <ItemCard key={s} it={it} equipped onClick={() => setOpen(it.uid)} />
            : <div key={s} class="card slot-card"><small>{slotLabel(s)}</small><span class="dim">{say('Empty', 'nothing')}</span></div>;
        })}
      </div>

      <section class="sect">
        <h3 class="display sect-h"><span>{say('Inventory', 'carried')}</span><span class="dim num sect-aside">{m.items.length} / {m.inventory_cap}</span></h3>
        <div class="inv-tools">
          <Seg label="Filter by slot" value={filter} onChange={setFilter}
            options={[{ id: 'all', label: say('All', 'all') }, ...SLOTS.map((s) => ({ id: s as Filter, label: slotLabel(s) }))]} />
          <Seg label="Sort" value={sort} onChange={setSort} options={[{ id: 'power', label: say('Power', 'power') }, { id: 'rarity', label: say('Rarity', 'rarity') }]} />
          <button class="btn" aria-pressed={scrapMode} onClick={() => (scrapMode ? endScrap() : setScrapMode(true))}>
            <Icon name={scrapMode ? 'cancel' : 'recycle'} size={20} />{scrapMode ? say('Done', 'done') : 'Scrap'}
          </button>
        </div>
        {spare.length === 0
          ? <p class="empty">{m.items.length - worn.size === 0 ? say('Nothing spare. Open caches and win fights.', 'nothing spare. feed. take.') : say('Nothing in this slot.', 'nothing here.')}</p>
          : <div class="inv-grid">{spare.map((i) => <ItemCard key={i.uid} it={i} selectMode={scrapMode} selected={picked.includes(i.uid)} onClick={() => tap(i.uid)} />)}</div>}
      </section>

      {scrapMode && (
        <div class="scrap-bar" role="region" aria-label="Scrap selection">
          {confirm ? (
            <>
              <p>{say(`Scrap ${chosen.length} including ${chosen.filter((i) => isRarePlus(i.rarity)).map(itemTitle).join(', ')}? This cannot be undone.`, `tear down ${chosen.length}, rare ones too? no going back.`)}</p>
              <div class="confirm-row">
                <button class="btn" onClick={() => setConfirm(false)}>{say('Back', 'back')}</button>
                <button class="btn danger" disabled={busy} onClick={doScrap}>{busy ? '…' : say('Scrap them', 'Scrap')}</button>
              </div>
            </>
          ) : (
            <Action id="why-multi" primary block busy={busy} reason={chosen.length === 0 ? say('Tap items to select them.', 'choose what to tear down.') : null}
              onClick={() => (risky ? setConfirm(true) : doScrap())}>
              Scrap {chosen.length}<span class="cost num"><Icon name="recycle" size={16} />+{total}</span>
            </Action>
          )}
          <ErrorLine text={err} />
        </div>
      )}

      <Consumables />
      <Abilities />
      {open && <ItemSheet key={open} uid={open} onClose={() => setOpen(null)} />}
    </div>
  );
}
