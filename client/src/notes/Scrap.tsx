import type { NoteRef } from '../api';
import { Icon } from '../ui/Icon';
import { say } from '../ui/voice';
import { openNote } from './store';
import './notes.css';

const SET_NAME: Record<string, string> = {
  lantern: 'Project Lantern', starlite: 'The Starlite Diner', ordinary: 'Ordinary People', containment: 'Containment',
  survey: 'The Survey', hunger: 'The Hunger', zero: 'Patient Zero', road: 'Along the Road',
};

/** A found note as a torn scrap: paper and tape for the Survey, a smeared warm fragment for the Turned. Tap to read. */
export function NoteScrap({ r, delay = 0 }: { r: NoteRef; delay?: number }) {
  return (
    <button type="button" class={`scrap rarity-${r.rarity} sf-${r.form}`} style={{ animationDelay: `${delay}ms` }} onClick={() => { void openNote(r.id); }}
      aria-label={`New note: ${r.title}. Read it.`}>
      <i class="scrap-tape" aria-hidden="true" />
      <span class="scrap-eyebrow"><Icon name="scroll-unfurled" size={16} /> {say('New note', 'a scrap')}</span>
      <strong class="scrap-title">{r.title}</strong>
      <span class="scrap-set dim">{SET_NAME[r.set] ?? r.set}</span>
      <span class="rarity-label">{r.rarity}</span>
      <span class="scrap-read">{say('Tap to read', 'tap. read it')}</span>
    </button>
  );
}
