//! THE FORBIDDEN-CONSTRUCT GUARD — comptime. Fails the build, not the review.
//!
//! CLAUDE.md lists constructs that "will be produced helpfully and wrongly". A distance
//! function, a neighbour search, an inverse quantizer, a coordinate carried inward. Each
//! is a single plausible-looking function that quietly ends the privacy guarantee, and
//! each will look reasonable on the day someone writes it.
//!
//! Leaving that to human vigilance is the one thing we know does not work. So this guard
//! takes the same strategy as the size guard (A7): the compiler is what stops it. A
//! forbidden construct does not fail review -- it fails to compile, on the machine of
//! the person writing it, in the second they write it.
//!
//! Two rules are enforced here:
//!
//!   1. No geometry, anywhere. No distance, bearing, heading, radius, neighbour, or
//!      inverse quantizer, in core or shell (A9, I2).
//!   2. THE COORDINATE WALL (B6). No float appears in a file classified CORE. The core
//!      has no vocabulary for a position, and this is what makes that literally true
//!      rather than aspirationally true.
//!
//! Adding a source file means registering it below, as core or as shell. That is
//! deliberate: B1 requires every unit be classified, with no third category and nothing
//! unclassified, and this is where the classification is written down.

const std = @import("std");

/// Constructs that must not exist in this codebase. A CellId is a group-by key, not a
/// compressed coordinate (A9). The game has no geometry -- not because we forgot to add
/// it, but because a bearing is a step on the road to a name.
const forbidden = [_][]const u8{
    "fn distance",
    "fn neighbours",
    "fn neighbors",
    "fn toLatLon",
    "fn toLatLng",
    "fn toCoord",
    "fn toPoint",
    "fn bearing",
    "fn heading",
    "fn radius",
    "fn nearby",
    "fn adjacent",
    "fn kRing",
    "fn ring",
    "fn decodeCell",
    "fn unquantize",
};

/// Constructs forbidden by the integrity rules.
///
/// H4: a suspicion score is a soft signal. No automated punitive action may be derived from
/// it, ever. A false positive costs a real player slightly less XP -- never their account.
///
/// H6: we do not enter the attestation arms race. No client attestation, no root detection,
/// no mock-location check, no signature verification. All are bypassable, all break
/// legitimate players' phones, all demand perpetual maintenance we will never sustain, and
/// all are unnecessary, because no location carries a reward worth spoofing toward (H2).
///
/// Both of these will be proposed in good faith by someone tired and reasonable. Neither
/// will compile.
const forbidden_integrity = [_][]const u8{
    "fn ban",
    "fn autoBan",
    "fn suspend",
    "fn punish",
    "fn attest",
    "fn detectRoot",
    "fn isRooted",
    "fn checkMockLocation",
    "fn verifySignature",
    "fn deviceFingerprint",
};

const Source = struct { name: []const u8, text: []const u8 };

/// CORE (B1, B2). Pure functions over plain data. A coordinate may not appear here in
/// any form -- no f32, no f64, ever (B6).
const core = [_]Source{
    .{ .name = "root.zig", .text = @embedFile("root.zig") },
    .{ .name = "spatial.zig", .text = @embedFile("spatial.zig") },
    .{ .name = "spatial/cell.zig", .text = @embedFile("spatial/cell.zig") },
    .{ .name = "world.zig", .text = @embedFile("world.zig") },
    .{ .name = "rand.zig", .text = @embedFile("rand.zig") },
    .{ .name = "combat.zig", .text = @embedFile("combat.zig") },
    .{ .name = "tick.zig", .text = @embedFile("tick.zig") },
    .{ .name = "integrity.zig", .text = @embedFile("integrity.zig") },
    .{ .name = "territory.zig", .text = @embedFile("territory.zig") },
    .{ .name = "city.zig", .text = @embedFile("city.zig") },
    .{ .name = "journal.zig", .text = @embedFile("journal.zig") },
    .{ .name = "replay.zig", .text = @embedFile("replay.zig") },
    .{ .name = "protocol.zig", .text = @embedFile("protocol.zig") },
    .{ .name = "session.zig", .text = @embedFile("session.zig") },
};

/// SHELL (B1, B3). Permitted to touch the outside world. Exactly one file here is
/// permitted to hold a coordinate, and only for the duration of one expression (B6).
const shell = [_]Source{
    .{ .name = "spatial/geohash.zig", .text = @embedFile("spatial/geohash.zig") },
    .{ .name = "sim.zig", .text = @embedFile("sim.zig") },
    .{ .name = "store.zig", .text = @embedFile("store.zig") },
};

/// Does `haystack` begin with `needle`? Byte-wise, so that comptime does the least work
/// it possibly can.
fn startsWith(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (needle, haystack[0..needle.len]) |a, b| {
        if (a != b) return false;
    }
    return true;
}

comptime {
    // The first cut of this used std.mem.indexOf once per (file, pattern). It worked, and
    // it cost twenty-two seconds of every cold build -- Boyer-Moore builds a skip table per
    // pattern per file, at comptime, and there are twenty-six patterns and ten files.
    //
    // Measured, then fixed (G1, G2). This version walks each file's bytes once and only
    // consults the forbidden list where a `fn ` actually appears, which is a few dozen
    // places per file rather than every byte. The guard is not negotiable; its price was.
    @setEvalBranchQuota(10_000_000);

    for (core ++ shell, 0..) |src, file_index| {
        const is_core = file_index < core.len;

        var i: usize = 0;
        while (i < src.text.len) : (i += 1) {
            // Every construct we look for -- `fn `, `f64`, `f32` -- begins with an 'f'. One
            // byte comparison rejects the overwhelming majority of the file, and comptime
            // does no further work on it.
            if (src.text[i] != 'f') continue;

            const rest = src.text[i..];

            // A forbidden function definition. Checked only at the handful of positions
            // where a function is actually being declared.
            if (startsWith(rest, "fn ")) {
                for (forbidden) |construct| {
                    if (startsWith(rest, construct)) {
                        @compileError("FORBIDDEN CONSTRUCT: '" ++ construct ++ "' in " ++ src.name ++
                            ". The game has no geometry: no distance, no bearing, no neighbours, " ++
                            "and no inverse quantizer (A9, I2). A CellId is a room, not a point.");
                    }
                }

                for (forbidden_integrity) |construct| {
                    if (startsWith(rest, construct)) {
                        @compileError("FORBIDDEN CONSTRUCT: '" ++ construct ++ "' in " ++ src.name ++
                            ". A suspicion score never becomes a punishment (H4), and we do not " ++
                            "enter the attestation arms race (H6). No location carries a reward " ++
                            "worth spoofing toward, so there is no war here to fight.");
                    }
                }
            }

            // THE COORDINATE WALL (B6). No float in a file classified core, in any form.
            if (is_core and (startsWith(rest, "f64") or startsWith(rest, "f32"))) {
                @compileError("THE COORDINATE WALL (B6): a float appears in " ++ src.name ++
                    ", which is CORE. The raw coordinate dies at the shell boundary. The core " ++
                    "cannot leak a location because it is never given one.");
            }
        }
    }
}
