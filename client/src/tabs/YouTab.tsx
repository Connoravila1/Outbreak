import { useState } from 'preact/hooks';
import { me, soundOn, hapticsOn, reducedMotion, setSetting, signOut } from '../state/store';
import { getServerUrl, setServerUrl, KEYS, storage } from '../api';
import { say } from '../ui/voice';
import { LevelRing } from '../shell/TopBar';
import { simActive, setSimActive } from '../location';
import '../shell/shell.css';

function Toggle({ label, checked, onChange }: { label: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <label class="toggle-row">
      <span>{label}</span>
      <input type="checkbox" checked={checked} onChange={(e) => onChange((e.target as HTMLInputElement).checked)} />
    </label>
  );
}

export function YouTab() {
  const m = me.value;
  const [server, setServer] = useState(getServerUrl());
  const [saved, setSaved] = useState(false);
  if (!m) return null;
  const s = m.stats;
  const recovery = storage.get(KEYS.recovery);
  return (
    <div class="panel scroll">
      <div style={{ display: 'flex', gap: 16, alignItems: 'center' }}>
        <LevelRing level={m.level} xp={m.xp} next={m.xp_next} />
        <div>
          <p class="display big-level">{m.level}</p>
          <p class="title">{m.title}</p>
        </div>
      </div>
      <p class="dim" style={{ margin: '8px 0 14px' }}><span class="num">{m.xp} / {m.xp_next}</span> {say('XP to next level', 'to the next hunger')}</p>
      <div class="card stat-grid">
        <div class="stat"><b>{s.hp}</b><span>HP</span></div>
        <div class="stat"><b>{s.atk}</b><span>ATK</span></div>
        <div class="stat"><b>{s.def}</b><span>DEF</span></div>
        <div class="stat"><b>{s.spd}</b><span>SPD</span></div>
      </div>
      <h3 class="display">{say('Record', 'record')}</h3>
      <p class="empty" style={{ padding: '8px 0' }}>{say('Wins, losses, contacts and distance walked arrive in the next pass.', 'counted later.')}</p>
      <h3 class="display">{say('Settings', 'settings')}</h3>
      <label class="dim" for="srv" style={{ fontSize: 'var(--fs-14)' }}>{say('Server URL (blank = this site)', 'server (blank = here)')}</label>
      <div style={{ display: 'flex', gap: 8, margin: '6px 0 10px' }}>
        <input id="srv" class="field" value={server} inputMode="url" autocapitalize="off" onInput={(e) => { setServer((e.target as HTMLInputElement).value); setSaved(false); }} />
        <button class="btn" onClick={() => { setServerUrl(server); setSaved(true); }}>{saved ? say('Saved', 'ok') : say('Save', 'save')}</button>
      </div>
      <Toggle label={say('Sound', 'sound')} checked={soundOn.value} onChange={(v) => setSetting(soundOn, KEYS.sound, v)} />
      <Toggle label={say('Haptics', 'touch')} checked={hapticsOn.value} onChange={(v) => setSetting(hapticsOn, KEYS.haptics, v)} />
      <Toggle label={say('Reduce motion', 'still')} checked={reducedMotion.value} onChange={(v) => setSetting(reducedMotion, KEYS.reducedMotion, v)} />
      <Toggle label={say('GPS simulator', 'fake steps')} checked={simActive.value} onChange={setSimActive} />
      <div class="kv"><span>{say('Recovery code', 'recovery code')}</span><b class="num">{recovery ?? say('Not stored on this device', 'not kept here')}</b></div>
      <p class="settings-note">{say('Write the recovery code down. It is the only way to move to a new phone.', 'keep the code. it is the only way back.')}</p>
      <div style={{ marginTop: 16 }}>
        <button class="btn danger block" onClick={() => { if (confirm('Forget this device? You will need your recovery code to come back.')) signOut(); }}>
          {say('Forget this device', 'leave')}
        </button>
      </div>
    </div>
  );
}
