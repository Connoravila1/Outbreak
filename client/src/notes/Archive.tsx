import { useEffect, useState } from 'preact/hooks';
import { api, errorMessage, type NoteSet } from '../api';
import { applyMe, me } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { Action, ErrorLine, Meter, pushToast, Section } from '../ui/kit';
import { showRewards } from '../ui/RewardsSheet';
import { claim as claimSound } from '../audio/fx';
import { archive, archiveError, isSeen, loadArchive, openNote, unreadCount } from './store';
import './notes.css';

function SetRow({ s, open, onToggle }: { s: NoteSet; open: boolean; onToggle: () => void }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const notes = (archive.value?.notes ?? []).filter((n) => n.set === s.id);
  const done = s.found === s.total;
  const sealed = s.id === 'zero' && s.found === 0;
  const unread = notes.filter((n) => !n.locked && !isSeen(n.id)).length;

  const claim = async () => {
    setBusy(true); setErr(null);
    try {
      const r = await api.claimNotes(s.id);
      applyMe(r.me);
      claimSound();
      showRewards(say(`${s.name}: complete`, `${s.name.toLowerCase()}: whole`), r.rewards);
      pushToast(say(`Title earned: ${r.title}`, `a name, earned: ${r.title.toLowerCase()}`), 'good');
      void loadArchive();
    } catch (e) {
      setErr(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <li class={'card set-row' + (done ? ' done' : '') + (sealed ? ' sealed' : '')}>
      <button type="button" class="set-head" aria-expanded={open} onClick={sealed ? undefined : onToggle} disabled={sealed}>
        <Icon name={sealed ? 'padlock' : 'scroll-unfurled'} size={22} />
        <span class="set-main">
          <b class="set-name">{sealed ? '???' : s.name}</b>
          <small class="dim">{sealed ? say('Sealed. Something has to be found first.', 'sealed. not yet.') : s.blurb}</small>
        </span>
        {unread > 0 && <span class="udot" role="img" aria-label={`${unread} unread`} />}
        <span class="num set-count">{s.found}/{s.total}</span>
      </button>
      <Meter value={s.found} max={s.total} label={`${s.name} found`} kind="plain" />
      {done && !s.claimed && (
        <div class="set-claim">
          <Action id={'claim-' + s.id} primary block busy={busy} onClick={() => { void claim(); }}>
            {say(`Claim ${s.title} · +${s.reward} salvage`, `take the name · +${s.reward} salvage`)}
          </Action>
        </div>
      )}
      {done && s.claimed && <p class="set-title dim"><Icon name="laurels" size={16} /> {s.title}</p>}
      <ErrorLine text={err} />
      {open && !sealed && (
        <ul class="note-list">
          {notes.map((n) => n.locked ? (
            <li class={'note-row locked rarity-' + n.rarity} key={n.id}>
              <Icon name="padlock" size={16} /> <span class="nr-q">???</span> <span class="rarity-label">{n.rarity}</span>
            </li>
          ) : (
            <li key={n.id}>
              <button type="button" class={'note-row rarity-' + n.rarity} onClick={() => { void openNote(n.id); }}>
                <span class="nr-main"><b>{n.title}</b><small class="dim">{n.author} · {n.date}</small></span>
                {!isSeen(n.id) && <span class="udot" role="img" aria-label="unread" />}
                <span class="rarity-label">{n.rarity}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </li>
  );
}

/** Found notes by set: progress, the silhouettes still to find, claim buttons. */
export function Archive() {
  const [openSet, setOpenSet] = useState<string | null>(null);
  useEffect(() => { void loadArchive(); }, []);
  const a = archive.value;
  const tally = me.value?.notes;
  const unread = unreadCount.value;
  return (
    <Section title={say('Archive', 'what was left')} aside={<>{unread > 0 && <span class="udot" role="img" aria-label={`${unread} unread`} />}{tally ? `${tally.found}/${tally.total}` : ''}</>}>
      <ErrorLine text={archiveError.value} />
      {!a && !archiveError.value && <p class="empty dim">…</p>}
      {a && (a.notes.every((n) => n.locked)) && (
        <p class="empty">{say('Nothing found yet. Caches, places and the fallen sometimes hold a page.', 'nothing yet. the fallen keep things.')}</p>
      )}
      {a && (
        <ul class="sets">
          {a.sets.map((s) => <SetRow key={s.id} s={s} open={openSet === s.id} onToggle={() => setOpenSet(openSet === s.id ? null : s.id)} />)}
        </ul>
      )}
    </Section>
  );
}
