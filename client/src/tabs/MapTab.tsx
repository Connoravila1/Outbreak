import { useState } from 'preact/hooks';
import { api, errorMessage } from '../api';
import { follow, selectedId } from '../map/GameMap';
import { threatOf, THREAT_WORD, THREAT_WORD_HEAT } from '../map/threat';
import { haversine, formatDistance, position } from '../location';
import { applyMe, faction, lens, me, onBattle, world } from '../state/store';
import { INTERACT_RANGE_M, objectsFrom, placeTendsTo, type GameObject } from '../state/objects';
import { lastStance } from '../state/stance';
import { StanceControl } from '../battle/StanceControl';
import { inSanctuary, pollError, pollNow } from '../state/poll';
import { Sheet } from '../ui/Sheet';
import { Icon } from '../ui/Icon';
import { say } from '../ui/voice';
import { RewardLines } from '../ui/RewardLines';
import { pushToast } from '../ui/kit';
import { coachDone, recordCache } from '../state/record';
import { enqueueLevelUp } from '../battle/session';
import type { PlaceKind, Rewards, WorldEnemy, WorldLandmark } from '../api';
import { clock } from '../shell/Vitals';

type Result = { kind: 'loot'; loot: Rewards } | { kind: 'note'; text: string };

const KIND_LINE: Record<GameObject['kind'], [string, string]> = {
  enemy: ['Hostile.', 'something warm. close.'],
  cache: ['Supplies. Worth the walk.', 'something to feed on.'],
  airdrop: ['Drop from above. Better goods inside.', 'a better kill, dropped from the sky.'],
  echo: ['A real player\'s build, replayed. Labelled honestly.', 'an echo of something that lives.'],
  stronghold: ['Clan ground. Held or up for grabs.', 'ground that someone holds.'],
  raid: ['Boss. Needs a crowd.', 'a huge heat. many will come.'],
  landmark: ['A real place. Supplies turn up here.', 'a place that fed once. it still does.'],
};

/** "2 h 10 min" / "35 min" until a landmark restocks. */
function restockIn(ms: number): string {
  const mins = Math.max(1, Math.ceil(ms / 60_000));
  const h = Math.floor(mins / 60);
  return h > 0 ? `${h} h ${mins % 60} min` : `${mins} min`;
}

/** What an opened cache or claimed stronghold gave. Lives above the object sheet: the next poll removes the opened object from the map. */
function ResultSheet({ result, onClose }: { result: Result; onClose: () => void }) {
  return (
    <Sheet title="Result" onClose={onClose}>
      <div class="battle-summary">
        <p class="display result">{result.kind === 'loot' ? say('Opened', 'opened') : say('Done', 'done')}</p>
        {result.kind === 'loot' ? (<><p>{say('Supplies recovered.', 'spoils. take them.')}</p><RewardLines r={result.loot} /></>) : <p>{result.text}</p>}
      </div>
      <div class="sheet-actions"><button class="btn primary block" onClick={onClose}>{say('Done', 'done')}</button></div>
    </Sheet>
  );
}

