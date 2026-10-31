import { lens } from '../state/store';

/** Pick copy by lens: Survey is terse field notes, Heat is lowercase and sensory. */
export function say(survey: string, heat: string): string {
  return lens.value === 'heat' ? heat : survey;
}
