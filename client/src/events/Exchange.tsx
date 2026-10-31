import { useEffect, useState } from 'preact/hooks';
import { api, errorMessage } from '../api';
import { applyMe, catalog, faction, lens, me } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { Action, ErrorLine } from '../ui/kit';
import { showRewards } from '../ui/RewardsSheet';
import { enqueueLevelUp } from '../battle/session';
import { purchase } from '../audio/fx';
import { FramedAvatar } from '../avatar/Frame';
import { colorHex } from '../ui/Callsign';
import { eventName, eventsState, refreshEvents } from './store';
import './events.css';

/** The Event Exchange: salvage sinks that open in the Store while an event is running. */
export function Exchange() {
  const m = me.value;
  const st = eventsState.value;
  const [pick, setPick] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => { void refreshEvents(true); }, []);
  const cat = catalog.value?.event_exchange;
  if (!m || !st || !st.live || !cat) return null;
  const f = faction.value ?? 'human';
  const buy = async (sku: string, name: string) => {
    setBusy(true); setErr(null);
    try {
      const r = await api.exchangeBuy(sku);
      applyMe(r.me);
      purchase();
      setPick(null);
      showRewards(name, r.rewards);
      enqueueLevelUp(r.rewards.level_up, r.me);
      void refreshEvents(true);
    } catch (e) { setErr(errorMessage(e)); } finally { setBusy(false); }
  };
  return (
    <>
      <h4 class="cos-sub">{say('Event Exchange', 'the turning market')} · {eventName(st.live.type)}</h4>
      <p class="ex-note dim">{say('Open while an event runs. Looks and conveniences, nothing that changes a fight.', 'open while the turning lasts. looks and comforts, nothing that wins fights.')}</p>
      <ul class="store">
        {cat.items.map((x) => {
          const s = st.exchange.items.find((i) => i.sku === x.sku);
          if (!s) return null;
          const cos = catalog.value?.cosmetics?.find((c) => c.id === x.sku);
          const left = Math.max(0, s.limit - s.bought);
          const reason = m.level < cat.min_level ? say(`The Exchange opens at level ${cat.min_level}.`, `opens at level ${cat.min_level}.`)
            : s.owned ? say('You own this.', 'already yours.')
            : left === 0 ? say('You have bought all you can this event.', 'no more this turning.')
            : (x.sku === 'ex_requisition' || x.sku === 'ex_crate') && m.items.length >= m.inventory_cap ? say('Your pack is full.', 'no room left.')
            : m.salvage < s.price ? say(`Need ${s.price - m.salvage} more salvage.`, `${s.price - m.salvage} more salvage.`) : null;
          return (
            <li class="card store-row cos-row" key={x.sku}>
              {cos?.kind === 'frame' && <span class="cos-ico"><FramedAvatar frame={cos.id} spec={m.avatar} faction={f} level={m.level} lens={lens.value} size={56} /></span>}
              <div class="st-main">
                <b>{x.names[f]}</b>
                {cos?.kind === 'color'
                  ? <span class="cos-sample" style={{ color: colorHex(cos.id) }}>{m.callsign ?? 'Callsign'}</span>
                  : cos ? <span class="dim">{say('Portrait frame', 'portrait frame')}</span>
                  : <span class="dim">{x.text}</span>}
                {s.limit > 1 && <span class="ex-left dim">{say(`${left} of ${s.limit} left this event`, `${left} of ${s.limit} left`)}</span>}
              </div>
              {pick === x.sku ? (
                <div class="st-confirm">
                  <span class="st-ask">{say(`Spend ${s.price}?`, `pay ${s.price}?`)}</span>
                  <div class="confirm-row">
                    <button class="btn" onClick={() => setPick(null)}>{say('No', 'no')}</button>
                    <button class="btn primary" disabled={busy} onClick={() => buy(x.sku, x.names[f])}>{busy ? '…' : say('Buy', 'Buy')}</button>
                  </div>
                </div>
              ) : (
                <Action id={'why-ex-' + x.sku} reason={reason} onClick={() => setPick(x.sku)}>
                  Buy<span class="cost num"><Icon name="recycle" size={16} />{s.price}</span>
                </Action>
              )}
            </li>
          );
        })}
      </ul>
      <ErrorLine text={err} />
    </>
  );
}
