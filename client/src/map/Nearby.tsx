import { follow, selectedId } from './GameMap';
import { threatOf, THREAT_WORD, THREAT_WORD_HEAT } from './threat';
import { formatDistance, haversine, position } from '../location';
import type { LatLon } from '../location/geo';
import { faction, lens, me, world } from '../state/store';
import { capLandmarks, objectsFrom, INTERACT_RANGE_M, type GameObject } from '../state/objects';
import { Sheet } from '../ui/Sheet';
import { Icon } from '../ui/Icon';
import { say } from '../ui/voice';
import './nearby.css';

const POINTS = ['north', 'north-east', 'east', 'south-east', 'south', 'south-west', 'west', 'north-west'];

/** Compass point from `a` to `b` in words, for a list read aloud. */
export function bearingWord(a: LatLon, b: LatLon): string {
  const y = Math.sin(((b.lon - a.lon) * Math.PI) / 180) * Math.cos((b.lat * Math.PI) / 180);
  const x = Math.cos((a.lat * Math.PI) / 180) * Math.sin((b.lat * Math.PI) / 180)
    - Math.sin((a.lat * Math.PI) / 180) * Math.cos((b.lat * Math.PI) / 180) * Math.cos(((b.lon - a.lon) * Math.PI) / 180);
  const deg = ((Math.atan2(y, x) * 180) / Math.PI + 360) % 360;
  return POINTS[Math.round(deg / 45) % 8];
}

const GROUPS: { kinds: GameObject['kind'][]; survey: string; heat: string }[] = [
  { kinds: ['enemy', 'echo', 'raid'], survey: 'Threats', heat: 'warm things' },
  { kinds: ['cache', 'airdrop'], survey: 'Supplies', heat: 'food' },
  { kinds: ['landmark', 'stronghold'], survey: 'Places', heat: 'places' },
];

/** What the map is showing, as a list: the same objects, nearest first, each one opening the same sheet a marker does. */
export function nearbyObjects(): { o: GameObject; dist: number }[] {
  const w = world.value;
  const f = faction.value;
  const p = position.value;
  if (!w || !f) return [];
  const all = p ? capLandmarks(objectsFrom(w, f), p, selectedId.peek()) : objectsFrom(w, f);
  return all.map((o) => ({ o, dist: p ? haversine(p, o) : Infinity })).sort((a, b) => a.dist - b.dist);
}

function line(o: GameObject, dist: number, p: LatLon | null): string {
  const m = me.value;
  const heat = lens.value === 'heat';
  const parts: string[] = [o.name];
  if (o.level != null) parts.push(`${say('level', 'level')} ${o.level}`);
  if (o.elite) parts.push(say('elite', 'elite'));
  if (o.level != null && m && (o.kind === 'enemy' || o.kind === 'echo')) {
    const t = threatOf(o.level, m.level);
    parts.push((heat ? THREAT_WORD_HEAT : THREAT_WORD)[t]);
  }
  if (Number.isFinite(dist) && p) parts.push(`${formatDistance(dist)} ${bearingWord(p, o)}`);
  return parts.join(', ');
}

export function NearbyList({ onClose }: { onClose: () => void }) {
  const p = position.value;
  const rows = nearbyObjects();
  const open = (id: string) => { follow.value = false; selectedId.value = id; onClose(); };
  return (
    <Sheet title={say('Nearby', 'close by')} onClose={onClose}>
      <h2 class="display obj-title">{say('Nearby', 'close by')}</h2>
      <p class="dim nb-lede">{say('Everything on the map, nearest first. Choose one to open it, as if you tapped it.', 'all of it, nearest first. choose one, as if you touched it.')}</p>
      {rows.length === 0 && <p class="empty">{say('Nothing within 450 m. Walk a block and it changes every 10 minutes.', 'nothing warm within 450 m. walk. it shifts every 10 minutes.')}</p>}
      {GROUPS.map((g) => {
        const list = rows.filter((r) => g.kinds.includes(r.o.kind));
        if (!list.length) return null;
        return (
          <section key={g.survey} class="nb-group" aria-label={say(g.survey, g.heat)}>
            <h3 class="display nb-h">{say(g.survey, g.heat)} <span class="dim num">{list.length}</span></h3>
            <ul class="nb-list">
              {list.map(({ o, dist }) => (
                <li key={o.id}>
                  <button class={'nb-row' + (dist <= INTERACT_RANGE_M ? ' near' : '')} aria-label={`${line(o, dist, p)}${dist <= INTERACT_RANGE_M ? '. ' + say('In range', 'in reach') : ''}`} onClick={() => open(o.id)}>
                    <span aria-hidden="true"><Icon name={o.icon} size={26} /></span>
                    <span class="nb-text" aria-hidden="true">
                      <b>{o.name}{o.level != null ? ` · ${o.level}` : ''}</b>
                      <span class="dim">{o.kind === 'landmark' ? o.detail : o.kind === 'echo' ? `${say('Echo', 'echo')}${o.detail ? ` · ${o.detail}` : ''}` : o.kind === 'enemy' ? (o.note ?? '') : ''}</span>
                    </span>
                    <span class="nb-dist num" aria-hidden="true">{Number.isFinite(dist) ? formatDistance(dist) : ''}{p && Number.isFinite(dist) ? <small>{bearingWord(p, o)}</small> : null}</span>
                  </button>
                </li>
              ))}
            </ul>
          </section>
        );
      })}
    </Sheet>
  );
}
