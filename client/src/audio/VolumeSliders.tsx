import { say } from '../ui/voice';
import { effectsVol, musicVol, setEffectsVol, setMusicVol } from './prefs';
import { tap } from './fx';
import './audio.css';

function Slider({ label, hint, value, onInput }: { label: string; hint: string; value: number; onInput: (v: number) => void }) {
  return (
    <label class="vol-row">
      <span class="tg-text"><span>{label}</span><small class="dim">{hint}</small></span>
      <input type="range" min="0" max="100" step="5" value={Math.round(value * 100)} aria-label={label}
        onInput={(e) => onInput(Number((e.target as HTMLInputElement).value) / 100)}
        onChange={() => tap()} />
    </label>
  );
}

/** Music and Effects volume, shown under the Sound switch. */
export function VolumeSliders() {
  return (
    <div class="vol-box">
      <Slider label={say('Music', 'music')} hint={say('Menu theme and map ambience.', 'the hum under everything.')} value={musicVol.value} onInput={setMusicVol} />
      <Slider label={say('Effects', 'effects')} hint={say('Taps, fights, loot, alarms.', 'bites, beats, breath.')} value={effectsVol.value} onInput={setEffectsVol} />
    </div>
  );
}
