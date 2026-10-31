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

// Neutral until a side is chosen; the store flips this once /api/me says who you are.
document.documentElement.dataset.lens = 'neutral';

// Storage must be hydrated (native Preferences) before any module reads a setting, so the
// app and the store are imported only afterwards.
async function main() {
  await hydrateStorage();
  const [{ App }, { installMock, mockRequested }, { initNative }] = await Promise.all([
    import('./app'),
    import('./dev/mock'),
    import('./native/lifecycle'),
  ]);
  if (mockRequested()) installMock();
  initNative();
  render(<App />, document.getElementById('app')!);
}
void main();
