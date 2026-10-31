import { tab, type TabId } from '../state/store';
import { say } from '../ui/voice';
import { Icon, type IconName } from '../ui/Icon';
import { unreadCount } from '../notes/store';
import './shell.css';

const TABS: { id: TabId; label: string; icon: IconName }[] = [
  { id: 'map', label: 'Map', icon: 'treasure-map' },
  { id: 'gear', label: 'Gear', icon: 'backpack' },
  { id: 'tasks', label: 'Tasks', icon: 'checklist' },
  { id: 'war', label: 'War', icon: 'crossed-swords' },
  { id: 'you', label: 'You', icon: 'person' },
];

/** Arrow keys, Home and End move between tabs (the selected tab is the only one in the Tab order). */
function onKeys(e: KeyboardEvent) {
  const i = TABS.findIndex((t) => t.id === tab.value);
  let n = i;
  if (e.key === 'ArrowRight') n = (i + 1) % TABS.length;
  else if (e.key === 'ArrowLeft') n = (i + TABS.length - 1) % TABS.length;
  else if (e.key === 'Home') n = 0;
  else if (e.key === 'End') n = TABS.length - 1;
  else return;
  e.preventDefault();
  tab.value = TABS[n].id;
  window.setTimeout(() => document.getElementById('tab-' + TABS[n].id)?.focus(), 0);
}

export function TabBar() {
  return (
    <nav class="tabbar" role="tablist" aria-label={say('Sections', 'sections')} onKeyDown={onKeys}>
      {TABS.map((t) => (
        <button key={t.id} id={'tab-' + t.id} class="tab" role="tab" aria-selected={tab.value === t.id} tabIndex={tab.value === t.id ? 0 : -1} aria-controls={t.id === 'map' ? undefined : 'panel-' + t.id} onClick={() => { tab.value = t.id; }}>
          <Icon name={t.icon} size={26} />
          <span>{t.label}</span>
          {t.id === 'you' && unreadCount.value > 0 && <i class="tab-dot" role="img" aria-label="Unread notes" />}
        </button>
      ))}
    </nav>
  );
}
