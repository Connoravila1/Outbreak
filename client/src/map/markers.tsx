import { render } from 'preact';
import { maplibregl } from './factory';
import type { Map as MlMap, Marker } from 'maplibre-gl';
import { Icon } from '../ui/Icon';
import type { WorldLandmark } from '../api';
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
    case 'landmark': {
      // Survey stamps the real name and the kind ("WALGREENS — PHARMACY"); Heat only senses the kind ("sick ward").
      const kind = o.detail ?? o.name;
      if (lens === 'heat') return kind.toLowerCase();
      return (o.name === kind ? kind : `${o.name} — ${kind}`).toUpperCase();
    }
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

/** A rubber-stamped municipal-map symbol: double rule, tilted a little, as if pressed by hand. */
function Stamp() {
  return (
    <svg class="mk-stamp" viewBox="0 0 56 56" aria-hidden="true">
      <rect class="stamp-o" x="8" y="8" width="40" height="40" rx="5" />
      <rect class="stamp-i" x="12.5" y="12.5" width="31" height="31" rx="3" />
    </svg>
  );
}

/** A warm smear: something that was fed from, a long time ago. */
function Smear() {
  return <span class="mk-smear" />;
}

function View({ o, c }: { o: GameObject; c: MarkerCtx }) {
  if (o.kind === 'landmark') {
    const heat = c.lens === 'heat';
    return (
      <>
        {heat ? <Smear /> : <Stamp />}
        <Icon name={o.icon} size={heat ? 22 : 20} class="mk-icon" />
        <span class={'mk-note ' + (heat ? 'voice' : 'hand')}>{note(o, c.lens)}</span>
      </>
    );
  }
  const threat: Threat | null = o.level != null && (o.kind === 'enemy' || o.kind === 'echo') ? threatOf(o.level, c.myLevel) : null;
  const heat = c.lens === 'heat';
  return (
    <>
      {heat ? <Bloom threat={threat ?? 'even'} elite={o.elite} /> : <Grease elite={o.elite} />}
      <Icon name={o.icon} size={26} class="mk-icon" />
      {o.tutorial && <span class="mk-first" />}
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
      const spent = o.kind === 'landmark' && !(o.raw as WorldLandmark).available;
      setClasses(e.el, `mk mk-${o.kind} mk-${c.lens} threat-${threat}${o.elite ? ' elite' : ''}${o.tutorial ? ' tutorial' : ''}${spent ? ' spent' : ''}${c.selectedId === o.id ? ' selected' : ''}`);
      e.el.setAttribute('aria-label', `${o.name}${o.level != null ? ', level ' + o.level : ''}`);
      e.m.setLngLat([o.lon, o.lat]);
      render(<View o={o} c={c} />, e.el);
    }
    for (const [id, e] of this.live) {
      if (!seen.has(id)) { render(null, e.el); e.m.remove(); this.live.delete(id); }
    }
  }

  /**
   * Hand labels get crowded. Hidden below zoom 16; otherwise placed greedily, nearest to `me` first,
   * and a label whose box overlaps one already placed is skipped (the icon stays). Landmark labels
   * go last, and they also give way to the body of any other marker, so a real place's name never
   * hides something the player can act on.
   */
  declutter(me: { lat: number; lon: number } | null, selectedId: string | null) {
    const zoom = this.map.getZoom();
    const notes: { el: HTMLElement; d: number; place: boolean }[] = [];
    const bodies: DOMRect[] = [];
    const origin = me ? this.map.project([me.lon, me.lat]) : null;
    for (const [id, e] of this.live) {
      const place = e.el.classList.contains('mk-landmark');
      if (!place) bodies.push(e.el.getBoundingClientRect());
      const el = e.el.querySelector<HTMLElement>('.mk-note');
      if (!el) continue;
      el.classList.remove('mk-note-off');
      if (zoom < 16) { el.classList.add('mk-note-off'); continue; }
      const p = this.map.project(e.m.getLngLat());
      const d = id === selectedId ? -1 : origin ? Math.hypot(p.x - origin.x, p.y - origin.y) : 0;
      notes.push({ el, d, place: place && d >= 0 }); // a selected place keeps its label
    }
    notes.sort((a, b) => Number(a.place) - Number(b.place) || a.d - b.d);
    const placed: DOMRect[] = [];
    const clash = (r: DOMRect, q: DOMRect, padX: number, padY: number) => r.left < q.right + padX && r.right > q.left - padX && r.top < q.bottom + padY && r.bottom > q.top - padY;
    for (const n of notes) {
      const r = n.el.getBoundingClientRect();
      const hit = placed.some((q) => clash(r, q, 2, 1)) || (n.place && bodies.some((q) => clash(r, q, 0, 0)));
      if (hit) n.el.classList.add('mk-note-off'); else placed.push(r);
    }
  }

  clear() { this.sync([], { lens: 'neutral', myLevel: 1, selectedId: null, onSelect: () => undefined }); }
}
