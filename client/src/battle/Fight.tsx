import { useEffect, useRef, useState } from 'preact/hooks';
import type { Battle, Combatant, Turn } from '../api';
import { reducedMotion } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { abilityName } from '../gear/util';
import * as fx from '../audio/fx';
import { foeLabel, myLabel } from './names';

const TURN_MS = 550;

type Side = 'a' | 'b';
interface Float { id: number; side: Side; text: string; kind: 'hit' | 'crit' | 'dodge' | 'heal' | 'dot'; t: number }
interface Banner { side: Side; text: string; n: number }

function hpOf(b: Battle, i: number, side: Side): number {
  if (i === 0) return side === 'a' ? b.a.hp_start : b.b.hp_start;
  const t = b.turns[i - 1];
  return side === 'a' ? t.hp_a : t.hp_b;
}

function Fighter({ side, who, label, you, hp, floats, banner, cardRef }: {
  side: Side; who: Combatant; label: string; you: boolean; hp: number; floats: Float[]; banner: Banner | null;
  cardRef: { current: HTMLDivElement | null };
}) {
  const pct = Math.max(0, Math.min(100, (hp / who.max_hp) * 100));
  return (
    <div class={`fighter side-${side} card`} ref={cardRef} data-faction={who.faction}>
      <div class="f-head">
        <h2 class="display f-name voice">{label}</h2>
        {you && <span class="label-tape">{say('You', 'you')}</span>}
      </div>
      <p class="f-meta dim">{say('Level', 'level')} {who.level}{who.title ? ` · ${who.title}` : ''}</p>
      {who.gear.length > 0 && (
        <ul class="f-gear">{who.gear.map((g, i) => <li key={i}>{g}</li>)}</ul>
      )}
      <div class="bar f-bar" role="progressbar" aria-label={`${label} health`} aria-valuemin={0} aria-valuemax={who.max_hp} aria-valuenow={Math.round(hp)}>
        <i class="trail" style={{ width: `${pct}%` }} />
        <i class="fill" style={{ width: `${pct}%` }} />
      </div>
      <p class="f-hp num">{Math.round(hp)} / {who.max_hp}</p>
      <div class="floats" aria-hidden="true">
        {floats.map((f) => <span key={f.id} class={'float ' + f.kind}>{f.text}</span>)}
      </div>
      {banner && (
        <div key={banner.n} class="ability-banner" aria-hidden="true">
          <span class="label-tape ab-tape">{banner.text}</span>
          <span class="ab-flare" />
        </div>
      )}
    </div>
  );
}

