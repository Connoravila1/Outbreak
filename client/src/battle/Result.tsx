import { useEffect, useRef, useState } from 'preact/hooks';
import type { Battle, Item } from '../api';
import { catalog, faction } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { consumableName, itemTitle, perkInfo, SLOT_ICON, statLine, uniqueLore } from '../gear/util';
import * as fx from '../audio/fx';
import { damageTaken, foeLabel, isPvp, outcomeLine, outcomeWord } from './names';
import { stanceName } from '../state/stance';
import type { ContactRank } from '../api';
import { NoteScrap } from '../notes/Scrap';

/** XP position before the fight, as a fraction of that level's bar, and after. */
function xpSpan(b: Battle): { from: number; to: number; gain: number } {
  const r = b.rewards;
  const m = b.me;
  const table = catalog.value?.levels.xp_to_next;
  const next = (lvl: number) => table?.[lvl - 1] ?? m.xp_next;
  let before = m.xp - r.xp;
  let fromLevel = m.level;
  if (r.level_up) {
    fromLevel = r.level_up.from;
    before = m.xp - r.xp;
    for (let l = r.level_up.from; l < r.level_up.to; l++) before += next(l);
  }
  const from = Math.max(0, Math.min(1, before / (next(fromLevel) || 1)));
  const to = r.level_up ? 1 : Math.max(0, Math.min(1, m.xp / (m.xp_next || 1)));
  return { from, to, gain: r.xp };
}

function Counter({ to, fast, suffix = '' }: { to: number; fast: boolean; suffix?: string }) {
  const [v, setV] = useState(fast ? to : 0);
  useEffect(() => {
    if (fast || to <= 0) { setV(to); return; }
    const t0 = performance.now();
    let raf = 0;
    const step = (t: number) => {
      const p = Math.min(1, (t - t0) / 700);
      setV(Math.round(to * (1 - (1 - p) * (1 - p))));
      if (p < 1) raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
  }, [to, fast]);
  return <b class="num">{v}{suffix}</b>;
}

function XpBar({ b, fast }: { b: Battle; fast: boolean }) {
  const { from, to, gain } = xpSpan(b);
  const [w, setW] = useState(from);
  useEffect(() => {
    const t = window.setTimeout(() => { setW(to); if (gain > 0) fx.xpFill(1300); }, 80);
    return () => clearTimeout(t);
  }, []);
  return (
    <div class="res-row">
      <div class="res-line"><span><Icon name="star-medal" size={18} /> XP</span><Counter to={gain} fast={fast} suffix=" XP" /></div>
      <div class="bar xp res-xp" role="progressbar" aria-label="Experience" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(w * 100)}>
        <i class="fill" style={{ width: `${w * 100}%`, transition: 'width 1.3s var(--ease)' }} />
      </div>
      {b.rewards.level_up && <p class="res-lvl voice">{say(`Level ${b.rewards.level_up.to} reached.`, `level ${b.rewards.level_up.to}. stronger.`)}</p>}
    </div>
  );
}

const RANK_AT = [0, 1, 5, 15, 40, 100];

/** Contact rank progress: the bar fills from where the fight found you, and says what is left. */
function RankBar({ b, fast }: { b: Battle; fast: boolean }) {
  const r: ContactRank = b.me.contact_rank;
  const gained = b.kind === 'pvp' && b.winner === 'a' ? 1 : 0;
  const before = r.wins - gained;
  const lo = RANK_AT[r.tier] ?? 0;
  const span = r.next_at != null ? r.next_at - lo : 1;
  // Right after a rank-up the new rank's bar is empty, so show the old one filling to the top instead.
  const rankedUp = gained > 0 && before < lo;
  const prevLo = RANK_AT[Math.max(0, r.tier - 1)] ?? 0;
  const prevSpan = Math.max(1, lo - prevLo);
  const to = rankedUp ? 1 : r.next_at != null ? Math.min(1, (r.wins - lo) / span) : 1;
  const from = rankedUp ? Math.max(0, Math.min(1, (before - prevLo) / prevSpan)) : r.next_at != null ? Math.max(0, (before - lo) / span) : 1;
  const [w, setW] = useState(fast ? to : from);
  useEffect(() => { const t = window.setTimeout(() => setW(to), 120); return () => clearTimeout(t); }, []);
  const name = say(r.name, r.name.toLowerCase());
  const left = r.next_at != null ? r.next_at - r.wins : 0;
  return (
    <div class="res-row res-rank">
      <div class="res-line"><span><Icon name="crossed-swords" size={18} /> {say('Contact rank', 'hunt rank')}</span><b class="rank-name">{name}</b></div>
      <div class="bar xp res-xp" role="progressbar" aria-label="Contact rank" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(w * 100)}>
        <i class="fill" style={{ width: `${w * 100}%`, transition: 'width 1.1s var(--ease)' }} />
      </div>
      <p class="dim rank-line">
        {rankedUp && <b class="rank-up">{say('Rank up! ', 'risen! ')}</b>}
        {r.next_at != null
          ? say(`${r.name} — ${left} more win${left === 1 ? '' : 's'} to ${r.next_name}`, `${name} — ${left} more kill${left === 1 ? '' : 's'} to ${(r.next_name ?? '').toLowerCase()}`)
          : say(`${r.name} — the top rank`, `${name} — the top`)}
      </p>
    </div>
  );
}

