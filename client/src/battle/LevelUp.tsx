import { useEffect, useRef, useState } from 'preact/hooks';
import type { Rewards } from '../api';
import { catalog, faction, reducedMotion } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { abilityName } from '../gear/util';
import * as fx from '../audio/fx';

type Up = NonNullable<Rewards['level_up']>;

function titleAt(level: number): string | null {
  const t = catalog.value?.levels.titles[faction.value ?? 'human'];
  return t ? t[Math.min(t.length - 1, Math.floor(level / 5))] ?? null : null;
}

/** Each unlock on its own line, from the catalog; falls back to the server's strings. */
export function unlockLines(up: Up): string[] {
  const c = catalog.value;
  const f = faction.value ?? 'human';
  if (!c) return up.unlocks;
  const lines: string[] = [];
  const mine = c.abilities.filter((a) => !a.faction || a.faction === f);
  // The ability gets its own line below, so the neutral "X / Y" wording is trimmed from the level text.
  for (const u of c.levels.unlocks) {
    if (u.level <= up.from || u.level > up.to) continue;
    const has = mine.some((a) => a.level === u.level);
    const text = has ? u.text.replace(/^New ability: .*$/, '').replace(/^(Ability slot \d+), and .*$/, '$1') : u.text;
    if (text) lines.push(text);
  }
  for (const a of mine) if (a.level > up.from && a.level <= up.to) lines.push(`${abilityName(a.id, f)}: ${a.text}`);
  if (lines.length) return lines;
  return up.unlocks.map((s) => c.abilities.find((a) => a.id === s) ? abilityName(s, f) : s.replace(/_/g, ' '));
}

export function LevelUp({ up, title, onContinue }: { up: Up; title: string; onContinue: () => void }) {
  const lines = unlockLines(up);
  const newTitle = titleAt(up.from) !== titleAt(up.to) ? title : null;
  const [shown, setShown] = useState(0);
  const btn = useRef<HTMLButtonElement>(null);
  useEffect(() => { fx.levelUp(); }, []);
  useEffect(() => {
    if (shown > lines.length + (newTitle ? 1 : 0)) { btn.current?.focus(); return; }
    const t = window.setTimeout(() => setShown(shown + 1), reducedMotion.peek() ? 150 : shown === 0 ? 900 : 550);
    return () => clearTimeout(t);
  }, [shown]);
  const done = shown > lines.length + (newTitle ? 1 : 0);
  return (
    <div class="levelup" role="status" aria-live="polite">
      <p class="eyebrow voice">{say('Level up', 'stronger')}</p>
      <p class="lv-num display" aria-label={`Level ${up.to}`}>{up.to}</p>
      <Icon name="laurels" size={40} class="lv-icon" />
      {newTitle && shown >= 1 && <p class="lv-title display">{newTitle}</p>}
      <ul class="lv-list">
        {lines.slice(0, Math.max(0, shown - (newTitle ? 1 : 0))).map((l, i) => (
          <li key={i}><Icon name="check-mark" size={20} />{l}</li>
        ))}
      </ul>
      <button ref={btn} class="btn primary block lv-btn" disabled={!done} onClick={onContinue}>{say('Continue', 'continue')}</button>
    </div>
  );
}
