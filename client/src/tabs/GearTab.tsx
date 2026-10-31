import { catalog, faction, me } from '../state/store';
import { Icon, type IconName } from '../ui/Icon';
import { say } from '../ui/voice';
import { itemName } from '../shell/Battle';
import type { Item, Slot } from '../api';
import '../shell/shell.css';

const SLOT_NAME: Record<Slot, [string, string]> = {
  weapon: ['Weapon', 'Claws'],
  armor: ['Armor', 'Hide'],
  utility: ['Gear', 'Strain'],
};
const SLOT_ICON: Record<Slot, IconName> = { weapon: 'baseball-bat', armor: 'hoodie', utility: 'flashlight' };

export function slotLabel(s: Slot): string { return SLOT_NAME[s][faction.value === 'zombie' ? 1 : 0]; }

function statLine(it: Item): string {
  const s = it.stats;
  return [s.atk && `ATK ${s.atk}`, s.def && `DEF ${s.def}`, s.spd && `SPD ${s.spd}`, s.hp && `HP ${s.hp}`].filter(Boolean).join(' · ');
}

function ItemCard({ it, equipped }: { it: Item; equipped?: boolean }) {
  return (
    <div class={`card item-card inv-item rarity-${it.rarity}`}>
      <Icon name={SLOT_ICON[it.slot]} size={28} />
      <strong>{itemName(it.base, it.slot)}{it.upgrade ? ` +${it.upgrade}` : ''}</strong>
      <span class="rarity-label">{it.rarity}</span>
      <span class="dim num">{statLine(it)}</span>
      {equipped && <span class="label-tape">{say('Equipped', 'worn')}</span>}
    </div>
  );
}

/** Placeholder: shows real data from /api/me. The full Gear screen comes later. */
export function GearTab() {
  const m = me.value;
  if (!m) return null;
  void catalog.value;
  const eq = new Set(Object.values(m.equipped).filter(Boolean));
  const cons = Object.entries(m.consumables).filter(([, n]) => n > 0);
  return (
    <div class="panel scroll">
      <h2 class="display">{say('Gear', 'what you carry')}</h2>
      <div class="slot-row">
        {(['weapon', 'armor', 'utility'] as Slot[]).map((s) => {
          const it = m.items.find((i) => i.uid === m.equipped[s]);
          return it ? <ItemCard key={s} it={it} equipped /> : (
            <div key={s} class="card slot-card"><small>{slotLabel(s)}</small><span class="dim">{say('Empty', 'nothing')}</span></div>
          );
        })}
      </div>
      <h3 class="display">{say('Inventory', 'carried')} <span class="dim num">{m.items.length} / {m.inventory_cap}</span></h3>
      {m.items.filter((i) => !eq.has(i.uid)).length === 0
        ? <p class="empty">{say('Nothing spare. Open caches and win fights.', 'nothing spare. feed. take.')}</p>
        : <div class="inv-grid">{m.items.filter((i) => !eq.has(i.uid)).map((i) => <ItemCard key={i.uid} it={i} />)}</div>}
      <h3 class="display">{say('Consumables', 'to consume')}</h3>
      {cons.length === 0 ? <p class="empty">{say('None.', 'none.')}</p> : (
        <div>{cons.map(([id, n]) => (
          <div class="kv" key={id}><span>{catalog.value?.consumables.find((c) => c.id === id)?.names[faction.value ?? 'human'] ?? id}</span><b class="num">×{n}</b></div>
        ))}</div>
      )}
      <p class="settings-note">{say('Equip, upgrade and scrap arrive in the next pass.', 'more of this soon.')}</p>
    </div>
  );
}
