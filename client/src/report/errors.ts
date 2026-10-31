// Crash and error reports. Anything that goes wrong in the app (a script error, a rejected promise, a
// render error, a failed native plugin call) is queued, scrubbed and sent to POST /api/client-error in
// small batches. Reports are anonymous: no token is needed, and nothing that could be a position goes
// out (coordinates, URL query strings, request bodies). A report is dropped silently when the phone
// is offline, when the same one was already sent this session, or when the session has sent plenty.
import { Capacitor } from '@capacitor/core';
import { api, ApiError, CLIENT_VERSION, type ClientErrorReport } from '../api';

export const MESSAGE_MAX = 500;
export const STACK_MAX = 4000;
/** Reports waiting this long are sent together. */
const FLUSH_MS = 5000;
const BATCH_MAX = 10;
/** Distinct reports one session may send; a loop of new errors must not become a flood. */
const SESSION_MAX = 25;

/** Never-throwing text clip that does not end inside a surrogate pair. */
function clip(s: string, max: number): string {
  if (s.length <= max) return s;
  const cut = /[\ud800-\udbff]/.test(s[max - 1] ?? '') ? max - 1 : max;
  return s.slice(0, cut);
}

/**
 * Remove what could point at a place or identify a session: query strings and fragments from URLs and
 * paths (a stack frame keeps its ":line:col"), decimal numbers that look like a latitude or longitude
 * (at most three whole digits, four or more fractional digits), bearer tokens and long hex strings.
 * The server applies the same rules again.
 */
export function scrub(text: string): string {
  const noUrlDetail = text.replace(/[^\s"'()<>[\]`]+/g, (tok) => {
    if (!(tok.includes('://') || tok.startsWith('/'))) return tok;
    const cut = tok.search(/[?#]/);
    if (cut < 0) return tok;
    const line = /(?::\d+){1,2}$/.exec(tok);
    return tok.slice(0, cut) + (line ? line[0] : '');
  });
  return noUrlDetail
    .replace(/(^|[^\d.A-Za-z])(-?\d{1,3}\.\d{4,})/g, '$1~')
    .replace(/Bearer\s+[A-Za-z0-9._~+/=-]+/gi, 'Bearer ~')
    .replace(/\b[a-f0-9]{40,}\b/gi, '~');
}

/** The first stack line that looks like a frame ("at f (url:1:2)" or "f@url:1:2"). */
export function topFrame(stack: string): string {
  for (const raw of stack.split('\n')) {
    const line = raw.trim();
    if (line.startsWith('at ') || line.includes('@')) return line.slice(0, 300);
  }
  return '';
}

function describe(err: unknown): { message: string; stack: string } {
  if (err instanceof Error) {
    const named = err.name && err.name !== 'Error' ? `${err.name}: ${err.message}` : err.message;
    return { message: named || err.name || 'Error', stack: err.stack ?? '' };
  }
  if (typeof err === 'string') return { message: err, stack: '' };
  // Never serialize an arbitrary object: it may carry a request body or a position.
  const m = (err as { message?: unknown } | null)?.message;
  return { message: typeof m === 'string' ? m : 'Non-error value thrown', stack: '' };
}

/** What is on screen ("map", "gear", "onboarding"...); the app sets it once its state exists. */
let screenOf: () => string = () => '';
export function setScreenProvider(fn: () => string) { screenOf = fn; }

const seen = new Set<string>();
let queue: ClientErrorReport[] = [];
let timer: number | null = null;
let accepted = 0;
let sending = false;

/** Known noise: browser notices that are not faults, and failures the player already sees. */
function ignorable(err: unknown, message: string): boolean {
  if (err instanceof ApiError) return err.status === 0 || err.status === 429 || err.status === 401 || err.status === 403 || err.status === 426;
  return /ResizeObserver loop|^Script error\.?$|Load failed$|Failed to fetch$|NetworkError/i.test(message);
}

function flush() {
  timer = null;
  if (sending || queue.length === 0) return;
  // Offline: nothing to tell anyone, and no point keeping it.
  if (typeof navigator !== 'undefined' && navigator.onLine === false) { queue = []; return; }
  const batch = queue.splice(0, BATCH_MAX);
  sending = true;
  api.clientErrors(batch).catch(() => undefined).finally(() => {
    sending = false;
    if (queue.length) schedule();
  });
}

function schedule() {
  if (timer == null) timer = window.setTimeout(flush, FLUSH_MS);
}

/** Queue one report. Safe to call from anywhere, including inside an error handler. */
export function reportError(err: unknown, where = ''): void {
  try {
    const d = describe(err);
    if (ignorable(err, d.message)) return;
    const message = clip(scrub(d.message), MESSAGE_MAX).trim();
    if (!message) return;
    const stack = clip(scrub(d.stack), STACK_MAX).trim();
    const key = message + '|' + topFrame(stack) + '|' + where;
    if (seen.has(key) || accepted >= SESSION_MAX) return;
    seen.add(key);
    accepted++;
    queue.push({
      message: where ? clip(`[${where}] ${message}`, MESSAGE_MAX) : message,
      stack,
      version: CLIENT_VERSION,
      platform: Capacitor.getPlatform(),
      screen: screenOf(),
      ts: Date.now(),
    });
    if (queue.length >= BATCH_MAX) flush(); else schedule();
  } catch { /* reporting must never cause an error of its own */ }
}

/** A native plugin call failed. The player's own refusals and plugins an older build lacks are not faults. */
export function reportPluginError(call: string, e: unknown): void {
  const code = (e as { code?: unknown } | null)?.code;
  const msg = (e as { message?: unknown } | null)?.message;
  const text = typeof msg === 'string' ? msg : '';
  if (code === 'UNIMPLEMENTED' || code === 'UNAVAILABLE' || code === 'location_denied' || code === 'CANCELED') return;
  if (/denied|permission|cancel|timed? ?out|unavailable/i.test(text)) return;
  reportError(new Error(`${call} failed: ${text || String(code ?? 'unknown')}`), 'plugin');
}

/** Catch what escapes everything else. Call once, early. */
export function installErrorReporting(): void {
  window.addEventListener('error', (e) => {
    reportError(e.error ?? new Error(e.message), 'window');
  });
  window.addEventListener('unhandledrejection', (e) => {
    reportError(e.reason, 'promise');
  });
}
