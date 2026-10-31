import { useEffect, useRef, useState } from 'preact/hooks';
import type { Battle, Combatant, Turn } from '../api';
import { reducedMotion, lens } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { abilityName } from '../gear/util';
import * as fx from '../audio/fx';
import * as pvpFx from '../audio/pvp';
import { foeLabel, isPvp, myLabel } from './names';
import { stanceName } from '../state/stance';
import './stance.css';
import './pvp.css';
import { Emblem, type Impact, type Side } from './Emblem';
import { PvpArena, type Flash } from './PvpStage';

const TURN_MS = 600;
/** How long after the lunge starts the blow lands (impact, number, sound). */
const LAND_MS = 130;
/** A fight against a person: the opening (the lens tears in, the figures arrive), and the beats that make it heavier. */
const INTRO_MS = 2700;
const INTRO_REDUCED_MS = 700;
/** Extra time held after a crit so the slow-motion beat can be read. */
const CRIT_HOLD_MS = 480;
const FINAL_HOLD_MS = 1900;
/** Below this share of HP either side makes the heartbeat quicken. */
const LOW_HP = 0.3;

type FloatKind = 'hit' | 'crit' | 'dodge' | 'heal' | 'dot';
interface Float { id: number; side: Side; text: string; tag: string | null; kind: FloatKind; slot: number }
interface Banner { side: Side; text: string; n: number }

function hpOf(b: Battle, i: number, side: Side): number {
  if (i === 0) return side === 'a' ? b.a.hp_start : b.b.hp_start;
  const t = b.turns[i - 1];
  return side === 'a' ? t.hp_a : t.hp_b;
}

/** Compact card: who, how healthy. The fighting happens on the stage, not here. */
function Card({ side, who, label, you, hp }: { side: Side; who: Combatant; label: string; you: boolean; hp: number }) {
  const pct = Math.max(0, Math.min(100, (hp / who.max_hp) * 100));
  return (
    <div class={`fighter side-${side} card`} data-faction={who.faction}>
      <div class="f-head">
        <h2 class="display f-name voice">{label}</h2>
        {you && <span class="label-tape">{say('You', 'you')}</span>}
        <span class="f-meta dim">{say('Level', 'level')} {who.level}</span>
      </div>
      {(who.title || who.gear.length > 0) && (
        <p class="f-gear dim">{[who.title, ...who.gear].filter(Boolean).join(' · ')}</p>
      )}
      <div class="f-barrow">
        <div class="bar f-bar" role="progressbar" aria-label={`${label} health`} aria-valuemin={0} aria-valuemax={who.max_hp} aria-valuenow={Math.round(hp)}>
          <i class="trail" style={{ width: `${pct}%` }} />
          <i class="fill" style={{ width: `${pct}%` }} />
        </div>
        <p class="f-hp num">{Math.round(hp)}<small> / {who.max_hp}</small></p>
      </div>
    </div>
  );
}

function Floats({ list }: { list: Float[] }) {
  return (
    <div class="floats" aria-hidden="true">
      {list.map((f) => (
        <span key={f.id} class={'float ' + f.kind} style={{ '--slot': f.slot }}>
          <b>{f.text}</b>
          {f.tag && <i>{f.tag}</i>}
        </span>
      ))}
    </div>
  );
}

