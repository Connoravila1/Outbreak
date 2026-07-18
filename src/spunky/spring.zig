//! CORE (pure). A damped-harmonic-oscillator spring — the animation
//! primitive that makes motion feel physical.
//!
//! A spring models ONE scalar channel (e.g. a widget's scale, a scroll
//! offset, a drawer's open fraction) as a mass on a spring being pulled
//! toward `target`. Its motion is the damped harmonic oscillator: a
//! Hooke's-law pull toward target plus a velocity-proportional friction
//! that bleeds off energy so the overshoot rings out.
//!
//! Because the spring carries STATE (position + velocity), it can be
//! interrupted mid-flight and continue from its current velocity — the one
//! thing an easing curve physically cannot do, and the whole reason this
//! feels like iOS rather than like a lerp.
//!
//! PURE: no clock, no RNG, no I/O. `dt` is handed in by the caller;
//! given the same inputs the step produces the same output, so the physics
//! is fully unit-testable. The LOOK — how a position composes into a
//! transform, how it renders — is NOT here; this module owns only the
//! motion.

const std = @import("std");
const assert = std.debug.assert;

/// PLAIN DATA. One scalar spring channel — the HOT record: channels occur
/// in quantity and the step sweeps them in bulk. Fields only, no methods.
///
/// mass is fixed at 1 by the duration/bounce conversion (see `constants`)
/// and is therefore NOT stored — a constant 1.0 per channel would be dead
/// weight. A future non-unit-mass need would be a deliberate size-budget
/// amendment.
pub const Spring = struct {
    position: f32, // current value of the channel
    velocity: f32, // current rate of change
    target: f32, // where it is heading
    stiffness: f32, // resolved from duration/bounce
    damping: f32, // resolved from duration/bounce

    comptime {
        // Budget: five f32, processed in bulk. Packed size is 20 bytes
        // with no padding (all fields 4-byte aligned).
        assert(@sizeOf(Spring) == 20);
    }
};

/// The two physical constants a spring integrates with, resolved from the
/// friendly duration/bounce front door.
pub const Constants = struct {
    stiffness: f32,
    damping: f32,
};

/// Fixed integrator sub-step. Smaller than any real frame, so every frame
/// takes at least one sub-step and the motion is frame-rate independent.
pub const sub_step: f32 = 1.0 / 240.0;

/// Per-frame accumulator clamp. After a long stall (app backgrounded, a
/// breakpoint) we must not run thousands of catch-up sub-steps — the
/// "spiral of death." A clamped catch-up just fast-forwards the settle,
/// which is the correct visible behaviour.
pub const max_accum: f32 = 0.25;

/// Rest thresholds. A spring's math never truly reaches rest; we declare
/// rest when the motion is imperceptible and snap it exactly to target.
pub const rest_eps: f32 = 1.0e-3;
pub const rest_vel_eps: f32 = 1.0e-3;

/// The tuning front door. Convert a PERCEPTUAL `duration` (seconds — how
/// long the meaningful part of the motion takes) and a `bounce` (~[-1, 1]:
/// 0 = no overshoot / critically damped, positive = bouncy / underdamped,
/// negative = lazy / overdamped) into the physical constants the integrator
/// uses. Pure and comptime-usable, so presets resolve at compile time.
///
/// mass is fixed at 1, so with stiffness k the natural frequency is sqrt(k)
/// and critical damping is 2*sqrt(k) = 4*pi/duration. bounce scales damping
/// away from (bounce > 0) or past (bounce < 0) that critical value.
pub fn constants(bounce: f32, duration: f32) Constants {
    const pi: f32 = std.math.pi;
    // The bounce = -1 singularity (damping → ∞) is defined out of existence
    // by clamping just shy of it; callers pass sane presets (~0.15–0.30).
    const b = std.math.clamp(bounce, -0.99, 1.0);
    const omega = (2.0 * pi) / duration;
    const critical = (4.0 * pi) / duration;
    const stiffness = omega * omega;
    const damping = if (b >= 0)
        (1.0 - b) * critical
    else
        critical / (1.0 + b);
    return .{ .stiffness = stiffness, .damping = damping };
}

