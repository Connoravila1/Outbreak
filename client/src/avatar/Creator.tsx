import { useState } from 'preact/hooks';
import { api, errorMessage, type Faction } from '../api';
import { applyMe, catalog, lens } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { Avatar } from './Avatar';
import { COUNT, HAIRS, NAMES, SKINS, avatarDefaults, cleanAvatar, type AvatarKey, type AvatarSpec } from './spec';
import './avatar.css';

const TABS: { key: AvatarKey; label: [string, string] }[] = [
  { key: 'look', label: ['Look', 'strain'] },
  { key: 'body', label: ['Build', 'frame'] },
  { key: 'skin', label: ['Skin', 'flesh'] },
  { key: 'face', label: ['Face', 'face'] },
  { key: 'hair', label: ['Hair', 'hair'] },
  { key: 'hcol', label: ['Colour', 'tint'] },
  { key: 'facial', label: ['Facial', 'growth'] },
  { key: 'scar', label: ['Marks', 'marks'] },
];

interface Props {
  faction: Faction;
  level: number;
  initial?: unknown;
  /** Called after a successful save. */
  onDone: () => void;
  /** Onboarding: "Later" saves a random default. Sheet: "Cancel" just closes. */
  later?: boolean;
  onCancel?: () => void;
}

/** Avatar creator: live preview, category tabs, an option strip with mini previews. */
export function Creator({ faction, level, initial, onDone, later, onCancel }: Props) {
  const [spec, setSpec] = useState<AvatarSpec>(() => (initial ? cleanAvatar(initial) : avatarDefaults()));
  const [tab, setTab] = useState<AvatarKey>('hair');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const lz = lens.value;
  // Looks come from the catalog: names and the level each opens at. Not offered while making a first face.
  const looks = catalog.value?.avatar_looks ?? [];
  const tabs = later || !looks.length ? TABS.filter((t) => t.key !== 'look') : TABS;

  const save = async (s: AvatarSpec) => {
    setBusy(true); setErr(null);
    try {
      const r = await api.setAvatar({ ...s });
      applyMe(r.me);
      onDone();
    } catch (ex) {
      setErr(errorMessage(ex));
      setBusy(false);
    }
  };
  const set = (k: AvatarKey, v: number) => setSpec({ ...spec, [k]: v });
  const cur = TABS.find((t) => t.key === tab)!;

  return (
    <div class="av-creator">
      <p class="eyebrow">{say('Appearance', 'what they see')}</p>
      <h2 class="display av-title">{say('Put a face to the callsign.', 'a face. for now.')}</h2>
      <div class="av-stage">
        <Avatar spec={spec} faction={faction} level={level} lens={lz} size={208} label={say('Portrait preview', 'portrait')} />
      </div>
      <button type="button" class="btn av-rand" onClick={() => setSpec(avatarDefaults())}>{say('Randomize', 'shuffle')}</button>

      <div class="av-tabs" role="tablist" aria-label={say('Categories', 'categories')}>
        {tabs.map((t) => (
          <button type="button" key={t.key} role="tab" id={`avt-${t.key}`} aria-selected={tab === t.key} aria-controls="av-panel" class="av-tab" onClick={() => setTab(t.key)}>
            {say(...t.label)}
          </button>
        ))}
      </div>
      <div class="av-opts" role="tabpanel" id="av-panel" aria-labelledby={`avt-${tab}`}>
        {Array.from({ length: COUNT[tab] }, (_, i) => {
          const on = spec[tab] === i;
          const lk = tab === 'look' ? looks[i] : undefined;
          const name = lk ? lk.names[faction] : NAMES[tab][i];
          const locked = !!lk && level < lk.level;
          if (tab === 'look' && !lk) return null;
          const swatch = tab === 'skin' ? SKINS[i].hex : tab === 'hcol' ? HAIRS[i].hex : null;
          return (
            <button
              type="button" key={i} class={'av-opt' + (on ? ' on' : '') + (locked ? ' locked' : '')} aria-pressed={on} aria-disabled={locked || undefined}
              aria-label={`${cur.label[0]}: ${name}${locked ? `. ${say(`Level ${lk!.level}`, `level ${lk!.level}`)}` : ''}`} title={locked ? say(`Opens at level ${lk!.level}`, `opens at level ${lk!.level}`) : name}
              onClick={() => { if (!locked) set(tab, i); }}
            >
              {swatch ? <span class="av-sw" style={{ background: swatch }} /> : <Avatar spec={{ ...spec, [tab]: i }} faction={faction} level={level} lens={lz} size={56} />}
              <span class="av-name">{name}</span>
              {locked && <span class="av-lock"><Icon name="padlock" size={12} /> {say(`Level ${lk!.level}`, `level ${lk!.level}`)}</span>}
            </button>
          );
        })}
      </div>

      {err && <p class="ob-hint bad" role="alert">{err}</p>}
      <div class="av-actions">
        {later ? (
          <button type="button" class="btn" disabled={busy} onClick={() => void save(avatarDefaults())}>{say('Later', 'later')}</button>
        ) : (
          <button type="button" class="btn" disabled={busy} onClick={onCancel}>{say('Cancel', 'cancel')}</button>
        )}
        <button type="button" class="btn primary" disabled={busy} onClick={() => void save(spec)}>{busy ? '...' : say('Save', 'keep it')}</button>
      </div>
    </div>
  );
}
