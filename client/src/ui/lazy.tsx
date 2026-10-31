import { signal } from '@preact/signals';
import type { ComponentChild, FunctionComponent } from 'preact';

export type Lazy<P> = FunctionComponent<P> & { preload: () => Promise<void> };

/**
 * A component whose code is fetched on first use (or earlier via `.preload()`), so the main bundle
 * stays small. Renders `fallback` until it arrives.
 */
export function lazy<P extends object>(load: () => Promise<FunctionComponent<P>>, fallback: ComponentChild = null): Lazy<P> {
  const loaded = signal<{ C: FunctionComponent<P> } | null>(null);
  let pending: Promise<void> | null = null;
  const preload = () => (pending ??= load().then((C) => { loaded.value = { C }; }, (e) => { pending = null; throw e; }));
  const Comp = ((props: P) => {
    const l = loaded.value;
    if (!l) { void preload().catch(() => undefined); return <>{fallback}</>; }
    return <l.C {...props} />;
  }) as Lazy<P>;
  Comp.preload = preload;
  return Comp;
}
