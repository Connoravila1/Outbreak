import type { Item } from '../api';
import { Icon } from '../ui/Icon';
import { say } from '../ui/voice';
import { me } from '../state/store';
import { itemTitle, SLOT_ICON, statLine } from './util';

interface Props {
  it: Item;
  equipped?: boolean;
  selected?: boolean;
  selectMode?: boolean;
  onClick: () => void;
}

/** A tappable item tile. Rarity is a label and a border treatment, never colour alone. */
export function ItemCard({ it, equipped, selected, selectMode, onClick }: Props) {
  const tooLow = (me.value?.level ?? 1) < it.req;
  return (
    <button
      class={`card item-card inv-item rarity-${it.rarity}${selected ? ' selected' : ''}`}
      onClick={onClick}
      aria-pressed={selectMode ? !!selected : undefined}
      aria-label={`${itemTitle(it)}${it.upgrade ? ` plus ${it.upgrade}` : ''}, ${it.rarity}`}
    >
      <span class="ic-top">
        <Icon name={SLOT_ICON[it.slot]} size={26} />
        {selectMode && <span class={'tick' + (selected ? ' on' : '')} aria-hidden="true">{selected ? '✓' : ''}</span>}
        {equipped && <span class="label-tape">{say('Equipped', 'worn')}</span>}
      </span>
      <strong class="ic-name">{itemTitle(it)}{it.upgrade ? ` +${it.upgrade}` : ''}</strong>
      <span class="rarity-label">{it.rarity}</span>
      <span class="dim num ic-stats">{statLine(it.stats)}</span>
      {tooLow && <span class="ic-req">{say(`Needs level ${it.req}`, `level ${it.req} first`)}</span>}
    </button>
  );
}
