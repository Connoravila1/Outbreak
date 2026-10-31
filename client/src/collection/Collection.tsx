import { useEffect, useState } from 'preact/hooks';
import type { CatalogAchievement, CatalogEnemy, CatalogItem, Rarity } from '../api';
import { catalog, faction, me } from '../state/store';
import { ARCH_ICON } from '../state/objects';
import { SLOT_ICON, SLOTS, slotLabel } from '../gear/util';
import { say } from '../ui/voice';
import { Sheet } from '../ui/Sheet';
import { Icon } from '../ui/Icon';
import { ErrorLine, Meter, Seg } from '../ui/kit';
import { achievementList, collection, collectionError, loadCollection } from './store';
import './collection.css';

type Tab = 'bestiary' | 'gear' | 'medals';

const RARITIES: Rarity[] = ['common', 'uncommon', 'rare', 'legendary'];
const RARITY_NAME: Record<Rarity, [string, string]> = {
  common: ['Common', 'common'], uncommon: ['Uncommon', 'uncommon'], rare: ['Rare', 'rare'], legendary: ['Legendary', 'legendary'],
};

/** Counts for the card and the log's header: what is known, out of what exists. */
function useTally() {
  const m = me.value;
  const cat = catalog.value;
  const enemies = (cat?.enemies ?? []).filter((e) => m && e.id in m.bestiary);
  const met = enemies.filter((e) => (m?.bestiary[e.id] ?? 0) > 0).length;
  const col = collection.value;
  const things = (cat?.items.length ?? 0) + (cat?.uniques.length ?? 0);
  const seen = (col?.bases.length ?? 0) + (col?.uniques.length ?? 0);
  return { enemies: enemies.length, met, things, seen, loaded: !!col, medals: m?.achievements?.earned ?? 0, medalTotal: m?.achievements?.total ?? cat?.achievements?.length ?? 0 };
}

/** The card on the You tab that opens the log. */
export function CollectionEntry() {
  const [open, setOpen] = useState(false);
  const t = useTally();
  useEffect(() => { void loadCollection(); }, []);
  return (
    <>
      <button type="button" class="card col-entry" onClick={() => setOpen(true)}>
        <Icon name="treasure-map" size={30} />
        <span class="col-entry-main">
          <b class="display col-entry-h">{say('Collection log', 'what you have had')}</b>
          <small class="dim">
            {say('Bestiary', 'bestiary')} {t.met}/{t.enemies} · {say('Gear', 'gear')} {t.loaded ? `${t.seen}/${t.things}` : '…'} · {say('Achievements', 'marks')} {t.medals}/{t.medalTotal}
          </small>
        </span>
        <span class="col-go" aria-hidden="true">›</span>
      </button>
      {open && <CollectionLog onClose={() => setOpen(false)} />}
    </>
  );
}

/** The log itself: bestiary, gear seen, achievements, and the way to the notes archive. */
export function CollectionLog({ onClose }: { onClose: () => void }) {
  const [tab, setTab] = useState<Tab>('bestiary');
  const m = me.value;
  const t = useTally();
  useEffect(() => { void loadCollection(); }, []);
  if (!m) return null;
  const toArchive = () => {
    onClose();
    window.setTimeout(() => document.getElementById('archive')?.scrollIntoView({ behavior: 'smooth', block: 'start' }), 120);
  };
  return (
    <Sheet title={say('Collection log', 'what you have had')} onClose={onClose} tall>
      <div class="col-log">
        <h2 class="display col-title">{say('Collection log', 'what you have had')}</h2>
        <div class="col-sum">
          <span class="card"><b class="num">{t.met}/{t.enemies}</b><small>{say('met', 'met')}</small></span>
          <span class="card"><b class="num">{t.loaded ? `${t.seen}/${t.things}` : '…'}</b><small>{say('gear seen', 'gear had')}</small></span>
          <span class="card"><b class="num">{t.medals}/{t.medalTotal}</b><small>{say('achievements', 'marks')}</small></span>
        </div>
        <button type="button" class="card col-notes" onClick={toArchive}>
          <Icon name="scroll-unfurled" size={22} />
          <span class="col-notes-main"><b>{say('Found notes', 'what was left')}</b><small class="dim">{m.notes ? `${m.notes.found}/${m.notes.total}` : ''}</small></span>
          <span class="col-go">{say('Open the archive', 'read them')} ›</span>
        </button>
        <Seg<Tab>
          label="Collection section" value={tab} onChange={setTab}
          options={[{ id: 'bestiary', label: say('Bestiary', 'bestiary') }, { id: 'gear', label: say('Gear', 'gear') }, { id: 'medals', label: say('Achievements', 'marks') }]}
        />
        <ErrorLine text={collectionError.value} />
        {tab === 'bestiary' && <Bestiary />}
        {tab === 'gear' && <GearSeen />}
        {tab === 'medals' && <Achievements />}
      </div>
    </Sheet>
  );
}

