import { useEffect } from 'preact/hooks';
import type { RefObject } from 'preact';

const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

/** Keep Tab inside a modal: from the last control it wraps to the first, and back. */
export function trapTab(e: KeyboardEvent, root: HTMLElement | null) {
  if (e.key !== 'Tab' || !root) return;
  const items = [...root.querySelectorAll<HTMLElement>(FOCUSABLE)].filter((el) => el.offsetParent !== null || el === document.activeElement);
  if (!items.length) { e.preventDefault(); root.focus(); return; }
  const first = items[0], last = items[items.length - 1];
  const at = document.activeElement;
  if (e.shiftKey && (at === first || at === root)) { e.preventDefault(); last.focus(); }
  else if (!e.shiftKey && at === last) { e.preventDefault(); first.focus(); }
}

/**
 * A modal layer: focus moves into it when it opens (the primary control, or the layer itself), Tab stays
 * inside, and focus returns to whatever had it before when the layer goes away.
 * `again` re-runs the move when the layer's content changes (a fight moving on to its result).
 */
export function useModalFocus(ref: RefObject<HTMLElement | null>, again?: unknown) {
  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null;
    const key = (e: KeyboardEvent) => trapTab(e, ref.current);
    window.addEventListener('keydown', key);
    return () => { window.removeEventListener('keydown', key); prev?.focus?.(); };
  }, []);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const t = window.setTimeout(() => {
      (el.querySelector<HTMLElement>('.btn.primary') ?? el).focus();
    }, 0);
    return () => clearTimeout(t);
  }, [again]);
}
