import { render } from 'preact';
import '@fontsource/big-shoulders-display/700';
import '@fontsource/big-shoulders-display/800';
import '@fontsource/big-shoulders-display/900';
import '@fontsource/barlow/400';
import '@fontsource/barlow/500';
import '@fontsource/barlow/600';
import '@fontsource/barlow/700';
import '@fontsource/permanent-marker/400';
import './styles/tokens.css';
import './styles/base.css';
import './styles/layout.css';
import { hydrateStorage } from './api/storage';
import { followSystemTextSize } from './native/textscale';

// Neutral until a side is chosen; the store flips this once /api/me says who you are.
document.documentElement.dataset.lens = 'neutral';

// Storage must be hydrated (native Preferences) before any module reads a setting, so the
// app and the store are imported only afterwards.
async function main() {
  await hydrateStorage();
  // The server may point the map at self-hosted tiles; ask before any map is created (never blocks long).
  const { loadTiles } = await import('./map/tiles');
  await Promise.race([loadTiles(), new Promise((r) => setTimeout(r, 1500))]);
  const [{ App }, { installMock, mockRequested }, { initNative }, { initAudio }] = await Promise.all([
    import('./app'),
    import('./dev/mock'),
    import('./native/lifecycle'),
    import('./audio/director'),
  ]);
  if (mockRequested()) installMock();
  initNative();
  followSystemTextSize();
  initAudio();
  render(<App />, document.getElementById('app')!);
}
void main();
