import { useEffect, useState } from 'preact/hooks';
import { api, errorMessage, getServerUrl, setServerUrl, KEYS } from '../api';
import { soundOn, hapticsOn, reducedMotion, setSetting } from '../state/store';
import { simActive, setSimActive, isDesktop } from '../location';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { Section } from '../ui/kit';
import { Credits } from './Credits';
import { Account } from './Account';
import { unlockAudio } from '../audio/fx';
import { VolumeSliders } from '../audio/VolumeSliders';
import { isNative } from '../native/platform';
import { patrolStatus, refreshPatrol, stopPatrol } from '../native/patrol';
import { patrolSheetOpen } from '../patrol/PatrolSheet';
import { SafetyRules } from '../safety/Safety';
import { Sheet } from '../ui/Sheet';

function Toggle({ label, hint, checked, onChange }: { label: string; hint?: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <label class="toggle-row">
      <span class="tg-text"><span>{label}</span>{hint && <small class="dim">{hint}</small>}</span>
      <input type="checkbox" checked={checked} onChange={(e) => onChange((e.target as HTMLInputElement).checked)} />
    </label>
  );
}

/** Patrol on/off. Turning it on opens the same sheet as the map button (duration, permissions). */
function PatrolToggle() {
  useEffect(() => { void refreshPatrol(); }, []);
  if (!isNative) {
    return <p class="dim lab">{say('Patrol mode needs the phone app.', 'roaming needs the phone app.')}</p>;
  }
  void patrolSheetOpen.value; // re-render when the sheet closes, so a cancelled switch snaps back
  const on = !!patrolStatus.value?.active;
  return (
    <Toggle
      label={say('Patrol', 'roam')}
      hint={say('Keep playing with the app closed. Results arrive as notifications. Uses some battery.', 'stay out there with the screen dark. you hear about it after.')}
      checked={on}
      onChange={(v) => { if (v) patrolSheetOpen.value = true; else void stopPatrol(); }}
    />
  );
}

type Probe = { ok: boolean; text: string } | null;

export function Settings() {
  const [server, setServer] = useState(getServerUrl());
  const [saved, setSaved] = useState(false);
  const [probe, setProbe] = useState<Probe>(null);
  const [testing, setTesting] = useState(false);
  const [credits, setCredits] = useState(false);
  const [safety, setSafety] = useState(false);

  const test = async () => {
    setTesting(true); setProbe(null);
    try {
      const h = await api.health(server);
      setProbe(h.ok ? { ok: true, text: say(`Connected. Server ${h.version}, ${h.players_online} online.`, `reached. ${h.players_online} awake.`) } : { ok: false, text: say('The server answered but says it is not ok.', 'it answered wrong.') });
    } catch (e) { setProbe({ ok: false, text: errorMessage(e) }); } finally { setTesting(false); }
  };

  return (
    <>
    <Account />
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
      {soundOn.value && <VolumeSliders />}
      <Toggle label={say('Haptics', 'touch')} checked={hapticsOn.value} onChange={(v) => setSetting(hapticsOn, KEYS.haptics, v)} />
      <Toggle label={say('Reduce motion', 'still')} hint={say('Overrides your device setting. No screen shake, no breathing.', 'no shaking. no breathing.')} checked={reducedMotion.value} onChange={(v) => setSetting(reducedMotion, KEYS.reducedMotion, v)} />
      <PatrolToggle />
      {!isNative && <Toggle label={say('GPS simulator', 'fake steps')} hint={isDesktop() ? undefined : say('For testing without walking.', 'for testing.')} checked={simActive.value} onChange={setSimActive} />}

      <div class="set-actions">
        <button class="btn block" onClick={() => setSafety(true)}><Icon name="shield" size={20} />{say('Play safe', 'play safe')}</button>
        <a class="btn block" href="terms.html" target="_blank" rel="noopener">{say('Terms of service', 'terms')}</a>
        <a class="btn block" href="privacy.html" target="_blank" rel="noopener">{say('Privacy policy', 'privacy')}</a>
        <button class="btn block" onClick={() => setCredits(true)}><Icon name="info" size={20} />{say('Credits', 'credits')}</button>
      </div>
      {credits && <Credits onClose={() => setCredits(false)} />}
      {safety && (
        <Sheet title={say('Play safe', 'play safe')} onClose={() => setSafety(false)} tall>
          <div class="safety-sheet">
            <SafetyRules />
          </div>
          <div class="sheet-actions"><button class="btn primary block" onClick={() => setSafety(false)}>{say('Got it', 'got it')}</button></div>
        </Sheet>
      )}
    </Section>
    </>
  );
}
