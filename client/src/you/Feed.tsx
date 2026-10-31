import { useEffect, useState } from 'preact/hooks';
import { api, errorMessage, type GameEvent } from '../api';
import { eventLog } from '../state/store';
import { say } from '../ui/voice';
import { Icon, type IconName } from '../ui/Icon';
import { ErrorLine, Section } from '../ui/kit';
import { ago } from '../ui/hooks';

const ICON: Record<GameEvent['type'], IconName> = {
  contact: 'radar-sweep', echo_report: 'ghost', level_up: 'laurels', raid: 'skull-crack', war_result: 'crossed-swords', clan: 'three-friends', achievement: 'trophy',
};

export function Feed() {
  const [events, setEvents] = useState<GameEvent[] | null>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => {
    api.feed().then((r) => setEvents(r.events), (e) => { setErr(errorMessage(e)); setEvents(eventLog.value); });
  }, []);
  return (
    <Section title={say('Feed', 'echoes of you')}>
      <ErrorLine text={err} />
      {!events && <p class="empty dim">…</p>}
      {events && events.length === 0 && <p class="empty">{say('Nothing yet. Walk, fight, and it fills in.', 'nothing yet.')}</p>}
      {events && events.length > 0 && (
        <ul class="feed">
          {events.map((e) => (
            <li class="card feed-row" key={e.id}>
              <Icon name={ICON[e.type] ?? 'info'} size={22} />
              <span class="fr-text">{e.text}</span>
              <span class="dim fr-at">{ago(e.at)}</span>
            </li>
          ))}
        </ul>
      )}
    </Section>
  );
}
