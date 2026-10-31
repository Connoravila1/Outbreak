import { me } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';

/** A calm notice while the phone reports a simulated (mock) location. The server turns real-world fights and war points off meanwhile. */
export function SimulatedBanner() {
  if (!me.value?.simulated_location) return null;
  return (
    <p class="simbanner" role="status">
      <Icon name="gps" size={18} />
      <span>{say(
        'Your location is simulated. Real-world fights and war points are off.',
        'your location is simulated. real-world fights and war points are off.',
      )}</span>
    </p>
  );
}
