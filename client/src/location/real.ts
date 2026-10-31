import { Emitter, type LocationSource } from './source';

export class RealSource extends Emitter implements LocationSource {
  readonly kind = 'real' as const;
  private watch: number | null = null;

  start() {
    if (this.watch != null) return;
    if (!('geolocation' in navigator)) { this.fail('This device has no location support.'); return; }
    this.watch = navigator.geolocation.watchPosition(
      (p) => this.emit({ lat: p.coords.latitude, lon: p.coords.longitude, acc: p.coords.accuracy, t: p.timestamp }),
      (e) => this.fail(e.code === e.PERMISSION_DENIED ? 'Location permission was denied.' : 'Cannot get a location fix.'),
      { enableHighAccuracy: true, maximumAge: 2000, timeout: 20000 },
    );
  }

  stop() {
    if (this.watch != null) navigator.geolocation.clearWatch(this.watch);
    this.watch = null;
  }
}

/** One-shot fix, used by onboarding to centre the split lens and by the simulator panel. */
export function getOnce(timeout = 12000): Promise<{ lat: number; lon: number; acc: number }> {
  return new Promise((resolve, reject) => {
    if (!('geolocation' in navigator)) { reject(new Error('no geolocation')); return; }
    navigator.geolocation.getCurrentPosition(
      (p) => resolve({ lat: p.coords.latitude, lon: p.coords.longitude, acc: p.coords.accuracy }),
      (e) => reject(new Error(e.message || 'denied')),
      { enableHighAccuracy: true, timeout, maximumAge: 10000 },
    );
  });
}
