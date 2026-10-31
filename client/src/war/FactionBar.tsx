import { Icon } from '../ui/Icon';

/** Humans vs Zombies as one split bar with the numbers written out. Colour is never the only signal. */
export function FactionBar({ human, zombie, label }: { human: number; zombie: number; label: string }) {
  const total = human + zombie;
  const h = total > 0 ? (human / total) * 100 : 50;
  const lead = human === zombie ? 'tied' : human > zombie ? 'Humans lead' : 'Zombies lead';
  return (
    <div class="fbar-wrap">
      <div class="fbar" role="img" aria-label={`${label}: Humans ${human}, Zombies ${zombie}. ${lead}.`}>
        <span class="fb-h num" style={{ width: `${h}%` }}>{Math.round(h)}%</span>
        <span class="fb-z num" style={{ width: `${100 - h}%` }}>{Math.round(100 - h)}%</span>
        <i class="fb-mid" aria-hidden="true" />
      </div>
      <div class="fb-labels">
        <span class="fb-lab h"><Icon name="shield" size={16} /> Humans <b class="num">{human.toLocaleString()}</b></span>
        <span class="fb-lab z"><b class="num">{zombie.toLocaleString()}</b> Zombies <Icon name="biohazard" size={16} /></span>
      </div>
    </div>
  );
}
