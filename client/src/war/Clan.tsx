import { useEffect, useRef, useState } from 'preact/hooks';
import { api, errorMessage, type ClanDetail, type ClanMessage, type ClanSummary } from '../api';
import { applyMe, faction, me } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { Action, ErrorLine, pushToast, Section } from '../ui/kit';
import { ago, usePoll } from '../ui/hooks';
import { Callsign } from '../ui/Callsign';

const CLAN_LEVEL = 10;
const CREATE_COST = 500;
const MAX_MEMBERS = 50;
const CHAT_MAX = 200;

function perkLines(p: ClanDetail['perks']): string[] {
  const out: string[] = [];
  if (p && typeof p === 'object' && typeof p.xp_bonus === 'number' && p.xp_bonus > 0) {
    out.push(say(`+${Math.round(p.xp_bonus * 100)}% XP for every member`, `+${Math.round(p.xp_bonus * 100)}% xp for the whole pack`));
  }
  return out;
}

// ---------- no clan yet ----------
function Browse() {
  const m = me.value!;
  const [q, setQ] = useState('');
  const [list, setList] = useState<ClanSummary[] | null>(null);
  const [code, setCode] = useState('');
  const [name, setName] = useState('');
  const [tag, setTag] = useState('');
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let live = true;
    const t = window.setTimeout(() => {
      api.clans(q.trim()).then((r) => { if (live) setList(r.clans); }, (e) => { if (live) setErr(errorMessage(e)); });
    }, q ? 300 : 0);
    return () => { live = false; clearTimeout(t); };
  }, [q]);

  const join = async (key: string, target: { id: string } | { code: string }) => {
    setBusy(key); setErr(null);
    try { const r = await api.joinClan(target); applyMe(r.me); pushToast(say(`Joined ${r.clan.name}.`, `you run with ${r.clan.name}.`), 'good'); }
    catch (e) { setErr(errorMessage(e)); } finally { setBusy(null); }
  };
  const create = async () => {
    setBusy('create'); setErr(null);
    try { const r = await api.createClan(name.trim(), tag.trim().toUpperCase()); applyMe(r.me); pushToast(say(`${r.clan.name} founded.`, `${r.clan.name} rises.`), 'good'); }
    catch (e) { setErr(errorMessage(e)); } finally { setBusy(null); }
  };

  const nameOk = name.trim().length >= 3;
  const tagOk = /^[A-Za-z0-9]{2,4}$/.test(tag.trim());
  const createReason = m.salvage < CREATE_COST ? say(`Need ${CREATE_COST - m.salvage} more salvage (costs ${CREATE_COST}).`, `${CREATE_COST - m.salvage} more salvage. it costs ${CREATE_COST}.`)
    : !nameOk ? say('Name needs at least 3 characters.', 'a name, 3 letters at least.')
    : !tagOk ? say('Tag is 2 to 4 letters or numbers.', 'tag: 2 to 4 letters.') : null;

  return (
    <>
      <p class="dim">{say('You are not in a clan. Find one or start your own.', 'you run alone. find a pack or make one.')}</p>
      <label class="dim lab" for="clan-q">{say('Search clans', 'search')}</label>
      <input id="clan-q" class="field" value={q} placeholder={say('Name or tag', 'name or tag')} onInput={(e) => setQ((e.target as HTMLInputElement).value)} />
      {list && list.length === 0 && <p class="empty">{say('No clans match.', 'none found.')}</p>}
      <ul class="clan-list">
        {(list ?? []).map((c) => {
          const wrong = c.faction !== faction.value;
          const full = c.members >= MAX_MEMBERS;
          const reason = wrong ? say(`${c.faction === 'human' ? 'Human' : 'Zombie'} clan.`, `${c.faction === 'human' ? 'living' : 'dead'} clan.`) : full ? say('Full.', 'full.') : null;
          return (
            <li key={c.id} class="card clan-row">
              <div class="cl-main">
                <b><span class="tag">[{c.tag}]</span> {c.name}</b>
                <span class="dim num">{c.members} / {MAX_MEMBERS} · {say('level total', 'combined level')} {c.level_sum}</span>
              </div>
              <Action id={'why-join-' + c.id} reason={reason} busy={busy === c.id} onClick={() => join(c.id, { id: c.id })}>Join</Action>
            </li>
          );
        })}
      </ul>

      <h4 class="sub-h display">{say('Invite code', 'invite')}</h4>
      <div class="row-gap">
        <input class="field" aria-label="Invite code" value={code} placeholder="CODE" autocapitalize="characters" onInput={(e) => setCode((e.target as HTMLInputElement).value)} />
        <Action id="why-code" reason={code.trim() ? null : say('Enter a code.', 'a code first.')} busy={busy === 'code'} onClick={() => join('code', { code: code.trim().toUpperCase() })}>Join</Action>
      </div>

      <h4 class="sub-h display">{say('Start a clan', 'make a pack')}</h4>
      <div class="create-form">
        <input class="field" aria-label="Clan name" value={name} maxLength={24} placeholder={say('Clan name', 'name')} onInput={(e) => setName((e.target as HTMLInputElement).value)} />
        <input class="field tag-in" aria-label="Clan tag" value={tag} maxLength={4} placeholder="TAG" onInput={(e) => setTag((e.target as HTMLInputElement).value.toUpperCase())} />
      </div>
      <Action id="why-create" block reason={createReason} busy={busy === 'create'} onClick={create}>
        {say('Create clan', 'Create clan')}<span class="cost num"><Icon name="recycle" size={16} />{CREATE_COST}</span>
      </Action>
      <ErrorLine text={err} />
    </>
  );
}

