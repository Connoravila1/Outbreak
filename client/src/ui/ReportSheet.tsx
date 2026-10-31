import { useState } from 'preact/hooks';
import { api, ApiError, errorMessage, type ReportKind, type ReportReason } from '../api';
import { isHidden, reportTarget, setHidden, hiddenChat } from '../state/moderation';
import { Sheet } from './Sheet';
import { ErrorLine } from './kit';
import { say } from './voice';
import './report.css';

const NOTE_MAX = 140;

/** What can be said about each kind of target. Cheating only makes sense for a person. */
function reasons(kind: ReportKind): { id: ReportReason; text: string; heat: string }[] {
  if (kind === 'player') return [
    { id: 'name', text: 'Offensive name', heat: 'a vile name' },
    { id: 'harassment', text: 'Harassment', heat: 'harassment' },
    { id: 'cheating', text: 'Cheating', heat: 'cheating' },
    { id: 'other', text: 'Something else', heat: 'something else' },
  ];
  if (kind === 'clan') return [
    { id: 'name', text: 'Offensive name or tag', heat: 'a vile name or tag' },
    { id: 'other', text: 'Something else', heat: 'something else' },
  ];
  return [
    { id: 'harassment', text: 'Harassment or abuse', heat: 'harassment or abuse' },
    { id: 'other', text: 'Something else', heat: 'something else' },
  ];
}

const KIND_NOUN: Record<ReportKind, string> = { player: 'player', clan: 'clan', message: 'message' };

function Form({ onSent }: { onSent: (already: boolean) => void }) {
  const t = reportTarget.value!;
  const options = reasons(t.kind);
  const [reason, setReason] = useState<ReportReason | null>(null);
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const send = async (e: Event) => {
    e.preventDefault();
    if (!reason) return;
    setBusy(true); setErr(null);
    try {
      await api.report(t.kind, t.id, reason, note.trim() || undefined);
      onSent(false);
    } catch (ex) {
      if (ex instanceof ApiError && ex.code === 'already_reported') onSent(true);
      else setErr(errorMessage(ex));
    } finally { setBusy(false); }
  };

  return (
    <form onSubmit={send}>
      <h3 class="display rp-title">{say('Report', 'report')} {KIND_NOUN[t.kind]}</h3>
      <p class="rp-target num">{t.label}</p>
      <fieldset class="rp-reasons">
        <legend class="dim">{say('What is wrong?', 'what is wrong?')}</legend>
        {options.map((o) => (
          <label key={o.id} class="rp-reason">
            <input type="radio" name="report-reason" checked={reason === o.id} onChange={() => setReason(o.id)} />
            <span>{say(o.text, o.heat)}</span>
          </label>
        ))}
      </fieldset>
      <label class="dim lab" for="report-note">{say('Anything to add? (optional)', 'anything to add? (optional)')}</label>
      <textarea id="report-note" class="field rp-note" rows={3} maxLength={NOTE_MAX} value={note}
        onInput={(e) => setNote((e.target as HTMLTextAreaElement).value)} />
      <p class="dim rp-count num">{note.length} / {NOTE_MAX}</p>
      <ErrorLine text={err} />
      <div class="rp-actions">
        <button class="btn" type="button" onClick={() => { reportTarget.value = null; }}>{say('Cancel', 'cancel')}</button>
        <button class="btn primary" type="submit" disabled={!reason || busy}>{busy ? '…' : say('Send report', 'send report')}</button>
      </div>
    </form>
  );
}

function Sent({ already }: { already: boolean }) {
  const t = reportTarget.value!;
  void hiddenChat.value;
  const who = t.callsign;
  return (
    <div class="rp-sent">
      <h3 class="display rp-title">{already ? say('Already reported', 'already told') : say('Report sent', 'told')}</h3>
      <p>{already ? say('You reported this already. It is waiting to be reviewed.', 'you already told them. it waits to be read.') : say('Thank you. The person running this server will look at it.', 'thank you. whoever keeps this place will read it.')}</p>
      {who && (
        <label class="toggle-row rp-hide">
          <span class="tg-text">
            <span>{say('Hide their messages', 'hide their messages')}</span>
            <small class="dim">{say(`Clan chat from ${who} stays hidden on this phone.`, `${who} goes quiet on this phone.`)}</small>
          </span>
          <input type="checkbox" checked={isHidden(who)} onChange={(e) => setHidden(who, (e.target as HTMLInputElement).checked)} />
        </label>
      )}
      <button class="btn primary block" onClick={() => { reportTarget.value = null; }}>{say('Done', 'done')}</button>
    </div>
  );
}

function Body() {
  const [sent, setSent] = useState<null | { already: boolean }>(null);
  return sent ? <Sent already={sent.already} /> : <Form onSent={(already) => setSent({ already })} />;
}

/** One sheet for all reports; open it with `openReport`. */
export function ReportSheet() {
  const t = reportTarget.value;
  if (!t) return null;
  return (
    <Sheet key={t.kind + t.id} title={`Report ${KIND_NOUN[t.kind]}`} onClose={() => { reportTarget.value = null; }}>
      <Body />
    </Sheet>
  );
}

/** The small "Report" control that sits at the end of a row. */
export function ReportButton({ label, onClick }: { label: string; onClick: () => void }) {
  return <button class="rep-btn" type="button" aria-label={`Report ${label}`} onClick={onClick}>{say('Report', 'report')}</button>;
}
