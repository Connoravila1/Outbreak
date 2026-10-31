import { signal } from '@preact/signals';
import type { Map as MlMap } from 'maplibre-gl';

/** The in-game map once mounted; used by the poller for the sanctuary test. */
export const gameMap = signal<MlMap | null>(null);
