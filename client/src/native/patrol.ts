import { registerPlugin } from '@capacitor/core';
import { signal } from '@preact/signals';
import { getServerUrl, getToken, storage } from '../api';
import { isNative } from './platform';

/**
 * Patrol mode (native only): a background service posts a light check-in to /api/patrol so the
 * player stays in the world with the app closed. Results arrive as notifications.
 * The plugin lives in android/.../PatrolPlugin.java and ios/App/App/PatrolPlugin.swift.
 */
export interface PatrolStatus {
  active: boolean;
  /** Epoch ms when patrol ends by itself; 0 when it runs until stopped. */
  endsAt: number;
  intervalSec: number;
  /** Epoch ms of the last accepted check-in; 0 if none yet. */
  lastCheckIn: number;
  lastError: string;
  fineLocation: boolean;
  /** "Allow all the time" (Android) / "Always" (iOS). */
  backgroundLocation: boolean;
  notifications: boolean;
}

interface PatrolPlugin {
  start(o: { serverUrl: string; token: string; intervalSec?: number; durationSec?: number }): Promise<PatrolStatus>;
  stop(): Promise<PatrolStatus>;
  status(): Promise<PatrolStatus>;
  requestBackground(): Promise<PatrolStatus>;
  openSettings(): Promise<void>;
}

const Patrol = registerPlugin<PatrolPlugin>('Patrol');

/** The last status the phone reported (null until first read, and always null on the web). */
export const patrolStatus = signal<PatrolStatus | null>(null);

/** Patrol needs the phone app: a browser has no background location. */
export const patrolAvailable = isNative;

/** Seconds between check-ins. 60 by default; `VITE_PATROL_INTERVAL_SEC` at build time or the
 *  `outbreak.patrol.interval` storage key (e.g. 15 while testing) override it. */
export function patrolIntervalSec(): number {
  const stored = Number(storage.get('outbreak.patrol.interval'));
  const env = Number(import.meta.env.VITE_PATROL_INTERVAL_SEC);
  const v = stored > 0 ? stored : env > 0 ? env : 60;
  return Math.max(10, Math.min(600, Math.round(v)));
}

const quiet = <T>(p: Promise<T>): Promise<T | null> => p.catch(() => null);

export async function refreshPatrol(): Promise<PatrolStatus | null> {
  if (!isNative) return null;
  const s = await quiet(Patrol.status());
  if (s) patrolStatus.value = s;
  return s;
}

/** Start patrolling for `durationSec` seconds (0 = until stopped). Throws a readable message on failure. */
export async function startPatrol(durationSec: number): Promise<PatrolStatus> {
  const token = getToken();
  const serverUrl = getServerUrl();
  if (!token || !serverUrl) throw new Error('Sign in and set a server address first.');
  try {
    const s = await Patrol.start({ serverUrl, token, intervalSec: patrolIntervalSec(), durationSec });
    patrolStatus.value = s;
    return s;
  } catch (e) {
    const msg = (e as { message?: string }).message;
    throw new Error(msg || 'Patrol could not start.');
  }
}

export async function stopPatrol(): Promise<void> {
  if (!isNative) return;
  const s = await quiet(Patrol.stop());
  if (s) patrolStatus.value = s;
}

/** Ask for "Allow all the time" / "Always". Resolves to the status afterwards. */
export async function requestBackgroundLocation(): Promise<PatrolStatus | null> {
  if (!isNative) return null;
  const s = await quiet(Patrol.requestBackground());
  if (s) patrolStatus.value = s;
  return s ?? (await refreshPatrol());
}

export function openPatrolSettings() { void quiet(Patrol.openSettings()); }
