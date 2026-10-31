import type { Battle, Rewards } from '../api';
import { say } from '../ui/voice';
import { catalog } from '../state/store';
import { faction } from '../state/store';
import { Icon } from '../ui/Icon';

export function damageTaken(b: Battle): number {
  const last = b.turns[b.turns.length - 1];
  return Math.max(0, b.a.hp_start - (last ? last.hp_a : b.a.hp_start));
}

function consumableName(id: string): string {
  const f = faction.peek() ?? 'human';
  return catalog.value?.consumables.find((c) => c.id === id)?.names[f] ?? id.replace(/_/g, ' ');
}

export function RewardLines({ r }: { r: Rewards }) {
  const cons = Object.entries(r.consumables);
  return (
    <ul class="reward-lines">
      <li><Icon name="star-medal" size={18} /> +{r.xp} XP</li>
      {r.salvage > 0 && <li><Icon name="recycle" size={18} /> +{r.salvage} salvage</li>}
      {r.items.map((it) => (
        <li key={it.uid} class={'rarity-' + it.rarity}><Icon name="swap-bag" size={18} /> {itemName(it.base, it.slot)} <span class="rarity-label">{it.rarity}</span></li>
      ))}
      {cons.map(([id, n]) => <li key={id}><Icon name="medical-pack" size={18} /> {consumableName(id)} ×{n}</li>)}
      {r.level_up && <li class="lvl"><Icon name="laurels" size={18} /> {say(`Level ${r.level_up.to}.`, `level ${r.level_up.to}. stronger.`)}</li>}
    </ul>
  );
}

export function itemName(base: string, slot?: string): string {
  const f = faction.peek() ?? 'human';
  return catalog.value?.items.find((i) => i.id === base)?.names[f] ?? (slot ? `${base} (${slot})` : base);
}

/** Raw result summary. The fight playback screen replaces this later. */
export function BattleSummary({ b }: { b: Battle }) {
  const won = b.winner === 'a';
  const dmg = damageTaken(b);
  const line = won
    ? say(`You held. Took ${dmg} damage.`, `fed. ${dmg} wounds.`)
    : say(`You went down. Took ${dmg} damage.`, `torn open. ${dmg} wounds.`);
  return (
    <div class="battle-summary">
      <p class="display result">{won ? say('Victory', 'fed') : say('Defeat', 'torn')}</p>
      <p>{line}</p>
      <p class="dim">{b.b.name}, level {b.b.level} · {b.turns.length} blows</p>
      <RewardLines r={b.rewards} />
    </div>
  );
}
