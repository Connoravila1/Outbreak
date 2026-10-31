import type { Rewards } from '../api';
import { say } from './voice';
import { Icon } from './Icon';
import { consumableName, itemTitle } from '../gear/util';

/** A plain list of what a Rewards bundle contains. */
export function RewardLines({ r }: { r: Rewards }) {
  const cons = Object.entries(r.consumables);
  return (
    <ul class="reward-lines">
      {r.xp > 0 && <li><Icon name="star-medal" size={18} /> +{r.xp} XP</li>}
      {r.salvage > 0 && <li><Icon name="recycle" size={18} /> +{r.salvage} salvage</li>}
      {r.war_points > 0 && <li><Icon name="crossed-swords" size={18} /> +{r.war_points} war points</li>}
      {r.items.map((it) => (
        <li key={it.uid} class={'rarity-' + it.rarity}><Icon name="swap-bag" size={18} /> {itemTitle(it)} <span class="rarity-label">{it.rarity}</span></li>
      ))}
      {cons.map(([id, n]) => <li key={id}><Icon name="medical-pack" size={18} /> {consumableName(id)} ×{n}</li>)}
      {r.level_up && <li class="lvl"><Icon name="laurels" size={18} /> {say(`Level ${r.level_up.to}.`, `level ${r.level_up.to}. stronger.`)}</li>}
    </ul>
  );
}

export function rewardsEmpty(r: Rewards): boolean {
  return !r.xp && !r.salvage && !r.war_points && !r.items.length && !Object.keys(r.consumables).length;
}
