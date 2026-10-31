import { useEffect, useState } from 'preact/hooks';
import { catalog, faction, me, reducedMotion } from '../state/store';
import { clunk } from '../audio/fx';
import { Icon, type IconName } from '../ui/Icon';
import { say } from '../ui/voice';
import { itemTitle } from '../gear/util';
import type { Slot } from '../api';

const SLOT_ICON: Record<Slot, IconName> = { weapon: 'baseball-bat', armor: 'hoodie', utility: 'flashlight' };
const SLOT_NAME: Record<Slot, [string, string]> = { weapon: ['Weapon', 'Claws'], armor: ['Armor', 'Hide'], utility: ['Gear', 'Strain'] };

/** The starter kit, handed over one item at a time. */
export function Kit({ onDone }: { onDone: () => void }) {
  const m = me.value;
  const f = faction.value ?? 'human';
  const entries: { key: string; icon: IconName; name: string; tag: string; rarity: string; note: string }[] = [];
  for (const it of m?.items ?? []) {
    entries.push({ key: it.uid, icon: SLOT_ICON[it.slot], name: itemTitle(it), tag: SLOT_NAME[it.slot][f === 'zombie' ? 1 : 0], rarity: it.rarity, note: `ATK ${it.stats.atk} · DEF ${it.stats.def} · SPD ${it.stats.spd}` });
  }
  for (const [id, n] of Object.entries(m?.consumables ?? {})) {
    const nm = catalog.value?.consumables.find((c) => c.id === id)?.names[f] ?? id;
    entries.push({ key: id, icon: f === 'human' ? 'bandage-roll' : 'meat', name: `${nm} ×${n}`, tag: say('Heals', 'feeds'), rarity: 'common', note: catalog.value?.consumables.find((c) => c.id === id)?.text ?? '' });
  }
  const [n, setN] = useState(0);
  useEffect(() => {
    if (n >= entries.length) return;
    const t = setTimeout(() => { setN(n + 1); clunk(); }, reducedMotion.value ? 80 : n === 0 ? 700 : 950);
    return () => clearTimeout(t);
  }, [n, entries.length]);

  return (
    <div class="ob-screen kit">
      <div class="ob-card wide">
        <p class="eyebrow">{say('Issued kit', 'what you start with')}</p>
        <h1 class="ob-h display breathe">{say('Take what you can carry.', 'this is all you have.')}</h1>
        <div class="kit-list" aria-live="polite">
          {entries.slice(0, n).map((e) => (
            <div key={e.key} class={`card item-card kit-card rarity-${e.rarity}`}>
              <Icon name={e.icon} size={36} />
              <div>
                <strong>{e.name}</strong>
                <div class="rarity-label">{e.rarity}</div>
                <div class="dim num" style={{ fontSize: 'var(--fs-14)' }}>{e.tag}{e.note ? ` · ${e.note}` : ''}</div>
              </div>
            </div>
          ))}
        </div>
        {n >= entries.length && <button class="btn primary block" onClick={onDone} autoFocus>{say('Continue', 'continue')}</button>}
      </div>
    </div>
  );
}
