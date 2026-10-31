import type { FoundCosmetic as Find } from '../api';
import { catalog, faction, lens, me } from '../state/store';
import { FramedAvatar } from '../avatar/Frame';
import { Callsign } from './Callsign';
import { Icon } from './Icon';
import { say } from './voice';
import './found.css';

/** A cosmetic that dropped: a moment of its own in the reveal. A repeat is shown for what it became. */
export function FoundCosmetic({ find }: { find: Find }) {
  const f = faction.value ?? 'human';
  const m = me.value;
  const c = catalog.value?.cosmetics?.find((x) => x.id === find.id);
  const name = c?.names[f] ?? find.id.replace(/_/g, ' ');
  return (
    <div class={'found' + (find.duplicate ? ' dup' : '')} role="group" aria-label={`${say('Found in the field', 'dug up')}: ${name}`}>
      <p class="found-eyebrow"><Icon name="treasure-map" size={16} /> {find.duplicate ? say('Found again', 'dug up again') : say('Found in the field', 'dug up')}</p>
      <div class="found-art">
        {find.kind === 'frame'
          ? <FramedAvatar frame={find.id} spec={m?.avatar} faction={f} level={m?.level ?? 1} lens={lens.value} size={104} />
          : <span class="found-name display"><Callsign name={m?.callsign ?? name} color={find.id} /></span>}
      </div>
      <strong class="found-title display">{name}</strong>
      {c && <span class="dim found-text">{c.text.replace(/ Found in the field\.$/, '')}</span>}
      {find.duplicate
        ? <span class="found-dup"><Icon name="recycle" size={16} /> {say(`You already had it. +${find.salvage} salvage instead.`, `already yours. +${find.salvage} salvage.`)}</span>
        : <span class="found-new">{say('Yours now. Wear it from the You tab.', 'yours. wear it from the you tab.')}</span>}
    </div>
  );
}
