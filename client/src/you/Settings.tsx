import { useState } from 'preact/hooks';
import { api, errorMessage, getServerUrl, setServerUrl, KEYS, storage } from '../api';
import { soundOn, hapticsOn, reducedMotion, setSetting, signOut } from '../state/store';
import { simActive, setSimActive, isDesktop } from '../location';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { Section } from '../ui/kit';
import { Credits } from './Credits';
import { unlockAudio } from '../audio/fx';

function Toggle({ label, hint, checked, onChange }: { label: string; hint?: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <label class="toggle-row">
      <span class="tg-text"><span>{label}</span>{hint && <small class="dim">{hint}</small>}</span>
      <input type="checkbox" checked={checked} onChange={(e) => onChange((e.target as HTMLInputElement).checked)} />
    </label>
  );
}

type Probe = { ok: boolean; text: string } | null;

export function Settings() {
  const [server, setServer] = useState(getServerUrl());
  const [saved, setSaved] = useState(false);
  const [probe, setProbe] = useState<Probe>(null);
  const [testing, setTesting] = useState(false);
  const [showCode, setShowCode] = useState(false);
  const [copied, setCopied] = useState(false);
  const [credits, setCredits] = useState(false);
  const recovery = storage.get(KEYS.recovery);

  const test = async () => {
    setTesting(true); setProbe(null);
    try {
      const h = await api.health(server);
      setProbe(h.ok ? { ok: true, text: say(`Connected. Server ${h.version}, ${h.players_online} online.`, `reached. ${h.players_online} awake.`) } : { ok: false, text: say('The server answered but says it is not ok.', 'it answered wrong.') });
    } catch (e) { setProbe({ ok: false, text: errorMessage(e) }); } finally { setTesting(false); }
  };

  return (
    <Section title={say('Settings', 'settings')}>
      <label class="dim lab" for="srv">{say('Server URL (blank = this site)', 'server (blank = here)')}</label>
      <div class="row-gap">
        <input id="srv" class="field" value={server} inputMode="url" autocapitalize="off" onInput={(e) => { setServer((e.target as HTMLInputElement).value); setSaved(false); setProbe(null); }} />
        <button class="btn" onClick={() => { setServerUrl(server); setSaved(true); }}>{saved ? say('Saved', 'ok') : say('Save', 'save')}</button>
      </div>
      <div class="row-gap probe">
        <button class="btn" disabled={testing} onClick={test}>{testing ? '…' : say('Test connection', 'test')}</button>
        {probe && <p class={'probe-out ' + (probe.ok ? 'ok' : 'bad')} role="status"><Icon name={probe.ok ? 'check-mark' : 'cancel'} size={18} />{probe.text}</p>}
      </div>

      <Toggle label={say('Sound', 'sound')} checked={soundOn.value} onChange={(v) => { setSetting(soundOn, KEYS.sound, v); if (v) unlockAudio(); }} />
      <Toggle label={say('Haptics', 'touch')} checked={hapticsOn.value} onChange={(v) => setSetting(hapticsOn, KEYS.haptics, v)} />
      <Toggle label={say('Reduce motion', 'still')} hint={say('Overrides your device setting. No screen shake, no breathing.', 'no shaking. no breathing.')} checked={reducedMotion.value} onChange={(v) => setSetting(reducedMotion, KEYS.reducedMotion, v)} />
      <Toggle label={say('GPS simulator', 'fake steps')} hint={isDesktop() ? undefined : say('For testing without walking.', 'for testing.')} checked={simActive.value} onChange={setSimActive} />

      <div class="kv code-kv">
        <span>{say('Recovery code', 'recovery code')}</span>
        {recovery ? (
          <span class="code-act">
            <b class="num code-val">{showCode ? recovery : '•••• •••• ••••'}</b>
            <button class="btn" aria-pressed={showCode} onClick={() => setShowCode(!showCode)}>{showCode ? say('Hide', 'hide') : say('Show', 'show')}</button>
            {showCode && <button class="btn" onClick={() => { void navigator.clipboard?.writeText(recovery).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1800); }, () => undefined); }}>{copied ? say('Copied', 'copied') : say('Copy', 'copy')}</button>}
          </span>
        ) : <b>{say('Not stored on this device', 'not kept here')}</b>}
      </div>
      <p class="settings-note">{say('Write the recovery code down. It is the only way to move to a new phone.', 'keep the code. it is the only way back.')}</p>

      <div class="set-actions">
        <button class="btn block" onClick={() => setCredits(true)}><Icon name="info" size={20} />{say('Credits', 'credits')}</button>
        <button class="btn danger block" onClick={() => { if (confirm('Forget this device? You will need your recovery code to come back.')) signOut(); }}>
          {say('Forget this device', 'leave')}
        </button>
      </div>
      {credits && <Credits onClose={() => setCredits(false)} />}
    </Section>
  );
}
