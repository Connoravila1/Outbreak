// Decides when sound happens without the screens having to ask: unlocking on the first touch, beds per
// screen, taps, tab switches, sheets, refusals, downed/revived, hostile pings and echo reports.
// Screens still call fx.* directly for the moments that carry meaning (a fight, a reward, a purchase).
import { effect, signal } from '@preact/signals';
import { lens, me, phase, tab, world } from '../state/store';
import { toasts } from '../ui/kit';
import { current } from '../battle/session';
import { marks, refreshBeds, setBed } from './engine';
import * as fx from './fx';

let started = false;

export function initAudio() {
  if (started) return;
  started = true;

  // Browsers only let audio start from a gesture; any first touch will do.
  const unlockOnce = () => {
    fx.unlockAudio();
    refreshBeds();
  };
  for (const ev of ['pointerdown', 'touchend', 'keydown', 'click'] as const) {
    window.addEventListener(ev, unlockOnce, { capture: true, passive: true });
  }

  // ---- beds: theme in onboarding and menus, ambience on the map, quiet during a fight ----
  // The theme waits for the emergency broadcast to finish before it comes in underneath.
  const nudge = signal(0);
  let wake = 0;
  effect(() => {
    const p = phase.value, t = tab.value, inBattle = !!current.value, l = lens.value;
    nudge.value;
    window.clearTimeout(wake);
    if (p === 'boot' || p === 'server') { setBed('ambience', null); setBed('music', null); return; }
    if (p === 'onboarding') {
      setBed('ambience', null);
      const wait = marks.broadcastAt ? marks.broadcastAt + 8000 - performance.now() : 0;
      if (wait > 0) { setBed('music', null); wake = window.setTimeout(() => { nudge.value++; }, wait); } else setBed('music', 'theme');
      return;
    }
    if (inBattle) { setBed('ambience', null); setBed('music', null); return; }
    if (t === 'map') { setBed('music', null); setBed('ambience', l === 'heat' ? 'amb_map.z' : 'amb_map.h'); return; }
    setBed('ambience', null);
    setBed('music', 'theme');
  });

  // ---- tab switches ----
  let lastTab = tab.peek();
  effect(() => {
    const t = tab.value;
    if (t !== lastTab) { lastTab = t; fx.tabSwitch(); }
  });

  // ---- taps: any enabled button that does not have a sound of its own ----
  document.addEventListener('click', (e) => {
    const el = (e.target as HTMLElement | null)?.closest?.('button, .btn, [role="button"]') as HTMLElement | null;
    if (!el || (el as HTMLButtonElement).disabled || el.getAttribute('aria-disabled') === 'true') return;
    if (el.closest('[role="tab"], .tabbar, .toast, .hold-btn')) return;
    fx.tap();
  }, { capture: true });

  // ---- sheets opening and closing, refusals appearing ----
  const isSheet = (n: Node) => n instanceof HTMLElement && (n.classList.contains('sheet-root') || !!n.querySelector?.('.sheet-root'));
  const isAlert = (n: Node) => n instanceof HTMLElement && (n.getAttribute('role') === 'alert' || !!n.querySelector?.('[role="alert"]'));
  let ready = false;
  window.setTimeout(() => { ready = true; }, 1500);
  new MutationObserver((muts) => {
    if (!ready) return;
    let open = false, close = false, bad = false;
    for (const m of muts) {
      m.addedNodes.forEach((n) => { if (isSheet(n)) open = true; else if (isAlert(n)) bad = true; });
      m.removedNodes.forEach((n) => { if (isSheet(n)) close = true; });
    }
    if (open) fx.sheetOpen(); else if (close) fx.sheetClose();
    if (bad) fx.error();
  }).observe(document.body, { childList: true, subtree: true });

  // ---- toasts: refusals and echo reports ----
  let seen = toasts.peek().length ? toasts.peek()[toasts.peek().length - 1].id : 0;
  effect(() => {
    for (const t of toasts.value) {
      if (t.id <= seen) continue;
      seen = t.id;
      if (t.kind === 'bad') fx.error();
      else if (t.kind === 'echo') fx.echoReport();
    }
  });

  // ---- downed / back up ----
  let wasDown: boolean | null = null;
  effect(() => {
    const m = me.value;
    if (!m) return;
    const down = !!m.downed_until && m.downed_until > Date.now();
    if (wasDown !== null && down !== wasDown && phase.peek() === 'app') { if (down) fx.downed(); else fx.revived(); }
    wasDown = down;
  });

  // ---- a hostile signal appears nearby ----
  let near = false;
  effect(() => {
    const n = !!world.value?.hostiles_near;
    if (n && !near && !current.peek() && phase.peek() === 'app') fx.ping();
    near = n;
  });
}
