//! In transit: a player moving faster than a person can walk is in a vehicle, and fights wait
//! until they are on foot (DESIGN.md section 5). Pure rules; the server keeps one `State` per
//! player in memory.
//!
//! One fast reading is not enough (a GPS jump looks fast too): two fast readings in a row put the
//! player in transit, and each further one extends it. It lasts `hold_ms` past the last fast
//! reading, so a walker is free again after a minute on foot. There is no passenger override.

const std = @import("std");
const progression = @import("progression.zig");

/// Faster than this is not walking (the same limit walking XP uses).
pub const fast_ms = progression.walk_max_speed_ms;
/// Consecutive fast readings that put a player in transit.
pub const fast_needed: u8 = 2;
/// Transit lasts this long after the last fast reading.
pub const hold_ms: i64 = 60 * 1000;
/// A position this vague says nothing about speed and is left out.
pub const max_usable_acc_m: f64 = 100.0;
/// Memory of a player is dropped once this long has passed since their last reading.
pub const forget_ms: i64 = 10 * 60 * 1000;

pub const State = struct {
    /// Fast readings in a row.
    streak: u8 = 0,
    /// In transit until this time (0: not).
    until: i64 = 0,
    /// Time of the last reading counted.
    at: i64 = 0,
};

/// Speed between two fixes. The distance is cut by the fixes' own accuracy radii first, so a phone
/// standing still with a wobbling signal never looks like it is moving.
pub fn speedMs(dist_m: f64, dt_ms: i64, acc_a_m: f64, acc_b_m: f64) f64 {
    const dt_s = @max(1.0, @as(f64, @floatFromInt(dt_ms)) / 1000.0);
    const d = @max(0.0, dist_m - @max(0.0, acc_a_m) - @max(0.0, acc_b_m));
    return d / dt_s;
}

/// Fold one reading (the speed since the previous fix) into the state. Readings from vague fixes
/// (`acc_m` over the limit) change nothing.
pub fn observe(s: State, speed_ms: f64, acc_m: f64, now: i64) State {
    if (acc_m > max_usable_acc_m) return s;
    var out = s;
    out.at = now;
    if (speed_ms > fast_ms) {
        out.streak = s.streak +| 1;
        if (out.streak >= fast_needed) out.until = now + hold_ms;
    } else {
        out.streak = 0;
    }
    return out;
}

pub fn active(s: State, now: i64) bool {
    return s.until > now;
}

/// Nothing left to remember.
pub fn stale(s: State, now: i64) bool {
    return !active(s, now) and now - s.at > forget_ms;
}

test "speed ignores accuracy slack and tiny gaps" {
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), speedMs(100, 10_000, 0, 0), 1e-9);
    // 30 m of wobble on a pair of 20 m fixes is nothing.
    try std.testing.expectEqual(@as(f64, 0), speedMs(30, 3000, 20, 20));
    // A zero gap counts as one second, not infinity.
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), speedMs(50, 0, 0, 0), 1e-9);
}

test "one fast fix is not transit; two in a row are" {
    var s = State{};
    s = observe(s, 20, 5, 1000);
    try std.testing.expect(!active(s, 1000));
    s = observe(s, 20, 5, 6000);
    try std.testing.expect(active(s, 6000));
    try std.testing.expect(active(s, 6000 + hold_ms - 1));
    try std.testing.expect(!active(s, 6000 + hold_ms));
}

test "a slow fix between fast ones resets the streak" {
    var s = State{};
    s = observe(s, 30, 5, 0);
    s = observe(s, 1.5, 5, 5000);
    s = observe(s, 30, 5, 10_000);
    try std.testing.expect(!active(s, 10_000));
}

test "transit clears a minute after the last fast fix, however slow the rest" {
    var s = State{};
    s = observe(s, 15, 5, 0);
    s = observe(s, 15, 5, 5000);
    s = observe(s, 1.2, 5, 20_000);
    try std.testing.expect(active(s, 20_000));
    s = observe(s, 1.2, 5, 70_000);
    try std.testing.expect(!active(s, 70_000));
    // Still driving: each fast fix pushes the end back.
    var d = State{};
    d = observe(d, 15, 5, 0);
    d = observe(d, 15, 5, 5000);
    d = observe(d, 15, 5, 50_000);
    try std.testing.expect(active(d, 100_000));
    try std.testing.expect(!active(d, 110_000));
}

test "vague fixes change nothing" {
    var s = State{};
    s = observe(s, 40, 5, 0);
    s = observe(s, 40, 500, 5000);
    try std.testing.expectEqual(@as(u8, 1), s.streak);
    s = observe(s, 40, 5, 10_000);
    try std.testing.expect(active(s, 10_000));
}

test "old idle state is forgotten" {
    var s = State{};
    s = observe(s, 15, 5, 0);
    s = observe(s, 15, 5, 5000);
    try std.testing.expect(!stale(s, 5000 + hold_ms));
    try std.testing.expect(stale(s, 5000 + forget_ms + 1));
}
