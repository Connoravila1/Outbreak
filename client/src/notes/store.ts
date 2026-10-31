import { computed, signal } from '@preact/signals';
import { api, errorMessage, type ArchiveNote, type NoteArchive, type NoteRef } from '../api';
import { KEYS, storage } from '../api/storage';
import { me } from '../state/store';
import { pushToast } from '../ui/kit';
import { say } from '../ui/voice';

/** The archive as the server last sent it. Null until first needed. */
export const archive = signal<NoteArchive | null>(null);
export const archiveError = signal<string | null>(null);
/** Id of the note open in the reader. */
export const reading = signal<string | null>(null);

const seenIds = signal<Set<string>>(new Set(storage.getJSON<string[]>(KEYS.notesSeen, [])));

export const isSeen = (id: string) => seenIds.value.has(id);

/** Notes found and not yet opened. Exact once the archive is loaded, otherwise counted from Me. */
export const unreadCount = computed(() => {
  const a = archive.value;
  if (a) return a.notes.filter((n) => !n.locked && !seenIds.value.has(n.id)).length;
  return Math.max(0, (me.value?.notes?.found ?? 0) - seenIds.value.size);
});

export function markSeen(id: string) {
  if (seenIds.peek().has(id)) return;
  const next = new Set(seenIds.peek());
  next.add(id);
  seenIds.value = next;
  storage.setJSON(KEYS.notesSeen, [...next]);
}

let loading: Promise<void> | null = null;
export function loadArchive(): Promise<void> {
  if (loading) return loading;
  loading = api.notes().then(
    (a) => { archive.value = a; archiveError.value = null; },
    (e) => { archiveError.value = errorMessage(e); },
  ).finally(() => { loading = null; });
  return loading;
}

export const noteById = (id: string): ArchiveNote | undefined => archive.peek()?.notes.find((n) => n.id === id);

/** Open the reader on a note, fetching the archive first if it does not hold the text yet. */
export async function openNote(id: string) {
  let n = noteById(id);
  if (!n || n.locked) { await loadArchive(); n = noteById(id); }
  if (!n || n.locked) return;
  markSeen(id);
  reading.value = id;
}

export function closeReader() { reading.value = null; }

/** Notes just found: refresh the archive in the background. Outside a fight, say so in a toast. */
export function notesFound(refs: NoteRef[] | undefined, toast = false) {
  if (!refs?.length) return;
  archive.value = null;
  void loadArchive();
  if (!toast) return;
  const r = refs[0];
  pushToast(say(`New note: ${r.title}`, `a scrap, still warm: ${r.title}`), 'good', () => { void openNote(r.id); });
}
