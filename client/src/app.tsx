import { useEffect } from 'preact/hooks';
import { signal } from '@preact/signals';
import { GameMap } from './map/GameMap';
import { TopBar } from './shell/TopBar';
import { Vitals } from './shell/Vitals';
import { TabBar } from './shell/TabBar';
import { MapTab } from './tabs/MapTab';
import { GearTab } from './tabs/GearTab';
import { TasksTab } from './tabs/TasksTab';
import { WarTab } from './tabs/WarTab';
import { YouTab } from './tabs/YouTab';
import { Onboarding } from './onboarding/Onboarding';
import { SimPanel } from './location/SimPanel';
import { boot, loadCatalog, phase, tab, lens, me } from './state/store';
import { isDesktop, startLocation } from './location';
import { startPolling, stopPolling } from './state/poll';
import { BattleHost } from './battle/BattleHost';
import { Toasts } from './ui/kit';
import { RewardsSheet } from './ui/RewardsSheet';
import { GuestNudge } from './you/GuestNudge';
import { NoteReader } from './notes/Reader';
import { setUnauthorizedHandler, setBannedHandler, setToken } from './api';
import { Banned } from './shell/Banned';
import { ReportSheet } from './ui/ReportSheet';
import { banned } from './state/moderation';
import { Icon } from './ui/Icon';
import { ServerAddress } from './onboarding/ServerAddress';
import { isNative } from './native/platform';
import { PatrolSheet } from './patrol/PatrolSheet';
import { PatrolReport } from './patrol/PatrolReport';
import { GuideHost } from './guide/Guide';
import './shell/shell.css';

const bootError = signal<string | null>(null);
const desktop = signal(isDesktop());
if (typeof matchMedia === 'function' && !isNative) {
  matchMedia('(min-width: 900px) and (pointer: fine)').addEventListener('change', (e) => { desktop.value = e.matches; });
}

function Shell() {
  useEffect(() => {
    void loadCatalog();
    startLocation();
    startPolling();
    return stopPolling;
  }, []);
  const t = tab.value;
  return (
    <div class="app">
      <div class="viewport">
        <GameMap />
        {t !== 'map' && (
          <div role="tabpanel" aria-label={t}>
            {t === 'gear' && <GearTab />}
            {t === 'tasks' && <TasksTab />}
            {t === 'war' && <WarTab />}
            {t === 'you' && <YouTab />}
          </div>
        )}
        <TopBar />
        {t === 'map' && <MapTab />}
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
    </div>
  );
}

function Boot() {
  return (
    <div class="ob-screen" style={{ background: '#000' }}>
      {bootError.value ? (
        <div class="ob-card">
          <h1 class="ob-h">No signal.</h1>
          <p>{bootError.value}</p>
          <button class="btn primary block" onClick={() => { bootError.value = null; void start(); }}>Try again</button>
        </div>
      ) : <Icon name="radar-sweep" size={48} class="spin" />}
    </div>
  );
}

async function start() {
  await boot();
  if (phase.value === 'boot') bootError.value = 'Cannot reach the server.';
}

export function App() {
  useEffect(() => {
    setUnauthorizedHandler(() => { setToken(null); });
    setBannedHandler((b) => { banned.value = b; });
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
        {banned.value && <Banned />}
        {!banned.value && p === 'boot' && <Boot />}
        {!banned.value && p === 'server' && <ServerAddress onDone={() => { phase.value = 'boot'; void start(); }} />}
        {!banned.value && p === 'onboarding' && <Onboarding />}
        {!banned.value && p === 'app' && <Shell />}
      </main>
      {desktop.value && <SimPanel />}
    </div>
  );
}
