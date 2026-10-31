import type { Fix } from './geo';

export type SourceKind = 'real' | 'sim';

/** Anything that can tell the game where the player is. */
export interface LocationSource {
  readonly kind: SourceKind;
  start(): void;
  stop(): void;
  /** Subscribe to fixes; returns an unsubscribe function. Called immediately if a fix exists. */
  subscribe(fn: (fix: Fix) => void, onError?: (msg: string) => void): () => void;
  current(): Fix | null;
}

export class Emitter {
  protected fns = new Set<(fix: Fix) => void>();
  protected errs = new Set<(msg: string) => void>();
  protected last: Fix | null = null;

  current() { return this.last; }

  subscribe(fn: (fix: Fix) => void, onError?: (msg: string) => void) {
    this.fns.add(fn);
    if (onError) this.errs.add(onError);
    if (this.last) fn(this.last);
    return () => {
      this.fns.delete(fn);
      if (onError) this.errs.delete(onError);
    };
  }

  protected emit(fix: Fix) {
    this.last = fix;
    this.fns.forEach((f) => f(fix));
  }
  protected fail(msg: string) { this.errs.forEach((f) => f(msg)); }
}