/// True when the spring's motion is imperceptible — within `rest_eps` of
/// target and slower than `rest_vel_eps`. Pure predicate.
pub fn atRest(s: Spring) bool {
    return @abs(s.position - s.target) < rest_eps and @abs(s.velocity) < rest_vel_eps;
}

/// The SoA view of the spring set: a `MultiArrayList(Spring)` slice. The
/// step sweeps the `position`/`velocity` columns linearly — the
/// cache-honest access pattern and the reason SoA is mandated over AoS.
pub const Slice = std.MultiArrayList(Spring).Slice;

/// THE INTERRUPTIBILITY. Point spring `i` at a new target WITHOUT touching
/// its position or velocity. This one tiny function is the whole reason a
/// spring beats an easing curve: an in-flight element that gets retargeted
/// (a second item arrives, the list reflows, the keyboard opens) keeps its
/// current momentum and curves smoothly toward the new goal — no restart,
/// no snap.
///
/// A settled spring is inactive, so retargeting also RE-ACTIVATES it —
/// otherwise the step would skip it and the nudge would do nothing.
pub fn retarget(s: Slice, active: []bool, i: usize, new_target: f32) void {
    assert(i < s.len);
    assert(active.len == s.len);
    s.items(.target)[i] = new_target;
    const pos = s.items(.position)[i];
    const vel = s.items(.velocity)[i];
    if (@abs(pos - new_target) >= rest_eps or @abs(vel) >= rest_vel_eps) {
        active[i] = true;
    }
}

/// THE HEART. Advance every ACTIVE spring in the set by real frame time
/// `dt`, using the fixed-step accumulator + semi-implicit Euler, then run
/// rest detection.
///
/// - `s`      : the SoA columns, mutated in place.
/// - `active` : out-of-band activeness (a separate array, not a bool field
///              bloating the hot record). An inactive spring is skipped; a
///              spring that reaches rest this frame is snapped to target and
///              marked inactive here, so the active set shrinks back toward
///              empty on its own.
/// - `dt`     : the real frame delta (seconds), the shell's ONE clock read.
/// - `acc`    : the caller-owned fixed-step remainder, carried across frames.
///
/// `dt` is a PARAMETER — the core never reads a clock. Given the same slice
/// contents, `active`, `dt`, and `acc`, the result is identical: deterministic
/// and frame-rate independent.
pub fn stepSprings(s: Slice, active: []bool, dt: f32, acc: *f32) void {
    assert(active.len == s.len);
    const pos = s.items(.position);
    const vel = s.items(.velocity);
    const tgt = s.items(.target);
    const stiff = s.items(.stiffness);
    const damp = s.items(.damping);

    acc.* = @min(acc.* + dt, max_accum);
    while (acc.* >= sub_step) : (acc.* -= sub_step) {
        for (pos, vel, tgt, stiff, damp, active) |*p, *v, t, k, c, a| {
            if (!a) continue;
            // Semi-implicit (symplectic) Euler: update velocity FIRST, then
            // use the already-updated velocity to move position. One line
            // different from explicit Euler, same cost, stable across the
            // tuning range.
            const accel = -k * (p.* - t) - c * v.*; // mass = 1
            v.* += accel * sub_step;
            p.* += v.* * sub_step;
        }
    }

    // Rest detection: a settled spring snaps exactly to target and drops out
    // of the active set.
    for (pos, vel, tgt, active) |*p, *v, t, *a| {
        if (!a.*) continue;
        if (@abs(p.* - t) < rest_eps and @abs(v.*) < rest_vel_eps) {
            p.* = t;
            v.* = 0;
            a.* = false;
        }
    }
}

/// Advance ONE scalar spring channel by real frame time `dt`. The
/// single-channel convenience over the same semi-implicit integrator
/// `stepSprings` uses, for callers animating a lone value (a nav drawer's
/// open fraction, a scroll bounce) where a pooled World is ceremony.
/// Sub-steps are derived from `dt` each call, so the motion is frame-rate
/// independent without a caller-owned accumulator.
pub fn stepScalar(pos: *f32, vel: *f32, target: f32, c: Constants, dt: f32) void {
    const d = std.math.clamp(dt, 0.0, max_accum);
    const n: u32 = @intFromFloat(@ceil(d / sub_step));
    if (n == 0) return;
    const h = d / @as(f32, @floatFromInt(n));
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const accel = -c.stiffness * (pos.* - target) - c.damping * vel.*;
        vel.* += accel * h;
        pos.* += vel.* * h;
    }
}

