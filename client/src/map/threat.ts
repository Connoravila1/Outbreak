export type Threat = 'easy' | 'even' | 'dangerous' | 'deadly';

/** Threat read of a level-`enemy` opponent against a level-`mine` player. */
export function threatOf(enemy: number, mine: number): Threat {
  const d = enemy - mine;
  return d <= -2 ? 'easy' : d <= 1 ? 'even' : d <= 3 ? 'dangerous' : 'deadly';
}

export const THREAT_WORD: Record<Threat, string> = {
  easy: 'Easy', even: 'Even', dangerous: 'Dangerous', deadly: 'Deadly',
};
export const THREAT_WORD_HEAT: Record<Threat, string> = {
  easy: 'soft', even: 'warm', dangerous: 'fierce', deadly: 'burning',
};
