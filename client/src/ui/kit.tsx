import { signal } from '@preact/signals';
import type { ComponentChildren } from 'preact';
import './kit.css';

// ---- segmented control ----
interface SegProps<T extends string> {
  value: T;
  options: { id: T; label: string }[];
  onChange: (v: T) => void;
  label: string;
}
export function Seg<T extends string>({ value, options, onChange, label }: SegProps<T>) {
  return (
    <div class="seg" role="group" aria-label={label}>
      {options.map((o) => (
        <button key={o.id} class="seg-btn" aria-pressed={value === o.id} onClick={() => onChange(o.id)}>{o.label}</button>
      ))}
    </div>
  );
}

// ---- progress meter ----
export function Meter({ value, max, label, kind = 'xp' }: { value: number; max: number; label: string; kind?: 'xp' | 'hp' | 'plain' }) {
  const f = max > 0 ? Math.max(0, Math.min(1, value / max)) : 0;
  return (
    <div class={'bar ' + (kind === 'xp' ? 'xp' : '')} role="progressbar" aria-valuemin={0} aria-valuemax={max} aria-valuenow={value} aria-label={label}>
      <i class="fill" style={{ width: `${f * 100}%`, background: kind === 'plain' ? 'var(--text)' : undefined }} />
    </div>
  );
}

// ---- a button that explains why it is off ----
interface ActionProps {
  children: ComponentChildren;
  onClick: () => void;
  reason?: string | null;
  busy?: boolean;
  primary?: boolean;
  danger?: boolean;
  block?: boolean;
  id: string;
}
export function Action({ children, onClick, reason, busy, primary, danger, block, id }: ActionProps) {
  const off = !!reason || !!busy;
  return (
    <div class={'action' + (block ? ' block' : '')}>
      <button
        class={'btn' + (primary ? ' primary' : '') + (danger ? ' danger' : '') + (block ? ' block' : '')}
        disabled={off}
        aria-disabled={off}
        aria-describedby={reason ? id : undefined}
        onClick={onClick}
      >{busy ? '…' : children}</button>
      {reason && <p class="reason" id={id}>{reason}</p>}
    </div>
  );
}

// ---- toasts ----
export interface Toast { id: number; text: string; kind: 'info' | 'echo' | 'good' | 'bad'; act?: () => void }
export const toasts = signal<Toast[]>([]);
let toastId = 1;
export function pushToast(text: string, kind: Toast['kind'] = 'info', act?: () => void) {
  const id = toastId++;
  toasts.value = [...toasts.value.slice(-2), { id, text, kind, act }];
  window.setTimeout(() => { toasts.value = toasts.value.filter((t) => t.id !== id); }, 4500);
}
export function Toasts() {
  if (!toasts.value.length) return null;
  return (
    <div class="toasts" role="status" aria-live="polite">
      {toasts.value.map((t) => (
        <button key={t.id} class={'toast ' + t.kind} onClick={() => { toasts.value = toasts.value.filter((x) => x.id !== t.id); t.act?.(); }}>{t.text}</button>
      ))}
    </div>
  );
}

// ---- section header ----
export function Section({ title, aside, children, id }: { title: string; aside?: ComponentChildren; children: ComponentChildren; id?: string }) {
  return (
    <section class="sect" id={id}>
      <h3 class="display sect-h"><span>{title}</span>{aside != null && <span class="dim num sect-aside">{aside}</span>}</h3>
      {children}
    </section>
  );
}

export function ErrorLine({ text }: { text: string | null }) {
  return text ? <p class="reason err" role="alert">{text}</p> : null;
}