// ---------- chat ----------
function Chat() {
  const [msgs, setMsgs] = useState<ClanMessage[]>([]);
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const box = useRef<HTMLUListElement>(null);
  const fetchChat = () => { api.clanChat().then((r) => setMsgs(r.messages), () => undefined); };
  usePoll(fetchChat, 10000);
  useEffect(() => { box.current?.scrollTo({ top: box.current.scrollHeight }); }, [msgs.length]);
  const send = async (e: Event) => {
    e.preventDefault();
    if (!text.trim()) return;
    setBusy(true); setErr(null);
    try { setMsgs((await api.sendClanChat(text.trim())).messages); setText(''); }
    catch (ex) { setErr(errorMessage(ex)); } finally { setBusy(false); }
  };
  const mine = me.value?.callsign;
  return (
    <Section title={say('Clan chat', 'the pack speaks')}>
      <ul class="chat" ref={box} aria-live="polite" aria-label="Clan chat">
        {msgs.length === 0 && <li class="empty dim">{say('Quiet. Say something.', 'quiet.')}</li>}
        {msgs.map((m) => (
          <li key={m.id} class={'msg' + (m.callsign === mine ? ' mine' : '')}>
            <span class="msg-h"><b><Callsign name={m.callsign} color={m.callsign_color} /></b> <span class="dim">{ago(m.at)}</span></span>
            <span class="msg-t">{m.text}</span>
          </li>
        ))}
      </ul>
      <form class="chat-form" onSubmit={send}>
        <input class="field" aria-label="Message" value={text} maxLength={CHAT_MAX} placeholder={say('Message', 'say it')} onInput={(e) => setText((e.target as HTMLInputElement).value)} />
        <button class="btn primary" disabled={busy || !text.trim()} aria-disabled={busy || !text.trim()} type="submit" aria-label="Send"><Icon name="chat-bubble" size={22} /></button>
      </form>
      <p class="dim chat-count num">{text.length} / {CHAT_MAX}</p>
      <ErrorLine text={err} />
    </Section>
  );
}

