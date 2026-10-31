import { signal } from '@preact/signals';
import { catalog, faction, me } from '../state/store';
import { say } from '../ui/voice';
import { Icon } from '../ui/Icon';
import './shell.css';

const now = signal(Date.now());
setInterval(() => { now.value = Date.now(); }, 1000);

export function clock(ms: number): string {
  const s = Math.max(0, Math.ceil(ms / 1000));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
  return h ? `${h}:${String(m).padStart(2, '0')}:${String(r).padStart(2, '0')}` : `${m}:${String(r).padStart(2, '0')}`;
}

function buffName(kind: string): string {
  const f = faction.value ?? 'human';
  return catalog.value?.consumables.find((c) => c.id === kind)?.names[f] ?? catalog.value?.store.find((s) => s.sku === kind)?.name ?? kind.replace(/^buff_/, '').replace(/_/g, ' ');
}

export function Vitals() {
  const m = me.value;
  if (!m) return null;
  const hp = Math.max(0, Math.min(1, m.hp / m.max_hp));
  const xp = m.xp_next > 0 ? Math.min(1, m.xp / m.xp_next) : 0;
  const downed = m.downed_until && m.downed_until > now.value ? m.downed_until - now.value : 0;
  const buffs = m.buffs.filter((b) => b.until > now.value);
  return (
    <section class="vitals" aria-label="Vitals">
      <div class="vitals-row">
        <span class="lab">HP</span>
        <div class="bar" role="progressbar" aria-valuemin={0} aria-valuemax={m.max_hp} aria-valuenow={m.hp} aria-label="Health">
          <i class="trail" style={{ width: `${hp * 100}%` }} />
          <i class="fill" style={{ width: `${hp * 100}%`, transition: 'width .25s var(--ease)' }} />
        </div>
        <span class="val num">{Math.round(m.hp)} / {m.max_hp}</span>
      </div>
      <div class="bar xp thin xp-row" role="progressbar" aria-valuemin={0} aria-valuemax={m.xp_next} aria-valuenow={m.xp} aria-label="Experience">
        <i class="fill" style={{ width: `${xp * 100}%` }} />
      </div>
      {buffs.length > 0 && (
        <div class="chips">
          {buffs.map((b) => (
            <span class="chip" key={b.kind}><Icon name="lightning-helix" size={14} />{buffName(b.kind)} {clock(b.until - now.value)}</span>
          ))}
        </div>
      )}
      {downed > 0 && (
        <div class="downed" role="status">
          <span>{say('Downed. No fights until you recover.', 'down. the world goes on without you.')}</span>
          <span class="num">{clock(downed)}</span>
        </div>
      )}
    </section>
  );
}