// ---- bestiary ----

function BeastRow({ e, n }: { e: CatalogEnemy; n: number }) {
  const f = faction.value ?? 'human';
  const known = n > 0;
  const hint = n >= 3 ? (f === 'zombie' ? e.hint_zombie ?? e.hint : e.hint) : null;
  return (
    <li class={'card beast' + (known ? '' : ' unseen')}>
      <span class="beast-ico"><Icon name={ARCH_ICON[e.id] ?? 'target-dummy'} size={34} /></span>
      <span class="beast-main">
        <b>{known ? e.names[f] : '???'}</b>
        <small class="dim">{known ? ((f === 'zombie' ? e.text_zombie : null) ?? e.text) : say('Not met yet.', 'not met.')}</small>
        {hint && <small class="beast-hint">{hint}</small>}
      </span>
      <span class="num beast-n">{known ? <><b>{n}</b><small>{n === 1 ? say('fight', 'fight') : say('fights', 'fights')}</small></> : '·'}</span>
    </li>
  );
}

function Bestiary() {
  const m = me.value!;
  const rows = (catalog.value?.enemies ?? []).filter((e) => e.id in m.bestiary);
  const elites = achievementList.value?.progress.elites;
  return (
    <>
      <p class="dim col-note">{say('Every kind of enemy you have fought, and how often. Fight one three times and you learn how to beat it.', 'what you have faced. face one enough and you learn how it dies.')}</p>
      <ul class="col-list">{rows.map((e) => <BeastRow key={e.id} e={e} n={m.bestiary[e.id] ?? 0} />)}</ul>
      {elites != null && (
        <p class="card col-extra"><Icon name="crown" size={20} /> <span>{say('Elites defeated', 'marked prey taken')}</span> <b class="num">{elites}</b></p>
      )}
    </>
  );
}

// ---- gear seen ----

function ItemRow({ it, seen }: { it: CatalogItem; seen: boolean }) {
  const f = faction.value ?? 'human';
  return (
    <li class={'card gear-seen' + (seen ? '' : ' unseen')}>
      <span class="beast-ico"><Icon name={SLOT_ICON[it.slot]} size={26} /></span>
      <span class="beast-main">
        <b>{seen ? it.names[f] : '???'}</b>
        <small class="dim">{seen ? say(`Level ${it.req}`, `level ${it.req}`) : say(`Turns up around level ${it.req}`, `around level ${it.req}`)}</small>
      </span>
      {seen && <Icon name="check-mark" size={18} />}
    </li>
  );
}

function GearSeen() {
  const cat = catalog.value;
  const col = collection.value;
  const f = faction.value ?? 'human';
  if (!cat || !col) return <p class="empty dim">…</p>;
  const seenBase = new Set(col.bases);
  const seenRarity = new Set<string>(col.rarities);
  const seenUnique = new Set(col.uniques);
  return (
    <>
      <p class="dim col-note">{say('Everything that has ever been in your pack, scrapped or not.', 'everything that has ever been in you, spent or kept.')}</p>
      <div class="rarity-row" role="list" aria-label="Rarities seen">
        {RARITIES.map((r) => (
          <span key={r} role="listitem" class={'chip rarity-' + r + (seenRarity.has(r) ? ' on' : '')}>
            {seenRarity.has(r) ? RARITY_NAME[r][faction.value === 'zombie' ? 1 : 0] : '???'}
          </span>
        ))}
      </div>
      {SLOTS.map((s) => {
        const list = cat.items.filter((i) => i.slot === s).sort((a, b) => a.req - b.req);
        return (
          <section key={s} class="col-group">
            <h4 class="display col-group-h"><span>{slotLabel(s)}</span><span class="num dim">{list.filter((i) => seenBase.has(i.id)).length}/{list.length}</span></h4>
            <ul class="col-list">{list.map((i) => <ItemRow key={i.id} it={i} seen={seenBase.has(i.id)} />)}</ul>
          </section>
        );
      })}
      <section class="col-group">
        <h4 class="display col-group-h"><span>{say('Named Legendaries', 'named')}</span><span class="num dim">{col.uniques.length}/{cat.uniques.length}</span></h4>
        <ul class="col-list">
          {cat.uniques.map((u) => {
            const seen = seenUnique.has(u.id);
            return (
              <li key={u.id} class={'card gear-seen rarity-legendary-row' + (seen ? '' : ' unseen')}>
                <span class="beast-ico"><Icon name={seen ? 'crown' : 'padlock'} size={26} /></span>
                <span class="beast-main">
                  <b>{seen ? u.names[f] : '???'}</b>
                  <small class="dim">{seen ? (f === 'zombie' ? u.lore_zombie ?? u.lore : u.lore) : say('Rare. One in six Legendaries.', 'rare. one in six.')}</small>
                </span>
              </li>
            );
          })}
        </ul>
      </section>
    </>
  );
}

