import type { ComponentChildren } from 'preact';
import { useEffect, useRef } from 'preact/hooks';
import { createPortal } from 'preact/compat';
import { pushBack } from './back';
import './sheet.css';

interface Props {
  title: string;
  onClose: () => void;
  children: ComponentChildren;
  /** Sit above the vitals/tab bars (default) or cover the whole phone. */
  tall?: boolean;
}

/** Bottom sheet inside the phone column. Esc or the scrim closes it; focus moves in. */
export function Sheet({ title, onClose, children, tall }: Props) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null;
    ref.current?.focus();
    const key = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', key);
    const unback = pushBack(onClose);
    return () => { unback(); window.removeEventListener('keydown', key); prev?.focus?.(); };
  }, []);
  const node = (
    <div class="sheet-root">
      <div class="scrim" onClick={onClose} />
      <section class={'sheet' + (tall ? ' tall' : '')} role="dialog" aria-modal="true" aria-label={title} tabIndex={-1} ref={ref}>
        <div class="grip" aria-hidden="true" />
        <div class="sheet-body scroll">{children}</div>
      </section>
    </div>
  );
  // Tabs scroll and stack on their own; the sheet lives on the viewport so it always sits on top.
  const host = document.querySelector('.viewport');
  return host ? createPortal(node, host) : node;
}
