import type { ComponentChildren } from 'preact';
import type { NoteForm } from '../api';

interface PaperNote { title: string; author: string; date: string; form: NoteForm; body: string }

/** "[handwritten margin] text" and "(handwritten) text" are marginalia; "[handwritten: text]" sits inside a line. */
function inline(line: string): ComponentChildren {
  const tag = /^(?:\[handwritten[^\]:]*\]|\(handwritten\))\s*(.+)$/.exec(line);
  if (tag) return <span class="hw">{tag[1]}</span>;
  const parts = line.split(/(\[handwritten:[^\]]*\])/);
  if (parts.length === 1) return line;
  return parts.map((p, i) => (p.startsWith('[handwritten:')
    ? <span class="hw" key={i}>{p.slice(13, -1).trim()}</span>
    : p));
}

const lines = (body: string) => body.split('\n');

/** Speaker lines ("Name: text") become bubbles; anything else (a [Read ...] line) a centred aside. */
function Chat({ body }: { body: string }) {
  const sides = new Map<string, number>();
  return (
    <div class="np-chat">
      {lines(body).map((l, i) => {
        const m = /^([^:\[]{1,24}): (.+)$/.exec(l);
        if (!m) return <p class="np-aside" key={i}>{l}</p>;
        if (!sides.has(m[1])) sides.set(m[1], sides.size);
        const k = sides.get(m[1])!;
        const prev = i > 0 ? /^([^:\[]{1,24}): /.exec(lines(body)[i - 1])?.[1] : undefined;
        return (
          <div class={'np-msg ' + (k % 2 === 0 ? 'in' : 'out')} key={i}>
            {prev !== m[1] && <span class="np-who">{m[1]}</span>}
            <p class="np-bubble">{m[2]}</p>
          </div>
        );
      })}
    </div>
  );
}

/** Mail headers are the lines at the top that start From:, To: or Subject:. */
function Email({ body }: { body: string }) {
  const all = lines(body);
  const head: string[] = [];
  while (head.length < all.length && /^(From|To|Subject):/.test(all[head.length])) head.push(all[head.length]);
  return (
    <>
      <dl class="np-mailhead">
        {head.map((h, i) => { const [k, ...v] = h.split(':'); return <div key={i}><dt>{k}</dt><dd>{v.join(':').trim()}</dd></div>; })}
      </dl>
      <div class="np-text">{all.slice(head.length).map((l, i) => <p key={i}>{inline(l)}</p>)}</div>
    </>
  );
}

/** Stars on the first line, then the review. */
function Review({ n }: { n: PaperNote }) {
  const all = lines(n.body);
  const stars = /^[★☆]{5}/.exec(all[0])?.[0] ?? '';
  const rest = stars ? all[0].slice(stars.length).trim() : all[0];
  const full = [...stars].filter((c) => c === '★').length;
  return (
    <>
      <p class="np-stars" aria-label={`${full} of 5 stars`}><span aria-hidden="true">{stars}</span> <b>{rest}</b></p>
      <div class="np-text">{all.slice(1).map((l, i) => <p key={i}>{inline(l)}</p>)}</div>
    </>
  );
}

/** Several sticky notes on one wall: "--" on its own line starts the next. */
function Stickies({ body }: { body: string }) {
  const notes = body.split(/\n--\n/);
  return (
    <div class="np-wall">
      {notes.map((t, i) => <div class={'np-stick s' + (i % 3)} key={i}>{lines(t).map((l, j) => <p key={j}>{inline(l)}</p>)}</div>)}
    </div>
  );
}

/** The note's text, drawn on the paper its form calls for. Colours come from the lens. */
export function Paper({ n }: { n: PaperNote }) {
  const f = n.form;
  if (f === 'sticky' && n.body.includes('\n--\n')) {
    return <div class="paper f-sticky multi" data-form="sticky"><Stickies body={n.body} /></div>;
  }
  return (
    <article class={`paper f-${f}`} data-form={f}>
      {f === 'poster' && <><i class="np-tape l" /><i class="np-tape r" /></>}
      {f === 'sticky' && <i class="np-pin" />}
      {f === 'notebook' && <i class="np-holes" />}
      {f === 'memo' && <p class="np-letterhead">{n.author}</p>}
      {f === 'receipt' && <p class="np-ttl">{lines(n.body)[0]}</p>}
      {f === 'chat' && <Chat body={n.body} />}
      {f === 'email' && <Email body={n.body} />}
      {f === 'review' && <Review n={n} />}
      {(f === 'notebook' || f === 'memo' || f === 'radio' || f === 'letter' || f === 'card' || f === 'sticky' || f === 'poster' || f === 'receipt') && (
        <div class="np-text">
          {lines(n.body).slice(f === 'receipt' ? 1 : 0).map((l, i, all) => (
            <p key={i} class={f === 'poster' && i === 0 ? 'np-big' : f === 'letter' && i === all.length - 1 && l.length <= 42 ? 'np-sign' : undefined}>{inline(l)}</p>
          ))}
        </div>
      )}
    </article>
  );
}