/** What they carried, in their own words, tinted by rarity. */
function Carried({ b }: { b: Battle }) {
  const foe = b.b;
  const list = foe.gear_detail ?? [];
  const note = b.b.kind === 'echo'
    ? say("This was an echo of a real player's build. They'll hear how it went.", "an echo of someone real. they will hear how it went.")
    : b.b.kind === 'rogue' ? say('A Rogue: a stand-in build, nobody real.', 'a rogue. nothing real behind it.') : null;
  return (
    <div class="res-row carried">
      <p class="eyebrow dim voice">{say('They carried:', 'it carried:')}</p>
      <ul class="carried-list">
        {list.length === 0 && <li class="dim">{say('Nothing worth naming.', 'nothing.')}</li>}
        {list.map((g) => (
          <li key={g.slot} class={`carried-item rarity-${g.rarity}`}>
            <Icon name={SLOT_ICON[g.slot]} size={18} />
            <b class="c-name">{g.name}</b>
            {g.upgrade > 0 && <span class="num c-up">+{g.upgrade}</span>}
            {g.unique && <span class="c-unique" title="Unique">★</span>}
            <span class="rarity-label c-rar">{g.rarity}</span>
          </li>
        ))}
      </ul>
      {foe.stance && <p class="dim c-stance">{say('Their stance:', 'how it hunted:')} <b>{stanceName(foe.stance, foe.faction)}</b></p>}
      {note && <p class="c-note">{note}</p>}
    </div>
  );
}

function LootCard({ it, flipped, held }: { it: Item; flipped: boolean; held: boolean }) {
  const lore = uniqueLore(it.unique);
  return (
    <div class={`loot ${flipped ? 'flipped' : ''} ${held && !flipped ? 'held' : ''} rarity-${it.rarity}`}>
      <div class="loot-in">
        <div class="loot-face loot-back item-card" aria-hidden={flipped}><Icon name="wooden-crate" size={34} /><span class="dim">{say('Unknown', 'something')}</span></div>
        <div class="loot-face loot-front item-card" aria-hidden={!flipped}>
          <Icon name={SLOT_ICON[it.slot]} size={30} />
          <strong>{itemTitle(it)}</strong>
          <span class="rarity-label">{it.rarity}</span>
          <span class="dim num">{statLine(it.stats)}</span>
          {it.perks.length > 0 && <span class="dim loot-perks">{it.perks.map((p) => perkInfo(p).name).join(', ')}</span>}
          {lore && <em class="lore">“{lore}”</em>}
        </div>
      </div>
    </div>
  );
}

