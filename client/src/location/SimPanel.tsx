import { useState } from 'preact/hooks';
import { PRESETS, getOnce, position, setSimActive, sim, simActive, simTick } from './index';
import { formatDistance, haversine } from './geo';
import { devMockGps } from './mock';
import './sim.css';

/** Desktop-only panel beside the phone: teleport, walk, and see what the game sees. */
export function SimPanel() {
  void simTick.value;
  const [msg, setMsg] = useState<string | null>(null);
  const on = simActive.value;
  const p = position.value;

  const useReal = async () => {
    setMsg('Asking the browser…');
    try {
      const r = await getOnce();
      sim.teleport({ lat: r.lat, lon: r.lon });
      setMsg(`Moved to your real location (±${Math.round(r.acc)} m).`);
    } catch (e) {
      setMsg('Could not get your real location: ' + (e instanceof Error ? e.message : 'denied') + '.');
    }
  };

  return (
    <aside class="simpanel" aria-label="GPS simulator">
      <h2>GPS simulator</h2>
      <label class="sim-toggle">
        <input type="checkbox" checked={on} onChange={(e) => setSimActive((e.target as HTMLInputElement).checked)} />
        <span>{on ? 'Simulating position' : 'Using device location'}</span>
      </label>
      {on && (
        <>
          <dl>
            <dt>Position</dt>
            <dd class="num">{sim.pos.lat.toFixed(5)}, {sim.pos.lon.toFixed(5)}</dd>
            <dt>Speed</dt>
            <dd class="num">{sim.speed.toFixed(1)} m/s</dd>
            <dt>Walking to</dt>
            <dd class="num">{sim.target ? `${formatDistance(haversine(sim.pos, sim.target))} away` : 'nowhere'}</dd>
          </dl>
          <p class="keys"><kbd>W</kbd><kbd>A</kbd><kbd>S</kbd><kbd>D</kbd> or arrows walk (1.4 m/s). Hold <kbd>Shift</kbd> to run (5 m/s). Click the map to walk there.</p>
          <h3>Teleport</h3>
          <div class="presets">
            {PRESETS.map((pr) => <button key={pr.name} onClick={() => sim.teleport(pr.at)}>{pr.name}</button>)}
            <button onClick={useReal}>Use my real location</button>
          </div>
          {msg && <p class="note" role="status">{msg}</p>}
        </>
      )}
      {on && (
        <label class="sim-toggle">
          <input type="checkbox" checked={devMockGps.value} onChange={(e) => { devMockGps.value = (e.target as HTMLInputElement).checked; }} />
          <span>Report as mock GPS</span>
        </label>
      )}
      <p class="note">Server sees: {p ? `${p.lat.toFixed(4)}, ${p.lon.toFixed(4)}` : 'no fix yet'}</p>
    </aside>
  );
}
