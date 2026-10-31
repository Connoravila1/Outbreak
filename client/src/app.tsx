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
import { boot, loadCatalog, phase, tab, lens } from './state/store';
import { isDesktop, startLocation } from './location';
import { startPolling, stopPolling } from './state/poll';
import { BattleHost } from './battle/BattleHost';
import { Toasts } from './ui/kit';
import { RewardsSheet } from './ui/RewardsSheet';
import { setUnauthorizedHandler, setToken } from './api';
import { Icon } from './ui/Icon';
import './shell/shell.css';

const bootError = signal<string | null>(null);
const desktop = signal(isDesktop());
if (typeof matchMedia === 'function') {
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
    void start();
  }, []);
  const p = phase.value;
  void lens.value;
  return (
    <div class="stage">
      <main class={'phone' + (desktop.value ? ' framed' : '')}>
        {p === 'boot' && <Boot />}
        {p === 'onboarding' && <Onboarding />}
        {p === 'app' && <Shell />}
      </main>
      {desktop.value && <SimPanel />}
    </div>
  );
}