export function Result({ battle, onContinue }: { battle: Battle; onContinue: () => void }) {
  const r = battle.rewards;
  const won = battle.winner === 'a';
  const n = r.items.length;
  const cons = Object.entries(r.consumables);
  const notes = r.notes ?? [];
  // After the gear: found notes get a step of their own.
  const noteStep = 4 + n;
  const final = noteStep + (notes.length ? 1 : 0);
  const [step, setStep] = useState(0);
  const [fast, setFast] = useState(false);
  const btn = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (step >= final) return;
    const nextLegendary = step >= 3 && step < 3 + n && r.items[step - 3].rarity === 'legendary';
    const d = step === 0 ? 650 : step === 1 ? 950 : step === 2 ? 650 : step < 3 + n ? (nextLegendary ? 1500 : 600) : 450;
    const t = window.setTimeout(() => setStep(step + 1), d);
    return () => clearTimeout(t);
  }, [step]);

  useEffect(() => {
    if (step === 0) { if (won) fx.held(); else fx.fell(); return; }
    if (notes.length && step === noteStep) { fx.lootFlip(notes[0].rarity === 'legendary' ? 'rare' : notes[0].rarity); return; }
    const flipped = step - 3; // items flipped so far
    if (step > 3 && flipped >= 1 && flipped <= n) {
      const it = r.items[flipped - 1];
      if (it.rarity === 'legendary') fx.legendary(); else fx.lootFlip(it.rarity);
    }
  }, [step]);

  useEffect(() => { if (step >= final) btn.current?.focus(); }, [step]);

  const skip = () => { setFast(true); setStep(final); };
  const flippedCount = Math.min(n, Math.max(0, step - 3));
  const dmg = damageTaken(battle);
  const f = faction.value;
  const pvp = isPvp(battle);
  return (
    <div class={'result ' + (pvp ? 'pvp-result ' : '') + (won ? 'won' : 'lost')} data-faction={f}>
      <div class="res-scroll scroll" onClick={() => { if (step < final) skip(); }}>
        <p class="eyebrow dim voice">{foeLabel(battle)} · {say('level', 'level')} {battle.b.level}</p>
        <h1 class="res-word display">{outcomeWord(won, battle)}</h1>
        <p class="res-line-1">{outcomeLine(won, dmg, battle)}</p>

        {pvp && <Carried b={battle} />}
        {step >= 1 && <XpBar b={battle} fast={fast} />}
        {step >= 2 && (
          <div class="res-row res-two">
            <div class="res-line"><span><Icon name="recycle" size={18} /> {say('Salvage', 'salvage')}</span><Counter to={r.salvage} fast={fast} /></div>
            <div class="res-line"><span><Icon name="crossed-swords" size={18} /> {say('War points', 'war points')}</span><Counter to={r.war_points} fast={fast} /></div>
          </div>
        )}
        {pvp && step >= 2 && <RankBar b={battle} fast={fast} />}
        {step >= 3 && n > 0 && (
          <div class="loot-grid">
            {r.items.map((it, k) => <LootCard key={it.uid} it={it} flipped={k < flippedCount} held={k === flippedCount && it.rarity === 'legendary'} />)}
          </div>
        )}
        {notes.length > 0 && step >= noteStep && (
          <div class="note-drop">
            <p class="note-drop-h dim voice">{say(notes.length > 1 ? 'Notes found' : 'Note found', 'something was left')}</p>
            {notes.map((nt, k) => <NoteScrap key={nt.id} r={nt} delay={k * 160} />)}
          </div>
        )}
        {step >= final && cons.length > 0 && (
          <ul class="reward-lines res-cons">
            {cons.map(([id, c]) => <li key={id}><Icon name="medical-pack" size={18} /> {consumableName(id)} ×{c}</li>)}
          </ul>
        )}
        {step >= final && !!r.auto_scrapped && <p class="dim res-full">{say(`Pack full: extra gear scrapped for ${r.auto_scrapped} salvage.`, `no room. the extra was torn down for ${r.auto_scrapped} salvage.`)}</p>}
        {step >= final && n === 0 && cons.length === 0 && notes.length === 0 && !r.auto_scrapped && <p class="dim">{say('No drops this time.', 'nothing left to take.')}</p>}
      </div>
      <p class="sr-only" role="status" aria-live="polite">
        {step >= final ? `${outcomeWord(won, battle)}. ${say('Salvage', 'salvage')} ${r.salvage}. ${say('War points', 'war points')} ${r.war_points}.${n ? ` ${n} ${n === 1 ? 'item' : 'items'}: ${r.items.map(itemTitle).join(', ')}.` : ''}` : ''}
      </p>
      <div class="res-foot">
        <button ref={btn} class="btn primary block" onClick={step >= final ? onContinue : skip}>
          {step >= final ? say('Continue', 'continue') : say('Skip', 'skip')}
        </button>
      </div>
    </div>
  );
}
