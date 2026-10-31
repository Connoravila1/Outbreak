import { signal } from '@preact/signals';
import { KEYS, storage, type Banned, type ReportKind } from '../api';

/** Set when the server answers 403 `banned`; the app shows the suspension screen instead of the game. */
export const banned = signal<Banned | null>(null);

/** What the report sheet is open for. */
export interface ReportTarget {
  kind: ReportKind;
  /** Callsign for a player, clan id for a clan, message id for a message. */
  id: string;
  /** Shown in the sheet title: the callsign, "[TAG] name", or the author of the message. */
  label: string;
  /** Whose clan chat messages "Hide their messages" hides (players and messages). */
  callsign?: string;
}
/** Null when the report sheet is closed. */
export const reportTarget = signal<ReportTarget | null>(null);
export const openReport = (t: ReportTarget) => { reportTarget.value = t; };

// ---- hidden chat: a local filter, never sent to the server ----
const key = (callsign: string) => callsign.toLowerCase();
export const hiddenChat = signal<string[]>(storage.getJSON<string[]>(KEYS.hiddenChat, []));

export function isHidden(callsign: string): boolean { return hiddenChat.value.includes(key(callsign)); }

export function setHidden(callsign: string, hide: boolean) {
  const rest = hiddenChat.value.filter((c) => c !== key(callsign));
  hiddenChat.value = hide ? [...rest, key(callsign)] : rest;
  storage.setJSON(KEYS.hiddenChat, hiddenChat.value);
}

export function showAllChat() {
  hiddenChat.value = [];
  storage.setJSON(KEYS.hiddenChat, []);
}
