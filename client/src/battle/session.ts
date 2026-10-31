import { computed, signal } from '@preact/signals';
import type { Battle, Me, Rewards } from '../api';
import { applyMe, setBattleHandler } from '../state/store';
import { recordBattle } from '../state/record';
import { pollNow } from '../state/poll';

/** One full-screen thing the player has to get through: a CONTACT + fight, a fight, or a level-up. */
export type Session =
  | { key: number; kind: 'battle'; battle: Battle; contact: boolean; replay: boolean }
  | { key: number; kind: 'levelup'; up: NonNullable<Rewards['level_up']>; me: Me };

export const queue = signal<Session[]>([]);
export const current = computed<Session | null>(() => queue.value[0] ?? null);
let key = 1;

export function battleActive(): boolean { return queue.peek().length > 0; }

/** `replay`: a fight already settled (a Patrol report entry); watching it changes nothing. */
export function enqueueBattle(battle: Battle, contact = false, replay = false) {
  queue.value = [...queue.peek(), { key: key++, kind: 'battle', battle, contact, replay }];
}

/** A level-up that did not come from a fight (mission claim, cache, store). */
export function enqueueLevelUp(up: Rewards['level_up'], me: Me) {
  if (up) queue.value = [...queue.peek(), { key: key++, kind: 'levelup', up, me }];
}

/** Called when the player leaves a fight result. Applies the server's `me`, queues the level-up if any. */
export function finishBattle() {
  const s = queue.peek()[0];
  if (!s) return;
  const rest = queue.peek().slice(1);
  if (s.kind === 'battle' && s.replay) {
    queue.value = rest;
  } else if (s.kind === 'battle') {
    applyMe(s.battle.me);
    recordBattle(s.battle, s.contact);
    const up = s.battle.rewards.level_up;
    queue.value = up ? [{ key: key++, kind: 'levelup', up, me: s.battle.me }, ...rest] : rest;
  } else {
    applyMe(s.me);
    queue.value = rest;
  }
  if (!queue.peek().length) pollNow();
}

// Every fight the app learns about (engage, raid, stronghold, contact) plays back here.
setBattleHandler((b) => enqueueBattle(b, false));
