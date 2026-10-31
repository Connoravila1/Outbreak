import { tab, type TabId } from '../state/store';
import { Icon, type IconName } from '../ui/Icon';
import './shell.css';

const TABS: { id: TabId; label: string; icon: IconName }[] = [
  { id: 'map', label: 'Map', icon: 'treasure-map' },
  { id: 'gear', label: 'Gear', icon: 'backpack' },
  { id: 'tasks', label: 'Tasks', icon: 'checklist' },
  { id: 'war', label: 'War', icon: 'crossed-swords' },
  { id: 'you', label: 'You', icon: 'person' },
];

export function TabBar() {
  return (
    <nav class="tabbar" role="tablist" aria-label="Sections">
      {TABS.map((t) => (
        <button key={t.id} class="tab" role="tab" aria-selected={tab.value === t.id} onClick={() => { tab.value = t.id; }}>
          <Icon name={t.icon} size={26} />
          <span>{t.label}</span>
        </button>
      ))}
    </nav>
  );
}
