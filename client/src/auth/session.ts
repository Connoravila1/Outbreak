// Sign-in flows shared by onboarding and Settings: ask the provider, ask the server, keep the session.
import { signal } from '@preact/signals';
import { api, ApiError, errorMessage, setToken, type AuthProvider, type Credentials, type Me, type ProviderStatus } from '../api';
import { applyMe } from '../state/store';
import { say } from '../ui/voice';
import { applyTiles } from '../map/tiles';
import { Cancelled, pickApple, pickGoogle } from './social';

const NONE: ProviderStatus = { google: false, apple: false, dev: false };

/** What the server offers; null until /api/health has answered. */
export const providers = signal<ProviderStatus | null>(null);
/** The terms version the server has in force (from /api/health), and the one accepted on this run of onboarding. */
export const termsVersion = signal<number | null>(null);
export const termsAccepted = signal<number | null>(null);
export async function loadProviders(): Promise<ProviderStatus> {
  try {
    const h = await api.health();
    providers.value = { ...NONE, ...(h.providers ?? {}) };
    if (typeof h.terms_version === 'number') termsVersion.value = h.terms_version;
    applyTiles(h.tiles);
  } catch {
    providers.value = providers.value ?? NONE;
  }
  return providers.value;
}

export type Intent = 'signin' | 'link';
export interface Pending { provider: AuthProvider; creds: Credentials; intent: Intent }
export type Outcome =
  | { kind: 'done'; me: Me; created: boolean; switched: boolean }
  | { kind: 'conflict'; pending: Pending; message: string }
  | { kind: 'cancelled' };

const LABEL: Record<AuthProvider, string> = { google: 'Google', apple: 'Apple', dev: 'dev' };
export const providerLabel = (p: string) => LABEL[p as AuthProvider] ?? p;

async function credentials(provider: AuthProvider, status: ProviderStatus, dev?: Credentials): Promise<Credentials> {
  if (provider === 'google') return pickGoogle(status);
  if (provider === 'apple') return pickApple(status);
  return dev ?? {};
}

/** Ask the provider, then the server. A guest's own token rides along, so the server links or replaces it. */
export async function authenticate(provider: AuthProvider, intent: Intent, status: ProviderStatus, dev?: Credentials): Promise<Outcome> {
  let creds: Credentials;
  try { creds = await credentials(provider, status, dev); } catch (e) {
    if (e instanceof Cancelled) return { kind: 'cancelled' };
    throw e;
  }
  return send({ provider, creds, intent }, false);
}

/** Send credentials already in hand; `doSwitch` confirms leaving the current character behind. */
export async function send(p: Pending, doSwitch: boolean): Promise<Outcome> {
  try {
    if (p.intent === 'link') {
      const r = await api.authLink(p.provider, p.creds);
      applyMe(r.me);
      return { kind: 'done', me: r.me, created: false, switched: false };
    }
    const r = await api.authSignIn(p.provider, p.creds, { switch: doSwitch, terms: termsAccepted.value ?? undefined });
    setToken(r.token);
    applyMe(r.me);
    return { kind: 'done', me: r.me, created: r.created, switched: doSwitch };
  } catch (e) {
    if (e instanceof ApiError && e.code === 'identity_in_use' && p.intent === 'signin') {
      return { kind: 'conflict', pending: p, message: e.message };
    }
    throw e;
  }
}

/** A sentence a player can act on, in the lens voice. */
export function authMessage(e: unknown, provider?: AuthProvider): string {
  const name = provider ? providerLabel(provider) : 'that';
  if (e instanceof ApiError) {
    switch (e.code) {
      case 'network': return say("Can't reach the server. Check your connection and try again.", "no signal. check your connection. try again.");
      case 'provider_not_configured': return say(`Sign in with ${name} is not set up on this server yet.`, `${name.toLowerCase()} is not wired up here yet.`);
      case 'provider_unavailable': return say(`Could not reach ${name}. Try again in a moment.`, `${name.toLowerCase()} did not answer. try again.`);
      case 'token_expired': return say('That sign-in expired. Please try again.', 'that took too long. try again.');
      case 'identity_in_use': return say(`That ${name} account already belongs to another survivor.`, `that ${name.toLowerCase()} account is someone else's body.`);
      case 'terms_required': return say('There is no survivor on that account yet. Go back and start from the beginning.', 'nothing under that name yet. go back. start at the start.');
      case 'already_linked': return say(`A different ${name} account is already linked here.`, `another ${name.toLowerCase()} account is already tied to this body.`);
    }
    return e.message;
  }
  return errorMessage(e);
}