// ---------------------------------------------------------------------------
// THE MODULE. `World` owns the spring set and is the ONLY way callers touch
// springs: they hold opaque `Handle`s, never bare indexes. The SoA columns,
// the free-list, the sub-step size, and the integrator choice are all sealed
// inside — a caller sees stable handles in and plain values out.
// ---------------------------------------------------------------------------

/// A stable reference to one spring slot, safe across free-list reuse. The
/// `generation` is bumped when a slot is released, so a handle to a released
/// (and possibly re-used) slot is detectably stale — no use-after-release.
/// Handles cross the module boundary as values; bare indexes never do.
pub const Handle = struct {
    index: u32,
    generation: u32,

    comptime {
        assert(@sizeOf(Handle) == 8);
    }
};

/// The animation state. One instance per animating surface, never held in a
/// collection. It owns all of its memory: the springs SoA, the out-of-band
/// `active`/`live`/`generation` columns, the free-list of reclaimed slots,
/// and the shared fixed-step accumulator remainder.
pub const World = struct {
    springs: std.MultiArrayList(Spring),
    active: std.ArrayListUnmanaged(bool),
    live: std.ArrayListUnmanaged(bool),
    generation: std.ArrayListUnmanaged(u32),
    free: std.ArrayListUnmanaged(u32),
    acc: f32,

    pub const empty: World = .{
        .springs = .empty,
        .active = .empty,
        .live = .empty,
        .generation = .empty,
        .free = .empty,
        .acc = 0,
    };

    pub fn deinit(w: *World, alloc: std.mem.Allocator) void {
        w.springs.deinit(alloc);
        w.active.deinit(alloc);
        w.live.deinit(alloc);
        w.generation.deinit(alloc);
        w.free.deinit(alloc);
        w.* = undefined;
    }

    /// Allocate a spring, reusing a released slot when one is free, else
    /// appending. Born at `start` with zero velocity, aimed at `target`,
    /// using the resolved `c` constants. Returns an opaque handle.
    pub fn spawn(w: *World, alloc: std.mem.Allocator, start: f32, target: f32, c: Constants) !Handle {
        const born: Spring = .{
            .position = start,
            .velocity = 0,
            .target = target,
            .stiffness = c.stiffness,
            .damping = c.damping,
        };
        const moving = @abs(start - target) >= rest_eps;

        if (w.free.items.len > 0) {
            const idx = w.free.items[w.free.items.len - 1];
            w.free.items.len -= 1;
            w.springs.set(idx, born);
            w.active.items[idx] = moving;
            w.live.items[idx] = true;
            return .{ .index = idx, .generation = w.generation.items[idx] };
        }

        const idx: u32 = @intCast(w.springs.len);
        try w.springs.ensureUnusedCapacity(alloc, 1);
        try w.active.ensureUnusedCapacity(alloc, 1);
        try w.live.ensureUnusedCapacity(alloc, 1);
        try w.generation.ensureUnusedCapacity(alloc, 1);
        try w.free.ensureTotalCapacity(alloc, idx + 1);
        w.springs.appendAssumeCapacity(born);
        w.active.appendAssumeCapacity(moving);
        w.live.appendAssumeCapacity(true);
        w.generation.appendAssumeCapacity(0);
        return .{ .index = idx, .generation = 0 };
    }

    /// True while `h` still refers to its live slot.
    pub fn isLive(w: *const World, h: Handle) bool {
        return h.index < w.live.items.len and
            w.live.items[h.index] and
            w.generation.items[h.index] == h.generation;
    }

    /// Return a spring's slot to the free-list. Bumps the slot's generation
    /// so every outstanding handle becomes stale. Infallible: the free-list
    /// capacity was reserved at spawn. No-op on a stale handle.
    pub fn release(w: *World, h: Handle) void {
        if (!w.isLive(h)) return;
        w.live.items[h.index] = false;
        w.active.items[h.index] = false;
        w.generation.items[h.index] +%= 1;
        w.free.appendAssumeCapacity(h.index);
    }

    /// Point a live spring at a new target, carrying its momentum. No-op on
    /// a stale handle.
    pub fn setTarget(w: *World, h: Handle, new_target: f32) void {
        if (!w.isLive(h)) return;
        retarget(w.springs.slice(), w.active.items, h.index, new_target);
    }

    /// The current value of a live spring, or `null` if the handle is stale.
    pub fn position(w: *const World, h: Handle) ?f32 {
        if (!w.isLive(h)) return null;
        return w.springs.items(.position)[h.index];
    }

    /// True while a live spring is still animating (has not reached rest).
    pub fn isActive(w: *const World, h: Handle) bool {
        return w.isLive(h) and w.active.items[h.index];
    }

    /// Advance the whole world by one frame of real time `dt`.
    pub fn step(w: *World, dt: f32) void {
        if (w.springs.len == 0) return;
        stepSprings(w.springs.slice(), w.active.items, dt, &w.acc);
    }
};

