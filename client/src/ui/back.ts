// Stack of "close me" handlers for the Android back button. Overlays register while open.
const stack: Array<() => void> = [];

/** Register a handler; returns the unregister function. Last in, first closed. */
export function pushBack(fn: () => void): () => void {
  stack.push(fn);
  return () => {
    const i = stack.lastIndexOf(fn);
    if (i >= 0) stack.splice(i, 1);
  };
}

/** Close the topmost overlay. Returns false when nothing was open. */
export function handleBack(): boolean {
  const fn = stack[stack.length - 1];
  if (!fn) return false;
  fn();
  return true;
}

// Escape does what the back button does: close the topmost overlay, and only that one.
if (typeof window !== 'undefined') {
  window.addEventListener('keydown', (e) => { if (e.key === 'Escape' && handleBack()) e.preventDefault(); });
}
