import { Haptics, ImpactStyle, NotificationType } from '@capacitor/haptics';
import { hapticsOn } from '../state/store';
import { isNative } from './platform';

const guard = (fn: () => void) => {
  if (!hapticsOn.peek()) return;
  try { fn(); } catch { /* unsupported */ }
};
const swallow = (p: Promise<unknown>) => { void p.catch(() => undefined); };

type Impact = 'light' | 'medium' | 'heavy';
const IMPACT: Record<Impact, ImpactStyle> = { light: ImpactStyle.Light, medium: ImpactStyle.Medium, heavy: ImpactStyle.Heavy };
const impact = (s: Impact) => swallow(Haptics.impact({ style: IMPACT[s] }));
const notify = (t: NotificationType) => swallow(Haptics.notification({ type: t }));

/** Web fallback and the generic path: a vibrate pattern, played as-is. */
function webVibrate(pattern: number | number[]) { navigator.vibrate?.(pattern); }

/** Generic pattern (ms on/off/on...). On native each "on" pulse becomes an impact of matching weight. */
export function vibrate(pattern: number | number[]) {
  guard(() => {
    if (!isNative) { webVibrate(pattern); return; }
    if (typeof pattern === 'number' && pattern >= 200) { swallow(Haptics.vibrate({ duration: pattern })); return; }
    const p = Array.isArray(pattern) ? pattern : [pattern];
    let t = 0;
    p.forEach((ms, i) => {
      if (i % 2 === 0) setTimeout(() => impact(ms < 25 ? 'light' : ms < 80 ? 'medium' : 'heavy'), t);
      t += ms;
    });
  });
}

/** A landed blow. */
export function hit() { guard(() => (isNative ? impact('medium') : webVibrate(12))); }
/** A critical. */
export function crit() {
  guard(() => {
    if (!isNative) { webVibrate([40, 30, 60]); return; }
    impact('heavy');
    setTimeout(() => impact('medium'), 90);
  });
}
/** CONTACT: another player is close. Strong and long. */
export function contact() {
  guard(() => {
    if (!isNative) { webVibrate([300, 100, 300, 100, 300, 100, 600]); return; }
    notify(NotificationType.Warning);
    [350, 700, 1050].forEach((t) => setTimeout(() => impact('heavy'), t));
  });
}
/** Level up, and other rewards worth celebrating. */
export function levelUp() {
  guard(() => {
    if (!isNative) { webVibrate([60, 40, 60, 40, 200]); return; }
    notify(NotificationType.Success);
    setTimeout(() => impact('heavy'), 250);
  });
}