// ---------- your clan ----------
function Page() {
  const [clan, setClan] = useState<ClanDetail | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [leaving, setLeaving] = useState(false);
  const [busy, setBusy] = useState(false);
  const mine = me.value?.callsign;
  usePoll(() => { api.clan().then((r) => setClan(r.clan), (e) => setErr(errorMessage(e))); }, 30000);
  const copy = () => { void navigator.clipboard?.writeText(clan!.code).then(() => { setCopied(true); setTimeout(() => setCopied(false), 1800); }, () => undefined); };
  const leave = async () => {
    setBusy(true);
    try { applyMe((await api.leaveClan()).me); } catch (e) { setErr(errorMessage(e)); setBusy(false); }
  };
  if (!clan) return err ? <ErrorLine text={err} /> : <p class="empty dim">…</p>;
  const perks = perkLines(clan.perks);
  return (
    <>
      <div class="card clan-head">
        <h3 class="display clan-name"><span class="tag">[{clan.tag}]</span> {clan.name}</h3>
        <div class="code-row">
          <span class="dim">{say('Invite code', 'invite')}</span>
          <b class="code num">{clan.code}</b>
          <button class="btn" onClick={copy}><Icon name="scroll-unfurled" size={20} />{copied ? say('Copied', 'copied') : say('Copy', 'copy')}</button>
        </div>
        <p class="dim"><Icon name="castle" size={16} /> {clan.strongholds} {say(clan.strongholds === 1 ? 'stronghold held' : 'strongholds held', clan.strongholds === 1 ? 'held ground' : 'held grounds')}</p>
        <ul class="perk-list">
          {perks.length === 0 ? <li class="dim">{say('No perks yet. Hold adjacent strongholds.', 'no gifts yet. hold ground side by side.')}</li> : perks.map((p) => <li key={p}>{p}</li>)}
        </ul>
      </div>
      <Section title={say('Roster', 'the pack')} aside={`${clan.members.length} / ${MAX_MEMBERS}`}>
        <ul class="roster">
          {clan.members.map((mb) => (
            <li key={mb.callsign} class={'card member' + (mb.callsign === mine ? ' me' : '')}>
              <span class="rk-main">
                <b class="rk-name"><Callsign name={mb.callsign} color={mb.callsign_color} />{mb.callsign === mine ? ` (${say('you', 'you')})` : ''}</b>
                <span class="dim">{say('Level', 'level')} {mb.level} · {mb.title}</span>
              </span>
              <span class="role label-tape">{mb.role}</span>
              <span class="rk-val num">{mb.weekly_points}<small> pts</small></span>
            </li>
          ))}
        </ul>
      </Section>
      <Chat />
      <div class="leave">
        {leaving ? (
          <div class="confirm">
            <p>{say('Leave this clan? You can rejoin with its code.', 'leave the pack? the code gets you back.')}</p>
            <div class="confirm-row">
              <button class="btn" onClick={() => setLeaving(false)}>{say('Stay', 'stay')}</button>
              <button class="btn danger" disabled={busy} onClick={leave}>{busy ? '…' : say('Leave', 'leave')}</button>
            </div>
          </div>
        ) : <button class="btn danger block" onClick={() => setLeaving(true)}><Icon name="exit-door" size={20} />{say('Leave clan', 'leave')}</button>}
        <ErrorLine text={err} />
      </div>
    </>
  );
}

export function ClanSection() {
  const m = me.value;
  if (!m) return null;
  return (
    <Section title={say('Clan', 'pack')}>
      {m.level < CLAN_LEVEL ? (
        <div class="card locked-card">
          <Icon name="three-friends" size={30} />
          <p>{say(`Clans unlock at level ${CLAN_LEVEL}. You are level ${m.level}. Join up to 50 others of your side, hold strongholds, and talk.`, `packs open at level ${CLAN_LEVEL}. you are ${m.level}. up to 50 of your kind. held ground. a voice.`)}</p>
        </div>
      ) : m.clan ? <Page key={m.clan.id} /> : <Browse />}
    </Section>
  );
}
