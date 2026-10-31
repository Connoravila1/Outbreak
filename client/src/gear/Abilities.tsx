import { useState } from 'preact/hooks';
import { api, errorMessage } from '../api';
import { applyMe, catalog, faction, me } from '../state/store';
import { Icon } from '../ui/Icon';
import { say } from '../ui/voice';
import { ErrorLine, Section } from '../ui/kit';
import { abilityName } from './util';

/** Unlocked abilities fill the slots; tap to put one in or take it out. */
export function Abilities() {
  const m = me.value;
  const c = catalog.value;
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  if (!m || !c) return null;
  const f = faction.value ?? 'human';
  const { unlocked, equipped, slots } = m.abilities;
  const list = c.abilities.filter((a) => !a.faction || a.faction === f).sort((a, b) => a.level - b.level);
  const set = async (next: string[]) => {
    setBusy(true); setErr(null);
    try { applyMe((await api.setAbilities(next)).me); } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  };
  const firstLocked = list.find((a) => !unlocked.includes(a.id));
  return (
    <Section id="abilities" title={say('Abilities', 'instincts')} aside={`${equipped.length} / ${slots} ${say('slots', 'slots')}`}>
      <div class="slot-strip" aria-label="Ability slots">
        {slots === 0
          ? <p class="dim">{say('Your first slot opens at level 3.', 'a first instinct wakes at level 3.')}</p>
          : Array.from({ length: slots }, (_, i) => {
            const id = equipped[i];
            return (
              <div key={i} class={'ab-slot' + (id ? ' filled' : '')}>
                {id ? abilityName(id, f) : say('Empty slot', 'empty')}
              </div>
            );
          })}
      </div>
      <ul class="ab-list">
        {list.map((a) => {
          const open = unlocked.includes(a.id);
          const on = equipped.includes(a.id);
          const full = !on && equipped.length >= slots;
          const reason = !open ? say(`Unlocks at level ${a.level}.`, `level ${a.level}.`) : full ? say(slots === 0 ? 'No slot yet.' : 'Slots full. Remove one first.', slots === 0 ? 'no room yet.' : 'full. let one go.') : null;
          return (
            <li key={a.id}>
              <button
                class={'card ab' + (on ? ' on' : '') + (!open ? ' locked' : '')}
                disabled={busy || !!reason}
                aria-disabled={busy || !!reason}
                aria-pressed={open ? on : undefined}
                onClick={() => set(on ? equipped.filter((x) => x !== a.id) : [...equipped, a.id])}
              >
                <Icon name={open ? 'lightning-helix' : 'padlock'} size={22} />
                <span class="ab-body">
                  <b>{a.names[f]}</b>
                  <span class="dim">{a.text}</span>
                  {reason && <span class="reason">{reason}</span>}
                </span>
                {open && <span class={'label-tape ab-state'}>{on ? say('Equipped', 'active') : say('Tap to equip', 'tap')}</span>}
              </button>
            </li>
          );
        })}
      </ul>
      {firstLocked && unlocked.length === 0 && slots > 0 && <p class="dim">{say('Abilities unlock by level.', 'they come with level.')}</p>}
      <ErrorLine text={err} />
    </Section>
  );
}