function ObjectSheet({ o, onClose, onResult }: { o: GameObject; onClose: () => void; onResult: (r: Result) => void }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const m = me.value;
  const p = position.value;
  const dist = p ? haversine(p, o) : Infinity;
  const inRange = dist <= INTERACT_RANGE_M;
  const threat = o.level != null && m ? threatOf(o.level, m.level) : null;
  const isHeat = lens.value === 'heat';
  const downed = !!m?.downed_until && m.downed_until > Date.now();

  const act = (() => {
    switch (o.kind) {
      case 'enemy': case 'echo': return { verb: 'Engage', icon: 'crossed-swords' as const };
      case 'cache': case 'airdrop': case 'landmark': return { verb: 'Open', icon: 'wooden-crate' as const };
      case 'stronghold': return { verb: 'Claim', icon: 'castle' as const };
      case 'raid': return { verb: 'Attack', icon: 'skull-crack' as const };
    }
  })();

  const lm = o.kind === 'landmark' ? (o.raw as WorldLandmark) : null;
  const restock = lm && !lm.available && lm.available_at ? Math.max(0, lm.available_at - Date.now()) : null;
  const fights = o.kind === 'enemy' || o.kind === 'echo' || o.kind === 'raid' || (o.kind === 'stronghold' && !!(o.raw as { clan?: unknown }).clan);

  let reason: string | null = null;
  if (restock != null) reason = say(`Picked clean. Restocks in ${restockIn(restock)}.`, `picked clean. it feeds again in ${restockIn(restock)}.`);
  else if (lm && inSanctuary.value) reason = say('Nothing can be opened in a sanctuary.', 'quiet ground. nothing to take.');
  else if (!inRange) reason = say(`Move closer. ${formatDistance(Math.max(0, dist - INTERACT_RANGE_M))} to go.`, `too far. ${formatDistance(Math.max(0, dist - INTERACT_RANGE_M))} closer.`);
  else if (downed) reason = say('You are downed. Recover first.', 'you are down. wait.');
  else if (o.kind === 'stronghold' && (m?.level ?? 0) < 15) reason = say('Strongholds unlock at level 15.', 'not yet. level 15.');
  else if (o.kind === 'stronghold' && !m?.clan) reason = say('Join a clan to claim territory.', 'no pack. no ground.');
  else if (o.kind === 'stronghold' && !m?.consumables.flag) reason = say('You need a flag. The Store sells them.', 'you need a marker. trade for one.');
  else if (o.kind === 'raid' && (m?.level ?? 0) < 20) reason = say('Raids unlock at level 20.', 'not yet. level 20.');
  else if (o.kind === 'raid' && ((o.raw as { can_attack_at?: number }).can_attack_at ?? 0) > Date.now()) {
    reason = say(`You can attack again in ${clock(((o.raw as { can_attack_at: number }).can_attack_at) - Date.now())}.`, `rest. again in ${clock(((o.raw as { can_attack_at: number }).can_attack_at) - Date.now())}.`);
  }

  const go = async () => {
    setBusy(true); setErr(null);
    try {
      // Fights play back full-screen (battle/); `me` is applied when the player continues.
      const stance = lastStance.peek();
      if (o.kind === 'enemy' || o.kind === 'echo') {
        onBattle(await api.engage(o.id, stance));
        onClose();
      } else if (o.kind === 'cache' || o.kind === 'airdrop' || o.kind === 'landmark') {
        const r = await api.open(o.id);
        applyMe(r.me);
        recordCache();
        onResult({ kind: 'loot', loot: r.loot });
        enqueueLevelUp(r.loot.level_up, r.me);
      } else if (o.kind === 'stronghold') {
        const r = await api.claimStronghold(o.id, stance);
        r.battles.forEach(onBattle);
        if (r.battles.length) {
          onClose();
          pushToast(r.claimed ? say('Stronghold claimed.', 'yours now. hold it.') : say('The garrison held.', 'they held. for now.'), r.claimed ? 'good' : 'info');
        }
        else { applyMe(r.me); onResult({ kind: 'note', text: r.claimed ? say('Stronghold claimed.', 'yours now. hold it.') : say('Nothing happened.', 'nothing.') }); }
      } else {
        onBattle(await api.raidAttack(o.id, stance));
        onClose();
      }
      if (o.kind === 'cache' || o.kind === 'airdrop' || o.kind === 'landmark') pollNow();
    } catch (e) {
      setErr(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const eta = o.expiresAt ? o.expiresAt - Date.now() : null;
  return (
    <Sheet title={o.name} onClose={onClose}>
      <div class="obj-head">
        <div class="obj-icon"><Icon name={o.icon} size={32} /></div>
        <div>
          <h2 class="display obj-title">{o.name}{o.level != null ? ` · ${o.level}` : ''}</h2>
          <p class="obj-sub">{lm ? (placeTendsTo(lm.kind as PlaceKind, faction.value ?? 'human') ?? KIND_LINE[o.kind][isHeat ? 1 : 0]) : KIND_LINE[o.kind][isHeat ? 1 : 0]}{o.detail && !lm ? ` ${o.detail}.` : ''}</p>
        </div>
      </div>
      {o.lore && <p class="obj-lore">{o.lore}</p>}
      <div class="pill-row">
        {o.elite && o.kind === 'enemy' && <span class="pill t-deadly">{say('Elite', 'elite')}</span>}
        {lm && <span class="pill">{o.detail}</span>}
        {o.note && <span class="pill">{o.note}</span>}
        {threat && <span class={'pill t-' + threat}>{isHeat ? THREAT_WORD_HEAT[threat] : THREAT_WORD[threat]}</span>}
        {restock != null && <span class="pill far">{say('Restocks in', 'feeds again in')} {restockIn(restock)}</span>}
        <span class={'pill ' + (inRange ? 'in-range' : 'far')}>{inRange ? say('In range', 'in reach') : say(`Move closer · ${formatDistance(dist)}`, `${formatDistance(dist)} away`)}</span>
        {eta != null && eta > 0 && <span class="pill far">{say('Gone in', 'fades in')} {clock(eta)}</span>}
      </div>
      {fights && <StanceControl archetype={o.kind === 'enemy' ? (o.raw as WorldEnemy).archetype : null} />}
      <div class="sheet-actions">
        <button class="btn primary block" disabled={!!reason || busy} aria-disabled={!!reason || busy} onClick={go} aria-describedby={reason ? 'why' : undefined}>
          {busy ? '…' : act.verb}
        </button>
        {reason && <p class="reason" id="why">{reason}</p>}
        {err && <p class="reason" role="alert" style={{ color: 'var(--danger)' }}>{err}</p>}
      </div>
    </Sheet>
  );
}

export function MapTab() {
  const [result, setResult] = useState<Result | null>(null);
  const w = world.value;
  const f = faction.value;
  const sel = selectedId.value;
  const obj = w && f && sel ? objectsFrom(w, f).find((o) => o.id === sel) : undefined;
  const coach = !coachDone.value && !obj && !!w?.enemies.some((e) => e.tutorial);
  const nothing = w && w.enemies.length + w.caches.length + w.echoes.length === 0;
  return (
    <>
      {inSanctuary.value && (
        <p class="map-banner" role="status">{say('Sanctuary. Nothing hunts here, and nothing can be fought.', 'quiet ground. nothing stirs. nothing can hurt you.')}</p>
      )}
      {!inSanctuary.value && pollError.value && <p class="map-banner err" role="alert">{pollError.value}</p>}
      {nothing && !inSanctuary.value && (
        <p class="map-note">{say('Nothing within 450 m. Walk a block and it changes every 10 minutes.', 'nothing warm within 450 m. walk. it shifts every 10 minutes.')}</p>
      )}
      {coach && (
        <p class="coach" role="status">
          <Icon name="crossed-swords" size={20} />
          <span>{say('Your first one. Tap it, then Engage.', 'the first one. close. take it.')}</span>
        </p>
      )}
      <button class="map-fab" aria-pressed={follow.value} aria-label="Center on me" onClick={() => { follow.value = true; }}>
        <Icon name="gps" size={28} />
      </button>
      {obj && !result && <ObjectSheet key={obj.id} o={obj} onClose={() => { selectedId.value = null; }} onResult={setResult} />}
      {result && <ResultSheet result={result} onClose={() => { setResult(null); selectedId.value = null; }} />}
    </>
  );
}
