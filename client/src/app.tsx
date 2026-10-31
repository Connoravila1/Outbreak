import { useEffect } from 'preact/hooks';
import { signal } from '@preact/signals';
import { GameMap } from './map/GameMap';
import { TopBar } from './shell/TopBar';
import { Vitals } from './shell/Vitals';
import { TabBar } from './shell/TabBar';
import { MapTab } from './tabs/MapTab';
import { boot, loadCatalog, phase, tab, lens, me } from './state/store';
import { isDesktop, startLocation } from './location';
import { startPolling, stopPolling } from './state/poll';
import { Toasts } from './ui/kit';
import { RewardsSheet } from './ui/RewardsSheet';
import { GuestNudge } from './you/GuestNudge';
import { api, setUnauthorizedHandler, setBannedHandler, setUpdateHandler, setToken } from './api';
import { Banned } from './shell/Banned';
import { UpdateRequired } from './shell/UpdateRequired';
import { ErrorBoundary } from './shell/ErrorBoundary';
import { SimulatedBanner } from './shell/SimulatedBanner';
import { checkMinClient, updateRequired } from './state/update';
import { setScreenProvider } from './report/errors';
import { ReportSheet } from './ui/ReportSheet';
import { banned } from './state/moderation';
import { Icon } from './ui/Icon';
import { ServerAddress } from './onboarding/ServerAddress';
import { isNative } from './native/platform';
import { PatrolSheet } from './patrol/PatrolSheet';
import { PatrolReport } from './patrol/PatrolReport';
import { GuideHost } from './guide/Guide';
import { SafetyStep, safetySeen } from './safety/Safety';
import { TermsSheet } from './safety/TermsSheet';
import { bootTip } from './safety/tips';
import { lazy } from './ui/lazy';
import './shell/shell.css';
import './onboarding/onboarding.css';

// Code that is not needed to draw the first map is split out and fetched on demand (or when idle).
const GearTab = lazy(() => import('./tabs/GearTab').then((m) => m.GearTab));
const TasksTab = lazy(() => import('./tabs/TasksTab').then((m) => m.TasksTab));
const WarTab = lazy(() => import('./tabs/WarTab').then((m) => m.WarTab));
const YouTab = lazy(() => import('./tabs/YouTab').then((m) => m.YouTab));
const Onboarding = lazy(() => import('./onboarding/Onboarding').then((m) => m.Onboarding));
const SimPanel = lazy(() => import('./location/SimPanel').then((m) => m.SimPanel));
const BattleHost = lazy(() => import('./battle/BattleHost').then((m) => m.BattleHost));
const NoteReader = lazy(() => import('./notes/Reader').then((m) => m.NoteReader));
const idle = (fn: () => void) => { const ric = (window as { requestIdleCallback?: (f: () => void, o?: object) => number }).requestIdleCallback; if (ric) ric.call(window, fn, { timeout: 4000 }); else window.setTimeout(fn, 2000); };

// Crash reports say where the player was: the tab, or the stage before the game.
setScreenProvider(() => (phase.value === 'app' ? tab.value : phase.value));

const bootError = signal<string | null>(null);
/** A phone that signed in to an existing account reads the safety notice once before its first map. */
const safetyRead = signal(false);
const desktop = signal(isDesktop());
if (typeof matchMedia === 'function' && !isNative) {
  matchMedia('(min-width: 900px) and (pointer: fine)').addEventListener('change', (e) => { desktop.value = e.matches; });
}

function Shell() {
  useEffect(() => {
    void loadCatalog();
    startLocation();
    startPolling();
    // Warm the split chunks once the map is up so the first fight or tab switch never waits on the network.
    idle(() => { for (const c of [BattleHost, GearTab, TasksTab, WarTab, YouTab, NoteReader]) void c.preload().catch(() => undefined); });
    return stopPolling;
  }, []);
  const t = tab.value;
  return (
    <div class="app">
      <div class={'viewport' + (t !== 'map' ? ' on-panel' : '')}>
        <GameMap />
        {t !== 'map' && (
          <div role="tabpanel" id={'panel-' + t} aria-labelledby={'tab-' + t}>
            {t === 'gear' && <GearTab />}
            {t === 'tasks' && <TasksTab />}
            {t === 'war' && <WarTab />}
            {t === 'you' && <YouTab />}
          </div>
        )}
        <TopBar />
        {t === 'map' && <MapTab />}
        {t === 'map' && <SimulatedBanner />}
      </div>
      <Vitals />
      <TabBar />
      <Toasts />
      <RewardsSheet />
      <BattleHost />
      <NoteReader />
      <ReportSheet />
      <GuestNudge />
      <PatrolSheet />
      <PatrolReport />
      <GuideHost />
      <TermsSheet />
    </div>
  );
}

function Boot() {
  const tip = bootTip();
  return (
    <div class="ob-screen" style={{ background: '#000' }}>
      {bootError.value ? (
        <div class="ob-card">
          <h1 class="ob-h">No signal.</h1>
          <p>{bootError.value}</p>
          <button class="btn primary block" onClick={() => { bootError.value = null; void start(); }}>Try again</button>
        </div>
      ) : (
        <>
          <Icon name="radar-sweep" size={48} class="spin" />
          {tip && <p class="boot-tip">{tip}</p>}
        </>
      )}
    </div>
  );
}

async function start() {
  // Ask first whether this client is still welcome; a 426 on any later request says the same.
  try { checkMinClient(await api.health()); } catch { /* offline or no server yet: boot reports it */ }
  if (updateRequired.value) return;
  await boot();
  if (phase.value === 'boot') bootError.value = 'Cannot reach the server.';
}

export function App() {
  useEffect(() => {
    setUnauthorizedHandler(() => { setToken(null); });
    setBannedHandler((b) => { banned.value = b; });
    setUpdateHandler((u) => { updateRequired.value = u; });
    void start();
  }, []);
  const p = phase.value;
  void lens.value;
  // A moderator reset the callsign while the app was open: choose a new one before playing on.
  const renaming = p === 'app' && !!me.value?.must_rename;
  useEffect(() => { if (renaming) phase.value = 'onboarding'; }, [renaming]);
  return (
    <div class="stage">
      <main class={'phone' + (desktop.value ? ' framed' : '')}>
        <ErrorBoundary>
          {updateRequired.value && <UpdateRequired />}
          {!updateRequired.value && banned.value && <Banned />}
          {!updateRequired.value && !banned.value && p === 'boot' && <Boot />}
          {!updateRequired.value && !banned.value && p === 'server' && <ServerAddress onDone={() => { phase.value = 'boot'; void start(); }} />}
          {!updateRequired.value && !banned.value && p === 'onboarding' && <Onboarding />}
          {!updateRequired.value && !banned.value && p === 'app' && (safetyRead.value || safetySeen() ? <Shell /> : <SafetyStep onDone={() => { safetyRead.value = true; }} />)}
        </ErrorBoundary>
      </main>
      {desktop.value && <SimPanel />}
    </div>
  );
}
