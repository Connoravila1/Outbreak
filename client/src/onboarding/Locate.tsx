import { useEffect, useState } from 'preact/hooks';
import { locationError, position, setSimActive, simActive, startLocation, isDesktop, requestLocationPermission } from '../location';
import { unlockAudio } from '../audio/fx';
import { isNative } from '../native/platform';

/** Location permission, with the honest framing. */
export function Locate({ onDone }: { onDone: () => void }) {
  const [asked, setAsked] = useState(false);
  const err = locationError.value;
  const have = !!position.value;

  useEffect(() => { if (have && asked) onDone(); }, [have, asked]);
  useEffect(() => { if (simActive.value) startLocation(); }, []);

  const ask = async () => {
    unlockAudio();
    setAsked(true);
    if (!(await requestLocationPermission())) { locationError.value = 'Location permission was denied. Turn it on in Settings, then try again.'; return; }
    startLocation();
  };

  return (
    <div class="ob-screen locate">
      <div class="ob-card">
        <p class="eyebrow">Before you go out</p>
        <h1 class="ob-h">The world is the map.</h1>
        <p>Outbreak uses your location to build the world around you. It's never shown to other players.</p>
        <ul class="ob-list">
          <li>Fights are anonymous. Nobody learns who you are or where.</li>
          <li>Your position is held in memory for two minutes and never saved.</li>
          <li>Nothing is read while the app is closed.</li>
        </ul>
        {asked && !err && !have && <p class="ob-status" role="status">Looking for you…</p>}
        {err && <p class="ob-error" role="alert">{err}</p>}
        <div class="ob-actions">
          <button class="btn primary block" onClick={ask}>{err ? 'Try again' : asked ? 'Waiting…' : 'Allow location'}</button>
          {!isNative && (err || isDesktop()) && (
            <button class="btn block" onClick={() => { setSimActive(true); setAsked(true); }}>Use the desktop simulator</button>
          )}
        </div>
      </div>
    </div>
  );
}
