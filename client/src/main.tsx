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
import { App } from './app';
import { installMock, mockRequested } from './dev/mock';

// Neutral until a side is chosen; the store flips this once /api/me says who you are.
document.documentElement.dataset.lens = 'neutral';

if (mockRequested()) installMock();

render(<App />, document.getElementById('app')!);