// ---------------------------------------------------------------------------
// Tests. The integrator is fixed-step and clock-free, so these are exact
// and reproducible. They prove the PHYSICS is right before any pixel moves.
// ---------------------------------------------------------------------------

const testing = std.testing;

const spring_retarget = retarget;

const Harness = struct {
    list: std.MultiArrayList(Spring),
    active: [1]bool,
    acc: f32,

    fn init(alloc: std.mem.Allocator, start: f32, target: f32, c: Constants) !Harness {
        var list: std.MultiArrayList(Spring) = .empty;
        try list.append(alloc, .{
            .position = start,
            .velocity = 0,
            .target = target,
            .stiffness = c.stiffness,
            .damping = c.damping,
        });
        return .{ .list = list, .active = .{true}, .acc = 0 };
    }

    fn deinit(self: *Harness, alloc: std.mem.Allocator) void {
        self.list.deinit(alloc);
    }

    fn doStep(self: *Harness, dt: f32) void {
        stepSprings(self.list.slice(), self.active[0..], dt, &self.acc);
    }

    fn doRetarget(self: *Harness, new_target: f32) void {
        spring_retarget(self.list.slice(), self.active[0..], 0, new_target);
    }

    fn pos(self: *Harness) f32 {
        return self.list.slice().items(.position)[0];
    }
    fn vel(self: *Harness) f32 {
        return self.list.slice().items(.velocity)[0];
    }
};

test "spring converges to target for a range of presets" {
    const presets = [_]Constants{
        constants(0.0, 0.35),
        constants(0.25, 0.35),
        constants(0.6, 0.40),
        constants(-0.3, 0.40),
    };
    for (presets) |c| {
        var h = try Harness.init(testing.allocator, 0.0, 1.0, c);
        defer h.deinit(testing.allocator);
        var i: usize = 0;
        while (i < 180) : (i += 1) h.doStep(1.0 / 60.0);
        try testing.expect(@abs(h.pos() - 1.0) < rest_eps);
        try testing.expect(@abs(h.vel()) < rest_vel_eps);
        try testing.expect(h.active[0] == false);
    }
}

test "critically damped preset never overshoots" {
    const c = constants(0.0, 0.35);
    var h = try Harness.init(testing.allocator, 0.0, 1.0, c);
    defer h.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 240) : (i += 1) {
        h.doStep(1.0 / 120.0);
        try testing.expect(h.pos() <= 1.0 + 1.0e-4);
    }
}

test "bouncy preset overshoots the target at least once" {
    const c = constants(0.35, 0.35);
    var h = try Harness.init(testing.allocator, 0.0, 1.0, c);
    defer h.deinit(testing.allocator);
    var overshot = false;
    var i: usize = 0;
    while (i < 240) : (i += 1) {
        h.doStep(1.0 / 120.0);
        if (h.pos() > 1.0 + 1.0e-3) overshot = true;
    }
    try testing.expect(overshot);
    try testing.expect(@abs(h.pos() - 1.0) < rest_eps);
}

