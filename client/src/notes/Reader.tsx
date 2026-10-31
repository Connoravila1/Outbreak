import { useEffect, useRef } from 'preact/hooks';
import type { ArchiveNote } from '../api';
import { pushBack } from '../ui/back';
import { trapTab } from '../ui/a11y';
import { Icon } from '../ui/Icon';
import { say } from '../ui/voice';
import { archive, closeReader, reading } from './store';
import { Paper } from './Paper';
import './notes.css';

function Reading({ n }: { n: ArchiveNote }) {
  const ref = useRef<HTMLDivElement>(null);
  const setName = archive.value?.sets.find((s) => s.id === n.set)?.name ?? '';
  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null;
    ref.current?.focus();
    const key = (e: KeyboardEvent) => trapTab(e, ref.current);
    window.addEventListener('keydown', key);
    const unback = pushBack(closeReader);
    return () => { unback(); window.removeEventListener('keydown', key); prev?.focus?.(); };
  }, []);
  return (
    <div class="note-reader" role="dialog" aria-modal="true" aria-label={n.title ?? 'Note'} tabIndex={-1} ref={ref}>
      <header class={'nr-head rarity-' + n.rarity}>
        <div class="nr-titles">
          <p class="nr-set dim voice">{setName}</p>
          <h2 class="nr-title display">{n.title}</h2>
          <p class="nr-meta"><span>{n.author}</span><span class="nr-date num">{n.date}</span></p>
        </div>
        <button class="nr-x" onClick={closeReader} aria-label={say('Close note', 'let go')}><Icon name="cancel" size={26} /></button>
      </header>
      <div class="nr-scroll scroll">
        <Paper n={{ title: n.title ?? '', author: n.author ?? '', date: n.date ?? '', form: n.form ?? 'card', body: n.body ?? '' }} />
        <p class="nr-foot"><span class={'rarity-' + n.rarity}><span class="rarity-label">{n.rarity}</span></span></p>
      </div>
      <div class="nr-actions"><button class="btn primary block" onClick={closeReader}>{say('Put it away', 'let go')}</button></div>
    </div>
  );
}

/** Full-screen reader for a found note, drawn on the paper of its form. */
export function NoteReader() {
  const id = reading.value;
  if (!id) return null;
  const n = archive.value?.notes.find((x) => x.id === id);
  if (!n || n.locked) return null;
  return <Reading key={n.id} n={n} />;
}
