import { useState } from 'preact/hooks';
import { api, errorMessage, type Me } from '../api';
import { applyMe, me } from '../state/store';
import { Sheet } from '../ui/Sheet';
import { Icon } from '../ui/Icon';
import { say } from '../ui/voice';
import { Action, ErrorLine, pushToast } from '../ui/kit';
import { clunk } from '../audio/fx';
import { isRarePlus, itemTitle, perkInfo, SLOT_ICON, slotLabel, STAT_KEYS, STAT_LABEL, uniqueLore } from './util';

const UPGRADE_LEVEL = 4;

/** Final stats, with an arrow and a number against whatever is worn in that slot. */
export function ItemSheet({ uid, onClose }: { uid: string; onClose: () => void }) {
  const m = me.value;
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [confirmScrap, setConfirmScrap] = useState(false);
  const it = m?.items.find((i) => i.uid === uid);
  if (!m || !it) return null;
  const worn = m.equipped[it.slot] === uid;
  const cur = worn ? null : m.items.find((i) => i.uid === m.equipped[it.slot]) ?? null;
  const lore = uniqueLore(it.unique);

  const run = async (what: string, f: () => Promise<{ me: Me }>, done: string, close = false) => {
    setBusy(what); setErr(null);
    try {
      const r = await f();
      applyMe(r.me);
      clunk();
      pushToast(done, 'good');
      if (close) onClose();
    } catch (e) {
      setErr(errorMessage(e));
    } finally {
      setBusy(null);
    }
  };

  const equipReason = m.level < it.req ? say(`Needs level ${it.req}.`, `level ${it.req} first.`) : null;
  const cost = it.upgrade_cost;
  const upReason = m.level < UPGRADE_LEVEL ? say(`Upgrading unlocks at level ${UPGRADE_LEVEL}.`, `level ${UPGRADE_LEVEL} first.`)
    : cost == null ? say('Already at +10.', 'nothing more to give.')
    : m.salvage < cost ? say(`Need ${cost - m.salvage} more salvage.`, `${cost - m.salvage} more salvage.`) : null;
  const scrapReason = worn ? say('Unequip it first.', 'let it go first.') : null;
  const needConfirm = isRarePlus(it.rarity);

  return (
    <Sheet title={itemTitle(it)} onClose={onClose} tall>
      <div class={`card item-card rarity-${it.rarity} is-head`}>
        <div class="obj-head">
          <div class="obj-icon"><Icon name={SLOT_ICON[it.slot]} size={30} /></div>
          <div>
            <h2 class="display obj-title">{itemTitle(it)}{it.upgrade ? ` +${it.upgrade}` : ''}</h2>
            <p class="obj-sub"><span class="rarity-label">{it.rarity}</span> · {slotLabel(it.slot)} · {say('needs level', 'level')} {it.req}</p>
          </div>
        </div>
        {lore && <p class="lore-big hand-or-voice">“{lore}”</p>}
      </div>

      <table class="stat-table">
        <caption class="sr-only">Stats</caption>
        <tbody>
          {STAT_KEYS.filter((k) => it.stats[k] || cur?.stats[k]).map((k) => {
            const d = cur || !worn ? it.stats[k] - (cur?.stats[k] ?? 0) : 0;
            return (
              <tr key={k}>
                <th scope="row">{STAT_LABEL[k]}</th>
                <td class="num"><b>{it.stats[k]}</b></td>
                <td class={'num delta ' + (d > 0 ? 'up' : d < 0 ? 'down' : '')}>
                  {worn ? '' : d > 0 ? `▲ +${d}` : d < 0 ? `▼ ${d}` : '='}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
      {!worn && <p class="dim vs">{cur ? say(`Against your ${itemTitle(cur)}.`, `against ${itemTitle(cur)}.`) : say(`Your ${slotLabel(it.slot)} slot is empty.`, `${slotLabel(it.slot)} is empty.`)}</p>}

      {it.perks.length > 0 && (
        <ul class="perk-list">
          {it.perks.map((p) => { const pi = perkInfo(p); return <li key={p}><b>{pi.name}</b>{pi.text ? ` ${pi.text}` : ''}</li>; })}
        </ul>
      )}

      <div class="sheet-actions act-grid">
        {worn ? (
          <Action id="why-unequip" block busy={busy === 'unequip'} onClick={() => run('unequip', () => api.unequip(it.slot), say('Unequipped.', 'let go.'), true)}>{say('Unequip', 'Unequip')}</Action>
        ) : (
          <Action id="why-equip" primary block reason={equipReason} busy={busy === 'equip'} onClick={() => run('equip', () => api.equip(uid), say('Equipped.', 'worn.'), true)}>Equip</Action>
        )}
        <Action id="why-up" block reason={upReason} busy={busy === 'up'} onClick={() => run('up', () => api.upgrade(uid), say('Upgraded.', 'stronger.'))}>
          Upgrade{cost != null && <span class="cost num"><Icon name="recycle" size={16} />{cost}</span>}
        </Action>
        {confirmScrap ? (
          <div class="confirm">
            <p>{say(`Scrap this ${it.rarity} item for ${it.scrap_value} salvage?`, `tear it down for ${it.scrap_value} salvage?`)}</p>
            <div class="confirm-row">
              <button class="btn" onClick={() => setConfirmScrap(false)}>{say('Keep it', 'keep')}</button>
              <button class="btn danger" disabled={busy === 'scrap'} onClick={() => run('scrap', () => api.scrap([uid]), say(`+${it.scrap_value} salvage.`, `+${it.scrap_value} salvage.`), true)}>{say('Scrap it', 'Scrap')}</button>
            </div>
          </div>
        ) : (
          <Action id="why-scrap" block danger reason={scrapReason} busy={busy === 'scrap'}
            onClick={() => (needConfirm ? setConfirmScrap(true) : run('scrap', () => api.scrap([uid]), say(`+${it.scrap_value} salvage.`, `+${it.scrap_value} salvage.`), true))}>
            Scrap<span class="cost num"><Icon name="recycle" size={16} />+{it.scrap_value}</span>
          </Action>
        )}
      </div>
      <ErrorLine text={err} />
    </Sheet>
  );
}