/** Plays `battle.turns` at ~600 ms a blow. Calls onDone when the last blow has landed or the player skips. */
export function Fight({ battle, onDone }: { battle: Battle; onDone: () => void }) {
  const { turns } = battle;
  const heat = lens.value === 'heat';
  const pvp = isPvp(battle);
  const [i, setI] = useState(0);
  const [ready, setReady] = useState(!pvp);
  const [reveal, setReveal] = useState(0);
  const [floats, setFloats] = useState<Float[]>([]);
  const [banner, setBanner] = useState<Banner | null>(null);
  const [impact, setImpact] = useState<Record<Side, Impact | null>>({ a: null, b: null });
  const [flash, setFlash] = useState<Flash | null>(null);
  const [slow, setSlow] = useState<Side | null>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  const stageRef = useRef<HTMLDivElement>(null);
  const timers = useRef<number[]>([]);
  const ids = useRef(1);
  const live = useRef(true);
  const heart = useRef<fx.Heart | null>(null);
  const myFaction = battle.a.faction;

  useEffect(() => {
    if (!pvp) fx.engage();
    return () => { live.current = false; timers.current.forEach(clearTimeout); heart.current?.stop(); heart.current = null; };
  }, []);

  // The opening of a fight against a person: the sting as the lenses meet, then their gear shows up piece by piece.
  useEffect(() => {
    if (!pvp) return;
    const rm = reducedMotion.peek();
    const add = (ms: number, fn: () => void) => timers.current.push(window.setTimeout(() => { if (live.current) fn(); }, ms));
    add(rm ? 0 : 450, () => pvpFx.contactSting(myFaction === 'human' ? 'h' : 'z'));
    const n = battle.b.gear_detail?.length ?? 0;
    for (let k = 1; k <= n; k++) add(rm ? 0 : 1250 + k * 330, () => { setReveal((r) => Math.max(r, k)); fx.tick(); });
    add(rm ? INTRO_REDUCED_MS : INTRO_MS, () => setReady(true));
  }, []);

  useEffect(() => {
    if (!ready) return;
    if (i > 0) apply(turns[i - 1], i > 1 ? turns[i - 2] : null);
    const last = i >= turns.length;
    const heavy = pvp && !reducedMotion.peek();
    const hold = i === 0 ? (pvp ? 500 : 700)
      : last ? (heavy ? FINAL_HOLD_MS : 1000)
      : TURN_MS + (heavy && turns[i - 1].ev === 'crit' ? CRIT_HOLD_MS : 0);
    const t = window.setTimeout(() => { if (last) onDone(); else setI(i + 1); }, hold);
    timers.current.push(t);
    return () => clearTimeout(t);
  }, [i, ready]);

  // The heartbeat under a fight against a person: slow and low at first, quicker as either side runs out.
  useEffect(() => {
    if (!pvp || !ready) return;
    const shown = Math.min(i, turns.length);
    const low = Math.min(hpOf(battle, shown, 'a') / battle.a.max_hp, hpOf(battle, shown, 'b') / battle.b.max_hp);
    const danger = low < LOW_HP ? 1 - Math.max(0, low) / LOW_HP : 0;
    const bpm = 56 + danger * 76;
    const strength = 0.3 + danger * 0.85;
    if (!heart.current) heart.current = fx.heartbeatLoop(bpm, strength);
    else { heart.current.setBpm(bpm); heart.current.setStrength(strength); }
  }, [i, ready]);

  const later = (ms: number, fn: () => void) => {
    if (ms <= 0) { fn(); return; }
    timers.current.push(window.setTimeout(() => { if (live.current) fn(); }, ms));
  };

  function body(side: Side): HTMLElement | null {
    return stageRef.current?.querySelector<HTMLElement>(`.emb-${side} .emb-body`) ?? null;
  }

  function apply(t: Turn, prev: Turn | null) {
    const rm = reducedMotion.peek();
    const actor = t.actor;
    const target: Side = actor === 'a' ? 'b' : 'a';
    const dA = t.hp_a - (prev ? prev.hp_a : battle.a.hp_start);
    const dB = t.hp_b - (prev ? prev.hp_b : battle.b.hp_start);
    const crit = t.ev === 'crit';
    const finale = pvp && t === turns[turns.length - 1];
    const add: Float[] = [];
    const slots: Record<Side, number> = { a: 0, b: 0 };
    const push = (side: Side, text: string, kind: FloatKind, tag: string | null = null) =>
      add.push({ id: ids.current++, side, text, tag, kind, slot: slots[side]++ });
    const delta = (side: Side, d: number) => {
      if (d < 0) {
        const kind: FloatKind = crit && side === target ? 'crit' : t.ev === 'dot' ? 'dot' : 'hit';
        push(side, `-${Math.round(-d)}`, kind, kind === 'crit' ? say('CRIT', 'crit') : kind === 'dot' ? say('burn', 'burn') : null);
      } else if (d > 0) push(side, `+${Math.round(d)}`, 'heal');
    };
    delta('a', dA);
    delta('b', dB);
    if (t.ev === 'dodge') push(target, say('DODGE', 'dodge'), 'dodge');

    const attacking = t.ev === 'hit' || t.ev === 'crit' || t.ev === 'dodge';
    const hurt = !!add.find((f) => f.kind === 'hit' || f.kind === 'crit' || f.kind === 'dot');
    // Against a person every blow is heavier: a longer, deeper lunge and a harder shake.
    const weight = pvp ? 1.2 : 1;

    // The blow: lunge now, land a beat later.
    if (!rm && attacking) {
      // On the person stage the lunge is a short step toward the other figure: it stays inside its own half.
      const dy = pvp ? (actor === 'a' ? -12 : 12) : (actor === 'a' ? -54 : 54);
      body(actor)?.animate(
        [{ transform: 'translateY(0) scale(1)' }, { transform: `translateY(${dy}px) scale(${pvp ? 1.04 : 1.14}) rotate(${actor === 'a' ? 4 : -4}deg)`, offset: 0.4 }, { transform: 'translateY(0) scale(1)' }],
        { duration: pvp && crit ? 520 : 340, easing: 'cubic-bezier(.3,.7,.3,1)' },
      );
    }
    later(rm || !attacking ? 0 : LAND_MS, () => {
      const now = add.map((f) => f.id);
      setFloats((cur) => [...cur, ...add]);
      later(pvp && crit ? 1700 : 1150, () => setFloats((cur) => cur.filter((f) => !now.includes(f.id))));
      if (hurt) {
        const side = add.find((f) => f.kind === 'hit' || f.kind === 'crit' || f.kind === 'dot')!.side;
        setImpact((cur) => ({ ...cur, [side]: { n: ids.current++, crit } }));
        if (pvp) setFlash({ n: ids.current++, crit: crit || finale, side });
        if (!rm) {
          const s = 9 * weight;
          body(side)?.animate(
            [{ translate: '0 0' }, { translate: `${-s}px ${s / 3}px` }, { translate: `${s * 0.9}px ${-s / 3}px` }, { translate: `${-s * 0.55}px ${s / 4}px` }, { translate: '0 0' }],
            { duration: crit || finale ? 520 : 260, easing: 'linear' },
          );
        }
      } else if (t.ev === 'dodge' && !rm) {
        body(target)?.animate(
          [{ translate: '0 0' }, { translate: `${actor === 'a' ? 34 : -34}px 0`, offset: 0.35 }, { translate: '0 0' }],
          { duration: 360, easing: 'ease-out' },
        );
      }
      // sound lands with the blow
      if (finale) pvpFx.finalBlow(battle.winner === 'a', myFaction === 'human' ? 'h' : 'z');
      else if (crit) { fx.crit(); if (pvp) pvpFx.slowMo(); }
      else if (t.ev === 'dot') fx.dotTick();
      else if (t.ev === 'hit') fx.hit();
      else if (t.ev === 'dodge') fx.dodge();
      if (add.some((f) => f.kind === 'heal')) fx.healTick();
    });

    // A crit, or the last blow, slows the view onto whoever took it.
    if (pvp && !rm && (crit || finale)) {
      later(LAND_MS, () => {
        setSlow(target);
        later(crit && !finale ? CRIT_HOLD_MS + 60 : FINAL_HOLD_MS - 300, () => setSlow(null));
      });
    }

    if (!rm && crit) {
      rootRef.current?.animate(
        [{ transform: 'translate(0,0)' }, { transform: `translate(${-9 * weight}px,${5 * weight}px)` }, { transform: `translate(${8 * weight}px,${-6 * weight}px)` }, { transform: `translate(${-6 * weight}px,${-3 * weight}px)` }, { transform: `translate(${4 * weight}px,${3 * weight}px)` }, { transform: 'translate(0,0)' }],
        { duration: pvp ? 560 : 340, delay: LAND_MS, easing: 'linear' },
      );
    }

    // abilities
    if (t.ability && t.ev !== 'dot') {
      const f = (actor === 'a' ? battle.a : battle.b).faction;
      const text = abilityName(t.ability, f);
      setBanner({ side: actor, text, n: ids.current++ });
      fx.abilityCue();
      later(1100, () => setBanner((b) => (b && b.text === text ? null : b)));
    } else if (t.ev === 'revive') {
      const af = (actor === 'a' ? battle.a : battle.b).faction;
      setBanner({ side: actor, text: abilityName(af === 'human' ? 'last_stand' : 'undying', af), n: ids.current++ });
      fx.abilityCue();
      later(1100, () => setBanner(null));
    }
  }

  const shown = Math.min(i, turns.length);
  const hpA = hpOf(battle, shown, 'a');
  const hpB = hpOf(battle, shown, 'b');
  const over = shown >= turns.length;
  const half = (side: Side) => {
    const who = side === 'a' ? battle.a : battle.b;
    const hp = side === 'a' ? hpA : hpB;
    return (
      <div class={`arena-half h-${side}`}>
        <Emblem side={side} who={who} label={side === 'a' ? say('you', 'you') : `${foeLabel(battle)} ${who.level}`.toLowerCase()} hp={hp}
          battle={battle} heat={heat} impact={impact[side]} dying={over && hp <= 0} />
        <Floats list={floats.filter((f) => f.side === side)} />
      </div>
    );
  };
  const bar = (
    <div class="arena-bar">
      <span class="dim num round" aria-live="off">{say('Round', 'round')} {Math.max(1, shown)}<small class="of"> / {turns.length}</small></span>
      {!pvp && battle.stance && <span class="label-tape fight-stance" title={say('Your stance', 'how you hunt')}>{stanceName(battle.stance, battle.a.faction)}</span>}
      <button class="btn" onClick={onDone}><Icon name="sprint" size={20} />{say('Skip', 'skip')}</button>
    </div>
  );
  const bannerEl = banner && (
    <div key={banner.n} class={`ability-banner ab-${banner.side}`} aria-hidden="true">
      <span class="ab-flare" />
      <span class="label-tape ab-tape">{banner.text}</span>
    </div>
  );

  if (pvp) {
    return (
      <div class="fight pvp" ref={rootRef} role="region" aria-label="Fight">
        <PvpArena
          battle={battle} hpA={hpA} hpB={hpB} impact={impact} over={over} ready={ready} reveal={reveal} flash={flash} slow={slow}
          floatsA={<Floats list={floats.filter((f) => f.side === 'a')} />} floatsB={<Floats list={floats.filter((f) => f.side === 'b')} />}
          stageRef={stageRef} onSkipIntro={() => { setReady(true); setReveal(9); }}
        >
          {bannerEl}
          {bar}
        </PvpArena>
      </div>
    );
  }

  return (
    <div class="fight" ref={rootRef} role="region" aria-label="Fight">
      <Card side="b" who={battle.b} label={foeLabel(battle)} you={false} hp={hpB} />
      <div class="arena" ref={stageRef}>
        {half('b')}
        {half('a')}
        {bannerEl}
        {bar}
      </div>
      <Card side="a" who={battle.a} label={myLabel(battle)} you hp={hpA} />
    </div>
  );
}
