import type { Rewards } from '../api';
import { say } from './voice';
import { Icon } from './Icon';
import { consumableName, itemTitle } from '../gear/util';
import { NoteScrap } from '../notes/Scrap';

/** A plain list of what a Rewards bundle contains. */
export function RewardLines({ r }: { r: Rewards }) {
  const cons = Object.entries(r.consumables);
  return (
    <ul class="reward-lines">
      {r.xp > 0 && <li><Icon name="star-medal" size={18} /> +{r.xp} XP</li>}
      {r.salvage > 0 && <li><Icon name="recycle" size={18} /> +{r.salvage} salvage</li>}
      {r.war_points > 0 && <li><Icon name="crossed-swords" size={18} /> +{r.war_points} war {r.war_points === 1 ? 'point' : 'points'}</li>}
      {r.items.map((it) => (
        <li key={it.uid} class={'rarity-' + it.rarity}><Icon name="swap-bag" size={18} /> {itemTitle(it)} <span class="rarity-label">{it.rarity}</span></li>
      ))}
      {cons.map(([id, n]) => <li key={id}><Icon name="medical-pack" size={18} /> {consumableName(id)} ×{n}</li>)}
      {!!r.auto_scrapped && <li class="dim"><Icon name="recycle" size={18} /> {say(`Pack full: extra gear scrapped for ${r.auto_scrapped} salvage.`, `no room. the extra was torn down for ${r.auto_scrapped} salvage.`)}</li>}
      {(r.unlocks ?? []).map((u) => <li key={u.kind + u.id}><Icon name={u.kind === 'title' ? 'laurels' : 'star-medal'} size={18} /> {u.kind === 'title' ? say('Title', 'title') : u.kind === 'color' ? say('Callsign colour', 'callsign colour') : say('Portrait frame', 'portrait frame')}: <b>{u.name}</b></li>)}
      {(r.notes ?? []).map((nt) => <li key={nt.id} class="scrap-li"><NoteScrap r={nt} /></li>)}
      {r.level_up && <li class="lvl"><Icon name="laurels" size={18} /> {say(`Level ${r.level_up.to}.`, `level ${r.level_up.to}. stronger.`)}</li>}
    </ul>
  );
}

export function rewardsEmpty(r: Rewards): boolean {
  return !r.xp && !r.salvage && !r.auto_scrapped && !r.war_points && !r.items.length && !Object.keys(r.consumables).length && !r.notes?.length && !r.unlocks?.length;
}
