import { App } from '@capacitor/app';
import { StatusBar, Style } from '@capacitor/status-bar';
import { SplashScreen } from '@capacitor/splash-screen';
import { effect } from '@preact/signals';
import { phase } from '../state/store';
import { handleBack } from '../ui/back';
import { scheduleDailyReset, watchDowned } from './notify';
import { isNative } from './platform';
import { refreshPatrol } from './patrol';
import { reportPluginError } from '../report/errors';

const quiet = (p: Promise<unknown>, call: string) => { void p.catch((e) => reportPluginError(call, e)); };

/** Wire the native shell: status bar, splash, back button, resume. A no-op in the browser. */
export function initNative() {
  if (!isNative) return;

  quiet(StatusBar.setOverlaysWebView({ overlay: true }), 'StatusBar.setOverlaysWebView');
  quiet(StatusBar.setStyle({ style: Style.Dark }), 'StatusBar.setStyle');

  // The splash is held until the first real screen, with a failsafe.
  let hidden = false;
  const hide = () => { if (!hidden) { hidden = true; quiet(SplashScreen.hide({ fadeOutDuration: 200 }), 'SplashScreen.hide'); } };
  effect(() => { if (phase.value !== 'boot') hide(); });
  setTimeout(hide, 6000);

  void App.addListener('backButton', () => {
    if (!handleBack()) quiet(App.minimizeApp(), 'App.minimizeApp');
  });

  watchDowned();
  void scheduleDailyReset();
  void App.addListener('resume', () => { void scheduleDailyReset(); void refreshPatrol(); });
}
