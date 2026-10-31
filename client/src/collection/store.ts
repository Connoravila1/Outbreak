import { signal } from '@preact/signals';
import { api, errorMessage, type AchievementList, type Collection, type EarnedAchievement } from '../api';
import { pushToast } from '../ui/kit';
import { say } from '../ui/voice';

/** The achievement list and the collection log, as the server last sent them. Null until first needed. */
export const achievementList = signal<AchievementList | null>(null);
export const collection = signal<Collection | null>(null);
export const collectionError = signal<string | null>(null);

let loading: Promise<void> | null = null;
/** (Re)load both lists. Cheap; called when the log opens and after anything is earned. */
export function loadCollection(): Promise<void> {
  if (loading) return loading;
  loading = Promise.all([api.achievements(), api.collection()]).then(
    ([a, c]) => { achievementList.value = a; collection.value = c; collectionError.value = null; },
    (e) => { collectionError.value = errorMessage(e); },
  ).finally(() => { loading = null; });
  return loading;
}

/** Ids already announced this session, so one reaching us twice (response and poll) toasts once. */
const announced = new Set<string>();

/** Achievements just earned: say so in a toast each, and refresh the list if it is open. */
export function achievementsEarned(list: EarnedAchievement[] | undefined) {
  const fresh = (list ?? []).filter((a) => !announced.has(a.id));
  if (!fresh.length) return;
  for (const a of fresh) {
    announced.add(a.id);
    const title = a.title ? say(` · title: ${a.title}`, ` · a name: ${a.title.toLowerCase()}`) : '';
    pushToast(say(`Achievement: ${a.name} · +${a.salvage} salvage${title}`, `earned: ${a.name.toLowerCase()} · +${a.salvage} salvage${title}`), 'good');
  }
  if (achievementList.peek()) { achievementList.value = null; void loadCollection(); }
}
