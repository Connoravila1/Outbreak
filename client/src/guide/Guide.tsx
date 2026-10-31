import { useSignal } from '@preact/signals';
import { catalog, faction, me, phase } from '../state/store';
import { current } from '../battle/session';
import { reading as noteReading } from '../notes/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { Sheet } from '../ui/Sheet';
import { Section } from '../ui/kit';
import { cardFor, dismissCard, entries, goTo, holdAt, pending, reading, type Entry } from './guide';
import './guide.css';

function CardSheet({ e, queued, left }: { e: Entry; queued: boolean; left: number }) {
  const f = faction.value ?? 'human';
  const c = cardFor(e, f);
  if (!c) return null;
  const close = () => { if (queued) dismissCard(e.key); else reading.value = null; };
  return (
    <Sheet title={c.title} onClose={close}>
      <div class="guide-card">
        <p class="eyebrow voice">{queued ? say(`Level ${e.level} unlocked`, `level ${e.level}. new.`) : say(`Field manual · level ${e.level}`, `what you know · level ${e.level}`)}</p>
        <h2 class="display guide-h">{c.title}</h2>
        <p class="guide-body">{c.body}</p>
        <div class="guide-actions">
          {c.act && <button class="btn primary block" onClick={() => { close(); goTo(c); }}>{c.act}</button>}
          <button class={'btn block' + (c.act ? '' : ' primary')} onClick={close}>{queued ? say('Got it', 'got it') : say('Close', 'close')}</button>
        </div>
        {queued && left > 1 && <p class="guide-more dim">{say(`${left - 1} more to read`, `${left - 1} more`)}</p>}
      </div>
    </Sheet>
  );
}

/**
 * The next waiting explainer, or the one opened from the Field manual. Waits while a fight, a
 * level-up or a found note is on screen, so it only ever appears after those are dismissed.
 */
export function GuideHost() {
  if (phase.value !== 'app' || !me.value) return null;
  const open = reading.value ? entries.value.find((x) => x.key === reading.value) : null;
  if (open) return <CardSheet key={open.key} e={open} queued={false} left={0} />;
  if (current.value || noteReading.value || holdAt.value) return null;
  const list = pending.value;
  const first = list[0];
  if (!first) return null;
  return <CardSheet key={first.key} e={first} queued left={list.length} />;
}

/** Everything the game has taught so far, to re-read; what is still ahead shows as its level. */
export function FieldManual() {
  const lvl = me.value?.level ?? 1;
  const list = entries.value;
  const f = faction.value ?? 'human';
  const open = useSignal(false);
  if (!catalog.value || !list.length) return null;
  const got = list.filter((e) => e.level <= lvl);
  return (
    <Section id="manual" title={say('Field manual', 'what the blood knows')} aside={`${got.length}/${list.length}`}>
      <button type="button" class="manual-toggle btn block" aria-expanded={open.value} onClick={() => { open.value = !open.value; }}>
        <Icon name="compass" size={20} />{open.value ? say('Hide', 'hide') : say('Open the manual', 'remember')}
      </button>
      {open.value && (
        <ul class="manual">
          {list.map((e) => {
            const yes = e.level <= lvl;
            const c = yes ? cardFor(e, f) : null;
            return (
              <li key={e.key}>
                <button type="button" class={'card manual-row' + (yes ? '' : ' locked')} disabled={!yes} onClick={() => { reading.value = e.key; }}>
                  <Icon name={yes ? 'scroll-unfurled' : 'padlock'} size={20} />
                  <span class="mr-main"><b>{c?.title ?? e.text}</b></span>
                  <span class="num mr-lvl">{say('Level', 'level')} {e.level}</span>
                </button>
              </li>
            );
          })}
        </ul>
      )}
    </Section>
  );
}
