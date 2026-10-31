// Provider sign-in through @capgo/capacitor-social-login (Google + Apple on Android, iOS and web).
// It only ever returns an ID token (plus the nonce we made up); the server verifies it.
import { SocialLogin } from '@capgo/capacitor-social-login';
import { Capacitor } from '@capacitor/core';
import type { Credentials, ProviderStatus } from '../api';
import { isNative } from '../native/platform';

/** The player closed the provider's sheet or popup. Not an error worth showing. */
export class Cancelled extends Error {
  constructor() { super('cancelled'); }
}

/** Something this build or device cannot do (missing client ID, no Google account, ...). */
export class Unavailable extends Error {}

export type Platform = 'ios' | 'android' | 'web';
export const platform = (): Platform => Capacitor.getPlatform() as Platform;

const env = import.meta.env;

/** What the server reported plus this build's own IDs. */
interface Ids { googleWeb?: string; googleIos?: string; appleService?: string; appleRedirect?: string }
export function idsFor(status: ProviderStatus): Ids {
  return {
    googleWeb: env.VITE_GOOGLE_WEB_CLIENT_ID || status.google_web_client_id || undefined,
    googleIos: env.VITE_GOOGLE_IOS_CLIENT_ID || undefined,
    appleService: env.VITE_APPLE_SERVICE_ID || status.apple_web_service_id || undefined,
    appleRedirect: env.VITE_APPLE_REDIRECT_URL || (isNative ? undefined : location.origin + '/'),
  };
}

/** Can this build start a sign-in with this provider at all? (The server must also have it on.) */
export function canUse(provider: 'google' | 'apple', status: ProviderStatus): boolean {
  const ids = idsFor(status);
  const p = platform();
  if (provider === 'google') return p === 'ios' ? !!ids.googleIos : !!ids.googleWeb;
  // iOS uses the system sheet and needs no web IDs; everywhere else Apple goes through its web flow.
  return p === 'ios' ? true : !!(ids.appleService && ids.appleRedirect);
}

/** Order of the buttons: the platform's own provider first. */
export function providerOrder(): ('apple' | 'google')[] {
  return platform() === 'ios' ? ['apple', 'google'] : platform() === 'android' ? ['google', 'apple'] : ['google', 'apple'];
}

function randomNonce(): string {
  const b = new Uint8Array(16);
  crypto.getRandomValues(b);
  return Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
}

const CANCEL = /cancel|dismiss|closed|aborted|denied|\b1001\b|\b12501\b|user_cancel/i;
function rethrow(e: unknown): never {
  const msg = e instanceof Error ? e.message : typeof e === 'string' ? e : JSON.stringify(e ?? '');
  const code = (e as { code?: unknown } | null)?.code;
  if (CANCEL.test(msg) || (typeof code === 'string' && CANCEL.test(code))) throw new Cancelled();
  throw new Unavailable(msg || 'Sign-in failed.');
}

const ready = new Set<string>();

export async function pickGoogle(status: ProviderStatus): Promise<Credentials> {
  const ids = idsFor(status);
  const ios = platform() === 'ios';
  if (ios ? !ids.googleIos : !ids.googleWeb) throw new Unavailable('Google sign-in is not set up in this build.');
  const nonce = randomNonce();
  try {
    if (!ready.has('google')) {
      await SocialLogin.initialize({ google: { webClientId: ids.googleWeb, iOSClientId: ids.googleIos, iOSServerClientId: ids.googleWeb, mode: 'online' } });
      ready.add('google');
    }
    const r = await SocialLogin.login({ provider: 'google', options: { nonce } });
    const res = r.result;
    if (res.responseType !== 'online' || !res.idToken) throw new Unavailable('Google did not return an ID token.');
    return { id_token: res.idToken, nonce };
  } catch (e) { return rethrow(e); }
}

export async function pickApple(status: ProviderStatus): Promise<Credentials> {
  const ids = idsFor(status);
  if (platform() !== 'ios' && !(ids.appleService && ids.appleRedirect)) throw new Unavailable('Apple sign-in is not set up in this build.');
  const nonce = randomNonce();
  try {
    if (!ready.has('apple')) {
      await SocialLogin.initialize({ apple: { clientId: ids.appleService, redirectUrl: ids.appleRedirect, useBroadcastChannel: platform() === 'android' } });
      ready.add('apple');
    }
    const r = await SocialLogin.login({ provider: 'apple', options: { scopes: ['email'], nonce } });
    if (!r.result.idToken) throw new Unavailable('Apple did not return an ID token.');
    return { id_token: r.result.idToken, nonce };
  } catch (e) { return rethrow(e); }
}
