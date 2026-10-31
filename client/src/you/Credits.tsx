import { Sheet } from '../ui/Sheet';

const ROWS: [string, string][] = [
  ['Map data', '© OpenStreetMap contributors, ODbL 1.0 (openstreetmap.org/copyright)'],
  ['Map tiles', 'OpenFreeMap and the OpenMapTiles schema (openfreemap.org)'],
  ['Map engine', 'MapLibre GL JS, BSD-3-Clause'],
  ['Icons', 'game-icons.net by Lorc, Delapouite and other contributors, CC BY 3.0 (creativecommons.org/licenses/by/3.0)'],
  ['Fonts', 'Big Shoulders Display (Patric King / Chicago Tribune), Barlow (Jeremy Tribby), Permanent Marker (Font Diner), all SIL OFL 1.1'],
  ['Interface', 'Preact and @preact/signals, MIT'],
  ['Sound', 'Kenney (Interface Sounds, RPG Audio), artisticdude (RPG Sound Pack), StarNinjas (16 Monster Growls), Bashar3A, primbal and bretbernhoft (wind, breathing, static), all CC0 via opengameart.org. The rest is synthesised, and the music is original.'],
];

export function Credits({ onClose }: { onClose: () => void }) {
  return (
    <Sheet title="Credits" onClose={onClose} tall>
      <h2 class="display obj-title">Credits</h2>
      <dl class="credits">
        {ROWS.map(([k, v]) => (<div key={k}><dt>{k}</dt><dd>{v}</dd></div>))}
      </dl>
      <div class="sheet-actions"><button class="btn primary block" onClick={onClose}>Close</button></div>
    </Sheet>
  );
}
