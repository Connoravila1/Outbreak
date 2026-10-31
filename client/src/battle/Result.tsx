import { useEffect, useRef, useState } from 'preact/hooks';
import type { Battle, Item } from '../api';
import { catalog, faction } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { consumableName, itemTitle, perkInfo, SLOT_ICON, statLine, uniqueLore } from '../gear/util';
import * as fx from '../audio/fx';
import { damageTaken, foeLabel, outcomeLine, outcomeWord } from './names';

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
  const final = 4 + n;
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
    const flipped = step - 3; // items flipped so far
    if (step > 3 && flipped >= 1 && flipped <= n) {
      const it = r.items[flipped - 1];
      if (it.rarity === 'legendary') fx.legendary(); else fx.lootFlip(it.rarity);
    }
  }, [step]);

  useEffect(() => { if (step >= final) btn.current?.focus(); }, [step]);

  const skip = () => { setFast(true); setStep(final); };
  const flippedCount = Math.max(0, step - 3);
  const dmg = damageTaken(battle);
  const f = faction.value;
  return (
    <div class={'result ' + (won ? 'won' : 'lost')} data-faction={f}>
      <div class="res-scroll scroll" onClick={() => { if (step < final) skip(); }}>
        <p class="eyebrow dim voice">{foeLabel(battle)} · {say('level', 'level')} {battle.b.level}</p>
        <h1 class="res-word display">{outcomeWord(won, battle)}</h1>
        <p class="res-line-1">{outcomeLine(won, dmg, battle)}</p>

        {step >= 1 && <XpBar b={battle} fast={fast} />}
        {step >= 2 && (
          <div class="res-row res-two">
            <div class="res-line"><span><Icon name="recycle" size={18} /> {say('Salvage', 'salvage')}</span><Counter to={r.salvage} fast={fast} /></div>
            <div class="res-line"><span><Icon name="crossed-swords" size={18} /> {say('War points', 'war points')}</span><Counter to={r.war_points} fast={fast} /></div>
          </div>
        )}
        {step >= 3 && n > 0 && (
          <div class="loot-grid">
            {r.items.map((it, k) => <LootCard key={it.uid} it={it} flipped={k < flippedCount} held={k === flippedCount && it.rarity === 'legendary'} />)}
          </div>
        )}
        {step >= final && cons.length > 0 && (
          <ul class="reward-lines res-cons">
            {cons.map(([id, c]) => <li key={id}><Icon name="medical-pack" size={18} /> {consumableName(id)} ×{c}</li>)}
          </ul>
        )}
        {step >= final && !!r.auto_scrapped && <p class="dim res-full">{say(`Pack full: extra gear scrapped for ${r.auto_scrapped} salvage.`, `no room. the extra was torn down for ${r.auto_scrapped} salvage.`)}</p>}
        {step >= final && n === 0 && cons.length === 0 && !r.auto_scrapped && <p class="dim">{say('No drops this time.', 'nothing left to take.')}</p>}
      </div>
      <div class="res-foot">
        <button ref={btn} class="btn primary block" onClick={step >= final ? onContinue : skip}>
          {step >= final ? say('Continue', 'continue') : say('Skip', 'skip')}
        </button>
      </div>
    </div>
  );
}