test "trajectory is independent of frame cadence" {
    const c = constants(0.25, 0.35);
    const total: f32 = 0.15;

    var steady = try Harness.init(testing.allocator, 0.0, 1.0, c);
    defer steady.deinit(testing.allocator);
    var t: f32 = 0;
    while (t + 1.0e-6 < total) : (t += 1.0 / 240.0) steady.doStep(1.0 / 240.0);

    var jittery = try Harness.init(testing.allocator, 0.0, 1.0, c);
    defer jittery.deinit(testing.allocator);
    const pattern = [_]f32{ 1.0 / 60.0, 1.0 / 200.0, 1.0 / 90.0, 1.0 / 120.0 };
    var acc: f32 = 0;
    var k: usize = 0;
    while (acc + 1.0e-6 < total) : (k += 1) {
        var d = pattern[k % pattern.len];
        if (acc + d > total) d = total - acc;
        jittery.doStep(d);
        acc += d;
    }

    try testing.expect(@abs(steady.pos() - jittery.pos()) < 5.0e-3);
}

test "retarget preserves velocity and position (no snap)" {
    const c = constants(0.25, 0.35);
    var h = try Harness.init(testing.allocator, 0.0, 1.0, c);
    defer h.deinit(testing.allocator);

    var i: usize = 0;
    while (i < 8) : (i += 1) h.doStep(1.0 / 60.0);
    const pos_before = h.pos();
    const vel_before = h.vel();
    try testing.expect(vel_before > 0.0);

    h.doRetarget(1.4);

    try testing.expect(h.pos() == pos_before);
    try testing.expect(h.vel() == vel_before);

    while (i < 240 and h.active[0]) : (i += 1) h.doStep(1.0 / 60.0);
    try testing.expect(@abs(h.pos() - 1.4) < rest_eps);
}

test "retarget re-activates a settled spring" {
    const c = constants(0.2, 0.30);
    var h = try Harness.init(testing.allocator, 0.0, 1.0, c);
    defer h.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 240 and h.active[0]) : (i += 1) h.doStep(1.0 / 120.0);
    try testing.expect(h.active[0] == false);

    h.doRetarget(0.5);
    try testing.expect(h.active[0] == true);

    i = 0;
    while (i < 240 and h.active[0]) : (i += 1) h.doStep(1.0 / 120.0);
    try testing.expect(@abs(h.pos() - 0.5) < rest_eps);
}

test "world reuses released slots and leaks nothing" {
    const c = constants(0.25, 0.35);
    var w: World = .empty;
    defer w.deinit(testing.allocator);

    var handles: [64]Handle = undefined;
    for (&handles) |*h| h.* = try w.spawn(testing.allocator, 0.0, 1.0, c);

    var i: usize = 0;
    while (i < 240) : (i += 1) w.step(1.0 / 120.0);
    try testing.expect(w.position(handles[0]).? == 1.0);

    for (handles) |h| w.release(h);
    try testing.expect(w.free.items.len == 64);
    try testing.expect(!w.isLive(handles[0]));
    try testing.expect(w.position(handles[0]) == null);

    const slots_before = w.springs.len;
    var reused: [64]Handle = undefined;
    for (&reused) |*h| h.* = try w.spawn(testing.allocator, 0.0, 1.0, c);
    try testing.expect(w.springs.len == slots_before);
    try testing.expect(w.isLive(reused[0]));
    try testing.expect(!w.isLive(handles[0]));
}

test "a settled spring goes inactive and stays put" {
    const c = constants(0.2, 0.30);
    var h = try Harness.init(testing.allocator, 0.0, 1.0, c);
    defer h.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 240 and h.active[0]) : (i += 1) h.doStep(1.0 / 120.0);
    try testing.expect(h.active[0] == false);
    const settled = h.pos();
    try testing.expect(@abs(settled - 1.0) < rest_eps);
    h.doStep(1.0 / 60.0);
    h.doStep(1.0 / 60.0);
    try testing.expect(h.pos() == settled);
}

test "stepScalar converges and carries velocity through a retarget" {
    const c = constants(0.0, 0.35);
    var p: f32 = 0.0;
    var v: f32 = 0.0;
    var i: usize = 0;
    while (i < 180) : (i += 1) stepScalar(&p, &v, 1.0, c, 1.0 / 60.0);
    try testing.expect(@abs(p - 1.0) < rest_eps);
    try testing.expect(@abs(v) < rest_vel_eps);

    var seeded_v: f32 = 5.0;
    var p2: f32 = 0.0;
    stepScalar(&p2, &seeded_v, 1.0, c, 1.0 / 60.0);
    try testing.expect(p2 > 0.0);
}
