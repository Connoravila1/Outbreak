import { ProviderButtons, type Done } from '../auth/ProviderButtons';

/** "Already playing? Sign in": restores the survivor that belongs to this account. */
export function SignIn({ onBack, onDone }: { onBack: () => void; onDone: (d: Done) => void }) {
  return (
    <div class="ob-screen signin">
      <div class="ob-card">
        <p class="eyebrow">Returning</p>
        <h1 class="ob-h">Welcome back.</h1>
        <p>Sign in with the account you saved your survivor to.</p>
        <ProviderButtons intent="signin" onDone={onDone} />
        <button class="btn block" type="button" onClick={onBack}>Back</button>
      </div>
    </div>
  );
}