/** Plays `battle.turns` at ~550 ms a turn. Calls onDone when the last blow has landed or the player skips. */
export function Fight({ battle, onDone }: { battle: Battle; onDone: () => void }) {
  const { turns } = battle;
  const [i, setI] = useState(0);
  const [floats, setFloats] = useState<Float[]>([]);
  const [banner, setBanner] = useState<Banner | null>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  const cardA = useRef<HTMLDivElement>(null);
  const cardB = useRef<HTMLDivElement>(null);
  const timers = useRef<number[]>([]);
  const ids = useRef(1);
  const live = useRef(true);

  useEffect(() => () => { live.current = false; timers.current.forEach(clearTimeout); }, []);

  useEffect(() => {
    if (i > 0) apply(turns[i - 1], i > 1 ? turns[i - 2] : null);
    const t = window.setTimeout(() => { if (i >= turns.length) onDone(); else setI(i + 1); }, i === 0 ? 650 : i >= turns.length ? 900 : TURN_MS);
    timers.current.push(t);
    return () => clearTimeout(t);
  }, [i]);

  function apply(t: Turn, prev: Turn | null) {
    const rm = reducedMotion.peek();
    const actor = t.actor;
    const target: Side = actor === 'a' ? 'b' : 'a';
    const dA = t.hp_a - (prev ? prev.hp_a : battle.a.hp_start);
    const dB = t.hp_b - (prev ? prev.hp_b : battle.b.hp_start);
    const now = Date.now();
    const add: Float[] = [];
    const push = (side: Side, text: string, kind: Float['kind']) => add.push({ id: ids.current++, side, text, kind, t: now });
    const delta = (side: Side, d: number) => {
      if (d < 0) push(side, `-${Math.round(-d)}`, t.ev === 'crit' ? 'crit' : t.ev === 'dot' ? 'dot' : 'hit');
      else if (d > 0) push(side, `+${Math.round(d)}`, 'heal');
    };
    delta('a', dA);
    delta('b', dB);
    if (t.ev === 'dodge') push(target, say('dodge', 'dodged'), 'dodge');
    setFloats((cur) => [...cur.filter((f) => now - f.t < 1400), ...add]);

    // sound
    if (t.ev === 'crit') fx.crit();
    else if (t.ev === 'hit') fx.hit();
    else if (t.ev === 'dodge') fx.dodge();
    else if (t.ev === 'dot') fx.hit();

    // motion
    const attacking = t.ev === 'hit' || t.ev === 'crit' || t.ev === 'dodge';
    if (!rm && attacking) {
      const el = (actor === 'a' ? cardA : cardB).current;
      const dy = actor === 'a' ? -26 : 26;
      el?.animate([{ transform: 'translateY(0)' }, { transform: `translateY(${dy}px) scale(1.03)` }, { transform: 'translateY(0)' }], { duration: 260, easing: 'ease-out' });
      if (t.ev !== 'dodge') {
        const hurt = (target === 'a' ? cardA : cardB).current;
        hurt?.animate([{ filter: 'brightness(1)' }, { filter: 'brightness(1.6)' }, { filter: 'brightness(1)' }], { duration: 220, delay: 120 });
      }
    }
    if (!rm && t.ev === 'crit') {
      rootRef.current?.animate(
        [{ transform: 'translate(0,0)' }, { transform: 'translate(-9px,5px)' }, { transform: 'translate(8px,-6px)' }, { transform: 'translate(-6px,-3px)' }, { transform: 'translate(4px,3px)' }, { transform: 'translate(0,0)' }],
        { duration: 340, easing: 'linear' },
      );
    }

    // abilities
    if (t.ability && t.ev !== 'dot') {
      const f = (actor === 'a' ? battle.a : battle.b).faction;
      const text = abilityName(t.ability, f);
      setBanner({ side: actor, text, n: ids.current++ });
      fx.abilityCue();
      timers.current.push(window.setTimeout(() => { if (live.current) setBanner((b) => (b && b.text === text ? null : b)); }, 1100));
    } else if (t.ev === 'revive') {
      setBanner({ side: actor, text: say('Last stand', 'undying'), n: ids.current++ });
      fx.abilityCue();
      timers.current.push(window.setTimeout(() => { if (live.current) setBanner(null); }, 1100));
    }
  }

  const shown = Math.min(i, turns.length);
  return (
    <div class="fight" ref={rootRef} role="region" aria-label="Fight">
      <Fighter side="b" who={battle.b} label={foeLabel(battle)} you={false} hp={hpOf(battle, shown, 'b')}
        floats={floats.filter((f) => f.side === 'b')} banner={banner?.side === 'b' ? banner : null} cardRef={cardB} />
      <div class="fight-mid">
        <span class="dim num" aria-live="off">{say('Blow', 'blow')} {shown} / {turns.length}</span>
        <button class="btn" onClick={onDone}><Icon name="sprint" size={20} />{say('Skip', 'skip')}</button>
      </div>
      <Fighter side="a" who={battle.a} label={myLabel(battle)} you hp={hpOf(battle, shown, 'a')}
        floats={floats.filter((f) => f.side === 'a')} banner={banner?.side === 'a' ? banner : null} cardRef={cardA} />
    </div>
  );
}
