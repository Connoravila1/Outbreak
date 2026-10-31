import { Component, type ComponentChildren } from 'preact';
import { reportError } from '../report/errors';
import '../onboarding/onboarding.css';

/**
 * Catches an error thrown while drawing and shows a plain card instead of a white screen.
 * The report that goes out has no personal details; Reload starts the app again from the saved session.
 */
export class ErrorBoundary extends Component<{ children?: ComponentChildren }, { failed: boolean }> {
  state = { failed: false };

  static getDerivedStateFromError() { return { failed: true }; }

  componentDidCatch(error: unknown) { reportError(error, 'render'); }

  render() {
    if (!this.state.failed) return this.props.children;
    return (
      <div class="ob-screen" role="alert">
        <div class="ob-card">
          <p class="eyebrow">Error</p>
          <h1 class="ob-h">Something broke.</h1>
          <p class="ob-hint">The app hit a problem and could not go on. Your character is safe. A short report with no personal details was sent.</p>
          <div class="ob-actions">
            <button class="btn primary block" onClick={() => location.reload()}>Reload</button>
          </div>
        </div>
      </div>
    );
  }
}
