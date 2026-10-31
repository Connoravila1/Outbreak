// Whether the app is in the foreground. The WebView keeps running JS and CSS animations after the
// user leaves on Android, so polling, GPS and ambient animation key off this instead of assuming the
// browser throttles them. Patrol (native service) is unaffected: it does not use any of this.
import { signal, effect } from '@preact/signals';
import { App } from '@capacitor/app';
import { isNative } from './platform';

export const appActive = signal(!document.hidden);

const set = (v: boolean) => { if (appActive.peek() !== v) appActive.value = v; };

document.addEventListener('visibilitychange', () => set(!document.hidden));
if (isNative) void App.addListener('appStateChange', (s) => set(s.isActive && !document.hidden));

// CSS pauses every animation while the app is away (see styles/base.css).
effect(() => { document.documentElement.dataset.active = appActive.value ? 'true' : 'false'; });
