//! CORE (B1, B2). Deterministic mixing. No clock, no entropy, no global state (B3, B4).
//!
//! splitmix64, written in-house. This is nine lines of shifts and multiplies, and it is
//! not a dependency (F2).
//!
//! Why not std.Random.DefaultPrng: `Default` means "whatever the standard library
//! currently considers best", and it is free to change in any Zig release. The tick must
//! replay byte-identically from (world, seed, index) forever (B8) -- including across a
//! toolchain upgrade. A replay that diverges because the stdlib improved its PRNG is a
//! replay we cannot trust, and we would discover it as a heisenbug in the integrity
//! system rather than as a build failure. So the algorithm is pinned here, by us, and it
//! never changes.

const std = @import("std");

/// CORE. The splitmix64 finalizer: an avalanche mix of a u64.
///
/// Every bit of the output depends on every bit of the input, which is the only property
/// we need of it.
pub fn mix(x: u64) u64 {
    var z = x +% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// CORE. Combine several values into one deterministic draw.
///
/// The draw for a player depends on who they are, not on where they happen to sit in an
/// array. This is what makes the tick's determinism real rather than incidental: the same
/// world, seed, and index must resolve identically no matter what order the presences
/// arrived in or how a sort broke a tie between them (B8).
pub fn draw(parts: []const u64) u64 {
    var acc: u64 = 0;
    for (parts) |part| acc = mix(acc ^ mix(part));
    return acc;
}

test "mix avalanches" {
    // A one-bit change in the input changes about half the output bits. We do not need a
    // strong guarantee here, only the absence of an obviously broken one.
    const a = mix(0);
    const b = mix(1);
    try std.testing.expect(@popCount(a ^ b) > 16);
}

test "draw is order-sensitive but stable" {
    try std.testing.expectEqual(draw(&.{ 1, 2, 3 }), draw(&.{ 1, 2, 3 }));
    try std.testing.expect(draw(&.{ 1, 2, 3 }) != draw(&.{ 3, 2, 1 }));
}

test "draw separates players that differ in one bit" {
    const seed: u64 = 0xDEADBEEF;
    const tick: u64 = 7;
    const a = draw(&.{ seed, tick, 1000 });
    const b = draw(&.{ seed, tick, 1001 });
    try std.testing.expect(a != b);
}

test "the pinned algorithm does not drift" {
    // If a Zig upgrade or a careless edit changes these numbers, every recorded replay in
    // the system becomes a lie. That is what this test is for: it is a tripwire, not a
    // property. If it fails, do not update the expected values -- find out why they moved.
    try std.testing.expectEqual(@as(u64, 0xE220A8397B1DCDAF), mix(0));
    try std.testing.expectEqual(@as(u64, 0x910A2DEC89025CC1), mix(1));
    try std.testing.expectEqual(@as(u64, 0xE4D971771B652C20), mix(0xFFFF_FFFF_FFFF_FFFF));
}
