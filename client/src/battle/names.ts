import type { Battle, Combatant } from '../api';
import { archetypeName } from '../state/objects';
import { say } from '../ui/voice';

/** What to call the opponent. Never a callsign: kind and faction only. */
export function foeLabel(b: Battle): string {
  const foe: Combatant = b.b;
  switch (foe.kind) {
    case 'enemy': return foe.archetype ? archetypeName(foe.archetype, b.a.faction) : foe.name;
    case 'boss': return foe.name;
    case 'echo': return 'Echo';
    case 'rogue': return 'Rogue';
    default: return foe.faction === 'zombie' ? 'A Zombie' : 'A Human';
  }
}

/** A fight against a person (or a copy of one): Contact, Echo, Rogue, a garrison. These get their own stage. */
export function isPvp(b: Battle): boolean {
  return b.kind === 'pvp' || b.kind === 'echo' || b.kind === 'garrison';
}

/** The stamp a ghosted opponent wears, if any. */
export function stampOf(b: Battle): 'ECHO' | 'ROGUE' | null {
  return b.b.kind === 'echo' ? 'ECHO' : b.b.kind === 'rogue' ? 'ROGUE' : null;
}

export function myLabel(b: Battle): string { return b.a.name; }

export function outcomeWord(won: boolean, b?: Battle): string {
  if (b?.kind === 'raid') return won ? say('SLAIN', 'slain') : say('DRIVEN BACK', 'driven back');
  return won ? say('HELD', 'fed') : say('FELL', 'starved');
}

/** Damage dealt to the foe over the whole fight. */
export function damageDealt(b: Battle): number {
  const last = b.turns[b.turns.length - 1];
  return Math.max(0, Math.round(b.b.hp_start - (last ? last.hp_b : b.b.hp_start)));
}

export function outcomeLine(won: boolean, dmg: number, b?: Battle): string {
  if (b?.kind === 'raid') {
    const dealt = damageDealt(b).toLocaleString();
    return say(`You hit it for ${dealt}. Took ${dmg} damage. It counts against the boss.`, `${dealt} torn from it. ${dmg} wounds. the horde remembers.`);
  }
  return won
    ? say(`You held. Took ${dmg} damage.`, `fed. ${dmg} wounds.`)
    : say(`You went down. Took ${dmg} damage.`, `torn open. ${dmg} wounds.`);
}

export function damageTaken(b: Battle): number {
  const last = b.turns[b.turns.length - 1];
  return Math.max(0, Math.round(b.a.hp_start - (last ? last.hp_a : b.a.hp_start)));
}