// ---- achievements ----

const km = (m: number) => (m / 1000).toLocaleString(undefined, { maximumFractionDigits: 1 });

/** "3 / 10" in the units the metric counts. Null where a count would read oddly. */
function progressText(a: CatalogAchievement, v: number): string | null {
  switch (a.metric) {
    case 'best_rarity': return null;
    case 'distance_m': return `${km(Math.min(v, a.need))} / ${km(a.need)} km`;
    case 'days': return `${Math.min(v, a.need)} / ${a.need} ${say('days', 'days')}`;
    case 'best_upgrade': return `+${Math.min(v, a.need)} / +${a.need}`;
    default: return `${Math.min(v, a.need).toLocaleString()} / ${a.need.toLocaleString()}`;
  }
}

function cosmeticName(id: string): string {
  const f = faction.value ?? 'human';
  return catalog.value?.cosmetics?.find((c) => c.id === id)?.names[f] ?? id;
}

function AchievementRow({ a, earned, value }: { a: CatalogAchievement; earned: boolean; value: number }) {
  const f = faction.value ?? 'human';
  const text = earned ? null : progressText(a, value);
  return (
    <li class={'card ach-row' + (earned ? ' earned' : '')}>
      <span class="ach-ico"><Icon name={earned ? 'trophy' : 'padlock'} size={24} /></span>
      <span class="ach-main">
        <b>{a.names[f]}</b>
        <small class="dim">{a.text}</small>
        {!earned && a.metric !== 'best_rarity' && <Meter value={Math.min(value, a.need)} max={a.need} label={`${a.names[f]} progress`} kind="plain" />}
        {text && <small class="num ach-prog">{text}</small>}
        {(a.title || a.cosmetic) && (
          <small class="ach-reward">
            <Icon name="laurels" size={14} />{' '}
            {a.title && <>{say('Title', 'name')}: {a.title[f]}</>}
            {a.title && a.cosmetic && ' · '}
            {a.cosmetic && <>{say('Unlocks', 'unlocks')} {cosmeticName(a.cosmetic)}</>}
          </small>
        )}
      </span>
      <span class="ach-pay num"><Icon name="recycle" size={14} />{a.salvage}</span>
    </li>
  );
}

function Achievements() {
  const defs = catalog.value?.achievements ?? [];
  const list = achievementList.value;
  if (!defs.length) return <p class="empty">{say('This server has no achievements.', 'nothing to earn here.')}</p>;
  if (!list) return <p class="empty dim">…</p>;
  const got = new Set(list.earned.map((e) => e.id));
  const groups: { name: string; rows: CatalogAchievement[] }[] = [];
  for (const a of defs) {
    const g = groups[groups.length - 1];
    if (g && g.name === a.group) g.rows.push(a); else groups.push({ name: a.group, rows: [a] });
  }
  return (
    <>
      <p class="dim col-note">{say('Each one pays salvage once. Some give a title or a cosmetic.', 'each pays salvage once. some give a name, or a look.')}</p>
      {groups.map((g) => (
        <section key={g.name} class="col-group">
          <h4 class="display col-group-h"><span>{g.name}</span><span class="num dim">{g.rows.filter((r) => got.has(r.id)).length}/{g.rows.length}</span></h4>
          <ul class="col-list">
            {g.rows.map((a) => <AchievementRow key={a.id} a={a} earned={got.has(a.id)} value={list.progress[a.metric] ?? 0} />)}
          </ul>
        </section>
      ))}
    </>
  );
}
