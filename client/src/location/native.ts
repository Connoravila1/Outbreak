import { Geolocation, type Position } from '@capacitor/geolocation';
import { Emitter, type LocationSource } from './source';
import { reportPluginError } from '../report/errors';

export type PermissionResult = 'granted' | 'denied';

/** Ask for While-In-Use location. Safe to call repeatedly; resolves once the user has answered. */
export async function requestNativeLocationPermission(): Promise<PermissionResult> {
  try {
    let st = await Geolocation.checkPermissions();
    if (st.location === 'granted' || st.coarseLocation === 'granted') return 'granted';
    st = await Geolocation.requestPermissions({ permissions: ['location'] });
    return st.location === 'granted' || st.coarseLocation === 'granted' ? 'granted' : 'denied';
  } catch {
    return 'denied';
  }
}

const toFix = (p: Position) => ({ lat: p.coords.latitude, lon: p.coords.longitude, acc: p.coords.accuracy, t: p.timestamp });

/** Capacitor Geolocation watch (FusedLocation on Android, CoreLocation on iOS). */
export class NativeSource extends Emitter implements LocationSource {
  readonly kind = 'real' as const;
  private watch: string | null = null;
  private starting = false;

  start() {
    if (this.watch != null || this.starting) return;
    this.starting = true;
    void Geolocation.watchPosition(
      // Android: one fix per 10 s at most (the plugin would otherwise reuse `timeout`, 20 s); iOS ignores both.
      { enableHighAccuracy: true, maximumAge: 2000, timeout: 20000, interval: 10000, minimumUpdateInterval: 5000 },
      (pos, err) => {
        if (pos) this.emit(toFix(pos));
        else if (err) {
          const denied = /denied|permission/i.test(String(err.message));
          if (!denied) reportPluginError('Geolocation.watchPosition', err);
          this.fail(denied ? 'Location permission was denied.' : 'Cannot get a location fix.');
        }
      },
    ).then((id) => { this.watch = id; this.starting = false; })
      .catch((e) => { this.starting = false; reportPluginError('Geolocation.watchPosition', e); this.fail('Cannot get a location fix.'); });
  }

  stop() {
    const id = this.watch;
    this.watch = null;
    if (id != null) void Geolocation.clearWatch({ id }).catch(() => undefined);
  }
}

export async function getOnceNative(timeout: number): Promise<{ lat: number; lon: number; acc: number }> {
  const p = await Geolocation.getCurrentPosition({ enableHighAccuracy: true, timeout, maximumAge: 10000 });
  return { lat: p.coords.latitude, lon: p.coords.longitude, acc: p.coords.accuracy };
}
