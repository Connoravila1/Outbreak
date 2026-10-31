import { KEYS, storage } from '../api/storage';
import { Emitter, type LocationSource } from './source';
import { offset, haversine, type LatLon } from './geo';

export const WALK_SPEED = 1.4; // m/s
export const RUN_SPEED = 5; // m/s (shift)

export const PRESETS: { name: string; at: LatLon }[] = [
  { name: 'Seattle', at: { lat: 47.6097, lon: -122.3331 } },
  { name: 'New York', at: { lat: 40.7411, lon: -73.9897 } },
  { name: 'London', at: { lat: 51.5136, lon: -0.1365 } },
  { name: 'Chicago', at: { lat: 41.8826, lon: -87.6226 } },
  { name: 'Suburb', at: { lat: 44.9537, lon: -93.0900 } },
];

const MOVE_KEYS: Record<string, [number, number]> = {
  w: [1, 0], arrowup: [1, 0],
  s: [-1, 0], arrowdown: [-1, 0],
  a: [0, -1], arrowleft: [0, -1],
  d: [0, 1], arrowright: [0, 1],
};

/** Desktop GPS simulator: keyboard walking, walk-to targets, teleport. */
export class SimSource extends Emitter implements LocationSource {
  readonly kind = 'sim' as const;
  pos: LatLon;
  target: LatLon | null = null;
  private keys = new Set<string>();
  private shift = false;
  private timer: number | null = null;
  private lastT = 0;
  private lastPersist = 0;
  /** UI hook: notified on every position/target change (drives the panel and map). */
  onChange: (() => void) | null = null;
  speed = 0;

  constructor() {
    super();
    this.pos = storage.getJSON<LatLon>(KEYS.simPos, PRESETS[0].at);
  }

  start() {
    if (this.timer != null) return;
    window.addEventListener('keydown', this.down);
    window.addEventListener('keyup', this.up);
    window.addEventListener('blur', this.clearKeys);
    this.lastT = performance.now();
    this.timer = window.setInterval(() => this.tick(), 100);
    this.publish();
  }

  stop() {
    if (this.timer == null) return;
    window.clearInterval(this.timer);
    this.timer = null;
    window.removeEventListener('keydown', this.down);
    window.removeEventListener('keyup', this.up);
    window.removeEventListener('blur', this.clearKeys);
    this.clearKeys();
  }

  teleport(p: LatLon) {
    this.pos = { ...p };
    this.target = null;
    this.speed = 0;
    this.publish(true);
  }

  walkTo(p: LatLon) {
    this.target = { ...p };
    this.onChange?.();
  }

  private clearKeys = () => { this.keys.clear(); this.shift = false; };

  private typing(e: KeyboardEvent) {
    const t = e.target as HTMLElement | null;
    return !!t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable);
  }

  private down = (e: KeyboardEvent) => {
    if (this.typing(e) || e.metaKey || e.ctrlKey || e.altKey) return;
    this.shift = e.shiftKey;
    const k = e.key.toLowerCase();
    if (k in MOVE_KEYS) {
      this.keys.add(k);
      this.target = null;
      e.preventDefault();
    }
  };
  private up = (e: KeyboardEvent) => {
    this.shift = e.shiftKey;
    this.keys.delete(e.key.toLowerCase());
  };

  private tick() {
    const now = performance.now();
    const dt = Math.min(0.5, (now - this.lastT) / 1000);
    this.lastT = now;
    const v = this.shift ? RUN_SPEED : WALK_SPEED;
    let n = 0, e = 0;
    this.keys.forEach((k) => { n += MOVE_KEYS[k][0]; e += MOVE_KEYS[k][1]; });
    let moved = false;
    if (n || e) {
      const len = Math.hypot(n, e);
      this.pos = offset(this.pos, (n / len) * v * dt, (e / len) * v * dt);
      this.speed = v;
      moved = true;
    } else if (this.target) {
      const d = haversine(this.pos, this.target);
      const step = v * dt;
      if (d <= step) {
        this.pos = this.target;
        this.target = null;
      } else {
        const f = step / d;
        this.pos = {
          lat: this.pos.lat + (this.target.lat - this.pos.lat) * f,
          lon: this.pos.lon + (this.target.lon - this.pos.lon) * f,
        };
      }
      this.speed = v;
      moved = true;
    } else {
      this.speed = 0;
    }
    if (moved) this.publish();
    else if (now - this.lastPersist > 2000) this.publish();
  }

  private publish(persist = false) {
    const now = performance.now();
    if (persist || now - this.lastPersist > 1000) {
      storage.setJSON(KEYS.simPos, this.pos);
      this.lastPersist = now;
    }
    this.emit({ ...this.pos, acc: 5, t: Date.now() });
    this.onChange?.();
  }
}
