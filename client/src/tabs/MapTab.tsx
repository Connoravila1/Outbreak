import { useState } from 'preact/hooks';
import { api, errorMessage } from '../api';
import { follow, selectedId } from '../map/GameMap';
import { threatOf, THREAT_WORD, THREAT_WORD_HEAT } from '../map/threat';
import { haversine, formatDistance, position } from '../location';
import { applyMe, faction, lens, me, onBattle, world } from '../state/store';
import { INTERACT_RANGE_M, objectsFrom, type GameObject } from '../state/objects';
import { inSanctuary, pollError, pollNow } from '../state/poll';
import { Sheet } from '../ui/Sheet';
import { Icon } from '../ui/Icon';
import { say } from '../ui/voice';
import { RewardLines } from '../ui/RewardLines';
import { recordCache } from '../state/record';
import { enqueueLevelUp } from '../battle/session';
import type { Rewards } from '../api';
import { clock } from '../shell/Vitals';

type Result = { kind: 'loot'; loot: Rewards } | { kind: 'note'; text: string };

const KIND_LINE: Record<GameObject['kind'], [string, string]> = {
  enemy: ['Hostile.', 'something warm. close.'],
  cache: ['Supplies. Worth the walk.', 'something to feed on.'],
  airdrop: ['Drop from above. Better goods inside.', 'a better kill, dropped from the sky.'],
  echo: ['A real player\'s build, replayed. Labelled honestly.', 'an echo of something that lives.'],
  stronghold: ['Clan ground. Held or up for grabs.', 'ground that someone holds.'],
  raid: ['Boss. Needs a crowd.', 'a huge heat. many will come.'],
};

function ObjectSheet({ o, onClose }: { o: GameObject; onClose: () => void }) {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [result, setResult] = useState<Result | null>(null);
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
      case 'cache': case 'airdrop': return { verb: 'Open', icon: 'wooden-crate' as const };
      case 'stronghold': return { verb: 'Claim', icon: 'castle' as const };
      case 'raid': return { verb: 'Attack', icon: 'skull-crack' as const };
    }
  })();

  let reason: string | null = null;
  if (!inRange) reason = say(`Move closer. ${formatDistance(Math.max(0, dist - INTERACT_RANGE_M))} to go.`, `too far. ${formatDistance(Math.max(0, dist - INTERACT_RANGE_M))} closer.`);
  else if (downed && o.kind !== 'cache' && o.kind !== 'airdrop') reason = say('You are downed. Recover first.', 'you are down. wait.');
  else if (o.kind === 'stronghold' && (m?.level ?? 0) < 15) reason = say('Strongholds unlock at level 15.', 'not yet. level 15.');
  else if (o.kind === 'raid' && (m?.level ?? 0) < 20) reason = say('Raids unlock at level 20.', 'not yet. level 20.');

  const go = async () => {
    setBusy(true); setErr(null);
    try {
      // Fights play back full-screen (battle/); `me` is applied when the player continues.
      if (o.kind === 'enemy' || o.kind === 'echo') {
        onBattle(await api.engage(o.id));
        onClose();
      } else if (o.kind === 'cache' || o.kind === 'airdrop') {
        const r = await api.open(o.id);
        applyMe(r.me);
        recordCache();
        setResult({ kind: 'loot', loot: r.loot });
        enqueueLevelUp(r.loot.level_up, r.me);
      } else if (o.kind === 'stronghold') {
        const r = await api.claimStronghold(o.id);
        r.battles.forEach(onBattle);
        if (r.battles.length) onClose();
        else { applyMe(r.me); setResult({ kind: 'note', text: r.claimed ? say('Stronghold claimed.', 'yours now. hold it.') : say('Nothing happened.', 'nothing.') }); }
      } else {
        onBattle(await api.raidAttack(o.id));
        onClose();
      }
      if (o.kind === 'cache' || o.kind === 'airdrop') pollNow();
    } catch (e) {
      setErr(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  if (result) {
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

  const eta = o.expiresAt ? o.expiresAt - Date.now() : null;
  return (
    <Sheet title={o.name} onClose={onClose}>
      <div class="obj-head">
        <div class="obj-icon"><Icon name={o.icon} size={32} /></div>
        <div>
          <h2 class="display obj-title">{o.name}{o.level != null ? ` · ${o.level}` : ''}</h2>
          <p class="obj-sub">{KIND_LINE[o.kind][isHeat ? 1 : 0]}{o.detail ? ` ${o.detail}.` : ''}</p>
        </div>
      </div>
      <div class="pill-row">
        {o.elite && o.kind === 'enemy' && <span class="pill t-deadly">{say('Elite', 'elite')}</span>}
        {threat && <span class={'pill t-' + threat}>{isHeat ? THREAT_WORD_HEAT[threat] : THREAT_WORD[threat]}</span>}
        <span class={'pill ' + (inRange ? 'in-range' : 'far')}>{inRange ? say('In range', 'in reach') : say(`Move closer · ${formatDistance(dist)}`, `${formatDistance(dist)} away`)}</span>
        {eta != null && eta > 0 && <span class="pill far">{say('Gone in', 'fades in')} {clock(eta)}</span>}
      </div>
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
  const w = world.value;
  const f = faction.value;
  const sel = selectedId.value;
  const obj = w && f && sel ? objectsFrom(w, f).find((o) => o.id === sel) : undefined;
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
      <button class="map-fab" aria-pressed={follow.value} aria-label="Center on me" onClick={() => { follow.value = true; }}>
        <Icon name="gps" size={28} />
      </button>
      {obj && <ObjectSheet key={obj.id} o={obj} onClose={() => { selectedId.value = null; }} />}
    </>
  );
}
