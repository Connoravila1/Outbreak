//! SHELL. Spunky — the interaction-feel module: spring physics, gesture
//! feel, and hit testing. Pure functions over plain data, tested without a
//! screen.
//!
//! ORIGIN. Vendored by copy from our own `spunky` side-project — it is
//! first-party code, not a third-party package, so F1 does not apply: there
//! is nothing to justify importing and nothing external to remove. It is kept
//! in sync by re-copying the four files, exactly as spunky's own README asks
//! ("copy the directory; don't package-manage it" — the F2 posture). To
//! remove it: delete `src/spunky/`, its four `@embedFile` lines in
//! `guard.zig`, and its re-export in `root.zig`.
//!
//! CLASSIFICATION — SHELL, and float. Every value here is an f32: a spring's
//! position/velocity, a scroll offset, a screen-pixel rectangle. By the same
//! reasoning that puts `render/quads.zig` in the shell, this is shell — the
//! coordinate wall (B6) forbids a float in a CORE file bluntly and textually,
//! and it is not weakened because these floats are screen pixels rather than
//! latitudes. It is pure regardless (no clock, no RNG, no I/O; `dt` and
//! timestamps are parameters), so it is fully tested on a laptop.
//!
//! THE BOUNDARY — where this is allowed to touch, and where it is not.
//!   * It animates PRESENTATION values (a drawer's open fraction, a menu's
//!     scroll offset, the war-globe's spin) and hit-tests SCREEN rectangles.
//!   * It never sees a `CellId`, a tell, a fight, an occupant count, or an
//!     identity. There is no data in this module from which a position, a
//!     bearing, a distance, a who, or a sub-quorum count could be inferred —
//!     it is inert with respect to Section I (I1–I3, I5). The one standing
//!     caution is on WIRING: an animation must never be driven by a hostile's
//!     position or a below-k count, because no such value may exist to drive
//!     it.
//!   * It is NOT imported by `ui.zig` — the integer-only UI core, where the
//!     guard keeps floats out. Game/screen STATE (which screen, faction,
//!     what the server told us) stays in `ui.zig`, pure and integer.
//!     Pure-motion VIEW state (a spring mid-flight, a fling's momentum) lives
//!     here, driven by the shell's frame loop. The dividing question: does
//!     the value change what the server is told or which screen we are on?
//!     Then it is `ui.zig`. Is it presentation motion only? Then it is here.
//!
//! STATUS — vendored, classified, tested, and UNWIRED. Adopted ahead of the
//! experience layer's motion work (the war-globe and scrollable menus in
//! EXPERIENCE_DESIGN) because that need is on the roadmap and this code is
//! already proven. No screen consumes it yet; the call sites land with those
//! features. See `gesture.zig` first when they do — Outbreak has no
//! fling/momentum/rubber-band vocabulary today, and that is the real gap.

pub const spring = @import("spring.zig");
pub const gesture = @import("gesture.zig");
pub const hit = @import("hit.zig");

test {
    _ = spring;
    _ = gesture;
    _ = hit;
}
