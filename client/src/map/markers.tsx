import { render } from 'preact';
import { maplibregl } from './factory';
import type { Map as MlMap, Marker } from 'maplibre-gl';
import { Icon } from '../ui/Icon';
import type { GameObject } from '../state/objects';
import { threatOf, type Threat } from './threat';
import type { Lens } from '../state/store';
import './markers.css';

export interface MarkerCtx {
  lens: Lens;
  myLevel: number;
  selectedId: string | null;
  onSelect: (id: string) => void;
}

function note(o: GameObject, lens: Lens): string {
  const n = o.name.toLowerCase();
  let s: string;
  switch (o.kind) {
    case 'enemy': s = `${n} · ${o.level}${o.elite ? '!' : ''}`; break;
    case 'echo': s = `${n.split(' ')[0]} · ${o.level}`; break;
    case 'cache': s = n.replace('supply ', ''); break;
    case 'raid': s = `${n} !!`; break;
    default: s = n;
  }
  // legibility first: both lenses name the archetype and level (heat keeps its lowercase styling)
  return lens === 'heat' ? s.toLowerCase() : s;
}

/** A hand-drawn, slightly open loop: the grease-pencil circle. */
function Grease({ elite }: { elite: boolean }) {
  return (
    <svg class="mk-ring" viewBox="0 0 56 56" aria-hidden="true">
      {elite && <circle class="mk-elite-ring" cx="28" cy="28" r="26" />}
      <path class="grease" d="M9 30C6 15 21 5 35 8C49 11 53 29 47 41C41 52 20 53 11 43C8 39 8 33 10 28C13 20 21 14 31 13" />
    </svg>
  );
}

function Bloom({ threat, elite }: { threat: Threat; elite: boolean }) {
  return (
    <>
      <span class="mk-bloom" />
      {elite && <span class="mk-elite-halo" />}
      {threat === 'deadly' && <span class="mk-core" />}
    </>
  );
}

function View({ o, c }: { o: GameObject; c: MarkerCtx }) {
  const threat: Threat | null = o.level != null && (o.kind === 'enemy' || o.kind === 'echo') ? threatOf(o.level, c.myLevel) : null;
  const heat = c.lens === 'heat';
  return (
    <>
      {heat ? <Bloom threat={threat ?? 'even'} elite={o.elite} /> : <Grease elite={o.elite} />}
      <Icon name={o.icon} size={26} class="mk-icon" />
      <span class={'mk-note ' + (heat ? 'voice' : 'hand')}>{note(o, c.lens)}</span>
    </>
  );
}

/** Replace our classes but keep the ones MapLibre put on a marker element. */
export function setClasses(el: HTMLElement, cls: string) {
  const keep = [...el.classList].filter((c) => c.startsWith('maplibregl-'));
  el.className = [...keep, cls].join(' ');
}

/** Keeps a set of MapLibre HTML markers in step with the world. */
export class MarkerLayer {
  private map: MlMap;
  private live = new Map<string, { m: Marker; el: HTMLElement }>();
  constructor(map: MlMap) { this.map = map; }

  sync(objects: GameObject[], c: MarkerCtx) {
    const seen = new Set<string>();
    for (const o of objects) {
      seen.add(o.id);
      let e = this.live.get(o.id);
      if (!e) {
        const el = document.createElement('div');
        el.setAttribute('role', 'button');
        el.tabIndex = 0;
        const m = new maplibregl.Marker({ element: el, anchor: 'center' }).setLngLat([o.lon, o.lat]).addTo(this.map);
        e = { m, el };
        this.live.set(o.id, e);
        el.addEventListener('click', (ev) => { ev.stopPropagation(); c.onSelect(o.id); });
        el.addEventListener('keydown', (ev) => { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); c.onSelect(o.id); } });
      }
      e.el.dataset.id = o.id;
      const threat = o.level != null ? threatOf(o.level, c.myLevel) : 'even';
      setClasses(e.el, `mk mk-${o.kind} mk-${c.lens} threat-${threat}${o.elite ? ' elite' : ''}${c.selectedId === o.id ? ' selected' : ''}`);
      e.el.setAttribute('aria-label', `${o.name}${o.level != null ? ', level ' + o.level : ''}`);
      e.m.setLngLat([o.lon, o.lat]);
      render(<View o={o} c={c} />, e.el);
    }
    for (const [id, e] of this.live) {
      if (!seen.has(id)) { render(null, e.el); e.m.remove(); this.live.delete(id); }
    }
  }

  clear() { this.sync([], { lens: 'neutral', myLevel: 1, selectedId: null, onSelect: () => undefined }); }
}
