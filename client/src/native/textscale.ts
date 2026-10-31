// The phone's own text size (iOS Dynamic Type) feeds --ts-sys, so the default already follows the OS.
// Android is handled natively: MainActivity sets the WebView text zoom to the system font scale, and the
// page then sees larger text without any CSS change. Settings > Text size stacks on top of either.

/** iOS "Body" is 17 pt at the default Dynamic Type size. */
const IOS_BODY_PX = 17;

function measure(): number {
  if (typeof CSS === 'undefined' || !CSS.supports('font', '-apple-system-body')) return 1;
  const probe = document.createElement('span');
  probe.style.cssText = 'position:absolute;visibility:hidden;font:-apple-system-body;';
  probe.textContent = 'M';
  document.body.appendChild(probe);
  const px = parseFloat(getComputedStyle(probe).fontSize);
  probe.remove();
  if (!Number.isFinite(px) || px <= 0) return 1;
  return Math.min(2, Math.max(1, Math.round((px / IOS_BODY_PX) * 100) / 100));
}

/** Read the OS text size now and again whenever the app comes back to the front. */
export function followSystemTextSize() {
  const apply = () => document.documentElement.style.setProperty('--ts-sys', String(measure()));
  apply();
  document.addEventListener('visibilitychange', () => { if (!document.hidden) apply(); });
}
