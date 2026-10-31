import { useEffect, useState } from 'preact/hooks';
import { signal } from '@preact/signals';
import { Sheet } from '../ui/Sheet';
import { Icon } from '../ui/Icon';
import { say } from '../ui/voice';
import { useNow, longClock } from '../ui/hooks';
import { requestNotifyPermission } from '../native/notify';
import {
  openPatrolSettings, patrolAvailable, patrolStatus, refreshPatrol, requestBackgroundLocation, startPatrol, stopPatrol,
} from '../native/patrol';
import './patrol.css';

export const patrolSheetOpen = signal(false);

const DURATIONS: { label: string; heat: string; sec: number }[] = [
  { label: '1 h', heat: 'an hour', sec: 3600 },
  { label: '3 h', heat: 'three hours', sec: 3 * 3600 },
  { label: 'Until I stop', heat: 'until i stop', sec: 0 },
];

/** Remaining time label for the map button and sheet: "2h 05m", or "on" when it has no end. */
export function patrolLeft(endsAt: number, now: number): string {
  return endsAt > 0 ? longClock(endsAt - now) : say('on', 'on');
}

/** Start / stop control: shared by the map button and Settings. */
function Controls({ onClose }: { onClose: () => void }) {
  const st = patrolStatus.value;
  const now = useNow(1000);
  const [dur, setDur] = useState(3600);
  const [step, setStep] = useState<'pick' | 'background'>('pick');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [asked, setAsked] = useState(false);
  useEffect(() => { void refreshPatrol(); }, []);

  const begin = async () => {
    setBusy(true); setErr(null);
    try {
      await requestNotifyPermission(); // results arrive as notifications; asked once
      await startPatrol(dur);
      onClose();
    } catch (e) {
      setErr((e as Error).message);
    } finally { setBusy(false); }
  };

  const allowAllTheTime = async () => {
    setBusy(true); setAsked(true);
    await requestBackgroundLocation();
    setBusy(false);
  };

  if (st?.active) {
    const age = st.lastCheckIn > 0 ? Math.max(0, Math.round((now - st.lastCheckIn) / 1000)) : null;
    return (
      <>
        <h2 class="display pt-title">{say('Patrol is on', 'you are out there')}</h2>
        <p class="pt-line">
          {st.endsAt > 0
            ? say(`Ends in ${longClock(st.endsAt - now)}.`, `it ends in ${longClock(st.endsAt - now)}.`)
            : say('Runs until you stop it.', 'until you call it off.')}
        </p>
        <p class="pt-line dim">
          {age == null
            ? say('Waiting for the first check-in.', 'waiting to be seen.')
            : say(`Last check-in ${age < 90 ? `${age}s` : `${Math.round(age / 60)}m`} ago.`, `last seen ${age < 90 ? `${age}s` : `${Math.round(age / 60)}m`} ago.`)}
          {st.lastError === 'no_fix' && ` ${say('No location fix yet.', 'no signal.')}`}
          {st.lastError === 'network' && ` ${say('Server unreachable; retrying.', 'cannot reach the world. trying.')}`}
        </p>
        {!st.backgroundLocation && <p class="pt-warn">{say('Location is "while in use" only. Patrol runs as long as Android lets this session live; if the phone restarts it, open Outbreak and start again.', 'only while in use. if the phone ends this, open the app and go again.')}</p>}
        {!st.notifications && <p class="pt-warn">{say('Notifications are off, so results will wait for you in the app.', 'alerts are off. the results will wait.')}</p>}
        <div class="sheet-actions">
          <button class="btn danger block" onClick={async () => { await stopPatrol(); onClose(); }}>{say('Stop patrol', 'come back in')}</button>
        </div>
      </>
    );
  }

  if (step === 'background') {
    const granted = !!st?.backgroundLocation;
    return (
      <>
        <h2 class="display pt-title">{say('Location, all the time', 'let it watch while you sleep')}</h2>
        <p class="pt-line">{say('Patrol reads your location while Outbreak is closed. Android only allows that if you pick "Allow all the time" in the location settings.', 'it has to see where you are with the app shut. android asks you to choose "allow all the time".')}</p>
        <p class="pt-line dim">{say('Your position is used to find fights nearby and is never shown to other players or stored.', 'your place is never shown. never kept.')}</p>
        {granted && <p class="pt-ok"><Icon name="check-mark" size={18} />{say('Allowed all the time.', 'allowed.')}</p>}
        {asked && !granted && !busy && (
          <p class="pt-warn">{say('Still "while in use". You can change it in Settings > Location > Allow all the time.', 'still only while in use. change it in settings.')}</p>
        )}
        <div class="sheet-actions">
          {!granted && <button class="btn primary block" disabled={busy} onClick={allowAllTheTime}>{busy ? '…' : say('Allow all the time', 'allow')}</button>}
          {asked && !granted && <button class="btn block" onClick={openPatrolSettings}>{say('Open app settings', 'open settings')}</button>}
          <button class={'btn block' + (granted ? ' primary' : '')} disabled={busy} onClick={() => void begin()}>
            {granted ? say('Start patrol', 'go out') : say('Patrol anyway', 'go anyway')}
          </button>
          {!granted && <p class="reason">{say('Without it, Patrol works only while Android keeps this session alive. If the phone ends it, open Outbreak and start again.', 'without it the phone may end the watch. open the app and go again.')}</p>}
          {err && <p class="reason" role="alert" style={{ color: 'var(--danger)' }}>{err}</p>}
        </div>
      </>
    );
  }

  return (
    <>
      <h2 class="display pt-title">{say('Patrol', 'roam')}</h2>
      <p class="pt-line">{say('Keeps you in the world with the app closed.', 'you stay out there while the screen sleeps.')}</p>
      <p class="pt-line">{say('Fights find you; results arrive as notifications.', 'things find you. you hear about it after.')}</p>
      <p class="pt-line dim">{say('Uses some battery.', 'it costs some battery.')}</p>
      <div class="pt-durs" role="radiogroup" aria-label={say('Duration', 'how long')}>
        {DURATIONS.map((d) => (
          <button key={d.sec} class={'pt-dur' + (dur === d.sec ? ' on' : '')} role="radio" aria-checked={dur === d.sec} onClick={() => setDur(d.sec)}>
            {say(d.label, d.heat)}
          </button>
        ))}
      </div>
      <div class="sheet-actions">
        <button class="btn primary block" disabled={busy} onClick={() => (st && !st.backgroundLocation ? setStep('background') : void begin())}>
          {busy ? '…' : say('Start', 'go')}
        </button>
        {err && <p class="reason" role="alert" style={{ color: 'var(--danger)' }}>{err}</p>}
      </div>
    </>
  );
}

export function PatrolSheet() {
  if (!patrolAvailable || !patrolSheetOpen.value) return null;
  const close = () => { patrolSheetOpen.value = false; };
  return (
    <Sheet title={say('Patrol', 'roam')} onClose={close}>
      <Controls onClose={close} />
    </Sheet>
  );
}
