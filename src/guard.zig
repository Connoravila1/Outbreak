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

const Source = struct { name: []const u8, text: []const u8 };

/// CORE (B1, B2). Pure functions over plain data. A coordinate may not appear here in
/// any form -- no f32, no f64, ever (B6).
const core = [_]Source{
    .{ .name = "root.zig", .text = @embedFile("root.zig") },
    .{ .name = "spatial.zig", .text = @embedFile("spatial.zig") },
    .{ .name = "spatial/cell.zig", .text = @embedFile("spatial/cell.zig") },
};

/// SHELL (B1, B3). Permitted to touch the outside world. Exactly one file here is
/// permitted to hold a coordinate, and only for the duration of one expression (B6).
const shell = [_]Source{
    .{ .name = "spatial/geohash.zig", .text = @embedFile("spatial/geohash.zig") },
};

comptime {
    // Scanning every source file for every forbidden construct at compile time costs
    // more comptime branches than the default budget allows. The budget is a guard
    // against runaway comptime, not a statement about this; raise it deliberately.
    @setEvalBranchQuota(1_000_000);

    for (core ++ shell) |src| {
        for (forbidden) |construct| {
            if (std.mem.indexOf(u8, src.text, construct) != null) {
                @compileError("FORBIDDEN CONSTRUCT: '" ++ construct ++ "' in " ++ src.name ++
                    ". The game has no geometry: no distance, no bearing, no neighbours, " ++
                    "and no inverse quantizer (A9, I2). A CellId is a room, not a point.");
            }
        }
    }

    for (core) |src| {
        for ([_][]const u8{ "f64", "f32" }) |float| {
            if (std.mem.indexOf(u8, src.text, float) != null) {
                @compileError("THE COORDINATE WALL (B6): '" ++ float ++ "' appears in " ++
                    src.name ++ ", which is CORE. The raw coordinate dies at the shell " ++
                    "boundary. The core cannot leak a location because it is never given one.");
            }
        }
    }
}
