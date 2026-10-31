import { useState } from 'preact/hooks';
import { api, errorMessage, type CatalogCosmetic, type CosmeticKind } from '../api';
import { applyMe, catalog, faction, lens, me } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import { ErrorLine, Section } from '../ui/kit';
import { Avatar } from '../avatar/Avatar';
import { FramedAvatar } from '../avatar/Frame';
import { colorHex } from '../ui/Callsign';
import '../collection/collection.css';

/** Wear a cosmetic you own, or take it off. Shared by the wardrobe and the store rows. */
export async function wear(kind: CosmeticKind, id: string | null, setErr?: (e: string | null) => void): Promise<boolean> {
  try {
    const r = await api.equipCosmetic(kind, id);
    applyMe(r.me);
    setErr?.(null);
    return true;
  } catch (e) {
    setErr?.(errorMessage(e));
    return false;
  }
}

/** The achievement that unlocks an earned-only cosmetic, by name. */
function earnedBy(c: CatalogCosmetic): string {
  const f = faction.value ?? 'human';
  const a = catalog.value?.achievements?.find((x) => x.id === c.unlock);
  return a ? a.names[f] : '';
}

/** Callsign colour and avatar frame: everything you own, one tap to wear. */
export function Wardrobe() {
  const m = me.value;
  const all = catalog.value?.cosmetics ?? [];
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  if (!m || !all.length) return null;
  const f = faction.value ?? 'human';
  const owned = new Set(m.cosmetics?.owned ?? []);
  // What you own, plus the earned-only ones still to win (shown locked). Things for sale live in the Store.
  const shown = (kind: CosmeticKind) => all.filter((c) => c.kind === kind && (owned.has(c.id) || c.price === 0));
  const set = async (kind: CosmeticKind, id: string | null) => {
    setBusy(true);
    await wear(kind, id, setErr);
    setBusy(false);
  };
  const color = m.cosmetics?.color ?? null;
  const frame = m.cosmetics?.frame ?? null;
  return (
    <Section title={say('Wardrobe', 'looks')}>
      <h4 class="wardrobe-h">{say('Callsign colour', 'name colour')}</h4>
      <ul class="swatches" aria-label="Callsign colour">
        <li><button type="button" class="swatch" aria-pressed={color == null} disabled={busy} onClick={() => set('color', null)}><span class="sw-name">{say('None', 'none')}</span></button></li>
        {shown('color').map((c) => {
          const have = owned.has(c.id);
          return (
            <li key={c.id}>
              <button
                type="button" class="swatch" aria-pressed={color === c.id} disabled={busy || !have}
                style={have ? { color: colorHex(c.id) } : undefined}
                title={have ? c.names[f] : say(`Earned by: ${earnedBy(c)}`, `earned: ${earnedBy(c).toLowerCase()}`)}
                onClick={() => set('color', c.id)}
              >
                {have ? <span class="dot" /> : <Icon name="padlock" size={14} />}
                <span class="sw-name">{c.names[f]}</span>
              </button>
            </li>
          );
        })}
      </ul>

      <h4 class="wardrobe-h">{say('Avatar frame', 'portrait frame')}</h4>
      <ul class="frames" aria-label="Avatar frame">
        <li>
          <button type="button" class="frame-pick" aria-pressed={frame == null} disabled={busy} onClick={() => set('frame', null)}>
            <Avatar spec={m.avatar} faction={f} level={m.level} lens={lens.value} size={56} />
            <span>{say('None', 'none')}</span>
          </button>
        </li>
        {shown('frame').map((c) => {
          const have = owned.has(c.id);
          return (
            <li key={c.id}>
              <button
                type="button" class={'frame-pick' + (have ? '' : ' locked')} aria-pressed={frame === c.id} disabled={busy || !have}
                title={have ? c.text : say(`Earned by: ${earnedBy(c)}`, `earned: ${earnedBy(c).toLowerCase()}`)}
                onClick={() => set('frame', c.id)}
              >
                {have
                  ? <FramedAvatar frame={c.id} spec={m.avatar} faction={f} level={m.level} lens={lens.value} size={68} />
                  : <span class="fp-lock"><Icon name="padlock" size={26} /></span>}
                <span>{c.names[f]}</span>
              </button>
            </li>
          );
        })}
      </ul>
      <p class="dim wardrobe-note">{say('Colours and frames are for sale in the Store, or earned. They show on your profile, the boards and your clan, never in a fight.', 'bought, or earned. shown on your profile, the boards and your clan. never in a fight.')}</p>
      <ErrorLine text={err} />
    </Section>
  );
}
