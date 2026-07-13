//! CORE (B1, B2). Pure functions over a u64.
//!
//! No coordinate appears in this file, and no function here converts a CellId back
//! toward one. There is no inverse quantizer, no distance, no bearing, no neighbour
//! enumeration, and there never will be (A9, I2). A cell is a room, not a point.
//!
//! ENCODING — the sentinel bit
//!
//!   bit 63                                    bit 0
//!   [ payload: p bits ][ 1 ][ zeros ................ ]
//!
//! The truncated geohash payload sits at the top, followed by a single 1 bit, followed
//! by zeros. Precision is recovered from the value itself: p = 63 - @ctz(v).
//!
//! Why precision must live inside the value:
//!
//! Coarsening (I8) means cells of different precision coexist in one world -- a sparse
//! region's room is larger than a dense one's. The tick groups presences by u64
//! equality and nothing else (0.3). If precision were not carried in the value, a
//! coarse cell and a fine cell could truncate to the same u64, and the group-by would
//! fabricate a shared room out of two people who are nowhere near each other. Quorum
//! would then fire on presence that does not exist, and the tells emitted from it would
//! be about strangers in another town.
//!
//! That is not a performance bug. It is the system inventing proximity, which is the
//! one thing it must never do. The sentinel costs one bit and makes the collision
//! structurally impossible rather than merely unlikely.
//!
//! It also makes 0 an invalid CellId, so a zeroed or uninitialised record cannot
//! masquerade as a place.

const std = @import("std");
const rand = @import("../rand.zig");

const assert = std.debug.assert;

/// A place. The fundamental type of the system (A9): a group-by key, a sort key, a
/// hash key -- and not a compressed coordinate.
///
/// It is an opaque enum rather than a bare u64 on purpose. You cannot subtract two
/// CellIds, so the geometry that Section I forbids cannot be written by accident; it
/// would take a deliberate @intFromEnum to even begin, and that is visible in review.
pub const CellId = enum(u64) { _ };

/// One bit of the 64 is always spent on the sentinel, so 63 payload bits is the
/// ceiling.
pub const max_precision: u6 = 63;

/// NOT A PLACE.
///
/// Every real cell has its sentinel bit set, so no real cell is ever zero -- which makes zero
/// the one value that can mean "this player is not in a room at all". A phone with no GPS fix,
/// a player who has never reported, a session that just opened: they are NOWHERE, and nowhere
/// is not somewhere.
///
/// This matters more than it looks. The first version gave unreported players a real cell as a
/// placeholder, and every player whose phone had not reported was therefore standing in the
/// SAME room as every other -- they reached quorum, and they fought each other. Everyone with
/// GPS switched off was at war in one enormous invisible room.
///
/// The tick skips nowhere. Nobody is co-located with a person who is not anywhere.
pub const nowhere: CellId = @enumFromInt(0);

/// CORE. Pack `precision` payload bits into a sentinel-tagged CellId.
pub fn fromBits(bits: u64, precision: u6) CellId {
    assert(precision >= 1 and precision <= max_precision);
    assert(bits >> precision == 0); // payload must fit in `precision` bits

    const payload_shift: u6 = @intCast(64 - @as(u8, precision));
    const sentinel: u64 = @as(u64, 1) << (max_precision - precision);
    return @enumFromInt((bits << payload_shift) | sentinel);
}

/// CORE. Recover the precision carried in the value.
pub fn precisionOf(id: CellId) u6 {
    const v = @intFromEnum(id);
    assert(v != 0); // 0 is not a place
    const trailing: u6 = @intCast(@ctz(v));
    return max_precision - trailing;
}

/// CORE. Total order on cells.
///
/// A sort key and nothing more. Two cells adjacent in this order are NOT adjacent in the
/// world, and no code may treat them as though they were. The order exists so that equal
/// cells land next to each other and the tick can scan runs (0.3) -- it is a group-by, not
/// a geometry (A9).
pub fn lessThan(a: CellId, b: CellId) bool {
    return @intFromEnum(a) < @intFromEnum(b);
}

/// CORE. A stable hash of a cell, for use as an entropy source.
///
/// A cell is a hash key (A9), and the tick needs per-cell randomness that replays. This
/// gives it one without handing out the bit layout: the result is mixed, so it is usable
/// as entropy and useless as a location. No caller can reconstruct the geohash bits from
/// it, and no caller has any business trying (D3).
pub fn hash(id: CellId) u64 {
    return rand.mix(@intFromEnum(id));
}

/// CORE. Fabricate a distinct cell from an arbitrary key.
///
/// No coordinate exists behind the result and no quantizer ran. This is how core tests
/// and the synthetic city (0.10) make rooms: a room is just an identity, and inventing a
/// latitude in order to obtain one would mean handing the core a coordinate it would then
/// have to be trusted to throw away. It is not trusted. It is never given one (B6).
pub fn fromKey(key: u64, precision: u6) CellId {
    assert(precision >= 1 and precision <= max_precision);
    const mask: u64 = if (precision == 64) ~@as(u64, 0) else (@as(u64, 1) << precision) - 1;
    return fromBits(key & mask, precision);
}

/// CORE. Grow the room (I8).
///
/// Sparse regions coarsen until quorum is reachable: fewer geohash bits, a larger
/// cell. This is the whole coarsening rule, and it is a mask and a bit -- k is never
/// lowered to solve density, and there is no function in this codebase that could.
pub fn coarsen(id: CellId, bits: u6) CellId {
    const p = precisionOf(id);
    assert(bits < p); // a cell keeps at least one bit; there is no null place

    const coarser: u6 = p - bits;
    const keep_shift: u6 = @intCast(64 - @as(u8, coarser));
    const keep: u64 = ~@as(u64, 0) << keep_shift;
    const sentinel: u64 = @as(u64, 1) << (max_precision - coarser);
    return @enumFromInt((@intFromEnum(id) & keep) | sentinel);
}

test "sentinel round-trips precision" {
    // The counter is wider than u6 on purpose: a u6 cannot hold max_precision + 1, so
    // the loop increment would overflow on the final iteration.
    var p: u7 = 1;
    while (p <= max_precision) : (p += 1) {
        const precision: u6 = @intCast(p);
        const id = fromBits(0, precision);
        try std.testing.expectEqual(precision, precisionOf(id));
    }
}

test "same bits at different precision are different cells" {
    // The collision this encoding exists to prevent. Without the sentinel both of
    // these truncate to the same u64 and the group-by fuses two unrelated rooms.
    const fine = fromBits(0b1011, 4);
    const coarse = fromBits(0b101, 3);
    try std.testing.expect(fine != coarse);
    try std.testing.expectEqual(@as(u6, 4), precisionOf(fine));
    try std.testing.expectEqual(@as(u6, 3), precisionOf(coarse));
}

test "coarsening drops bits and retains the prefix" {
    const fine = fromBits(0b110101, 6);
    const coarse = coarsen(fine, 2);

    try std.testing.expectEqual(@as(u6, 4), precisionOf(coarse));
    // The surviving payload is the 4-bit prefix of the 6-bit one.
    try std.testing.expectEqual(fromBits(0b1101, 4), coarse);
}

test "coarsening is idempotent in steps" {
    const fine = fromBits(0b11010110, 8);
    try std.testing.expectEqual(coarsen(fine, 3), coarsen(coarsen(fine, 1), 2));
}

test "cells sharing a coarse parent coarsen to the same room" {
    // Two distinct fine cells in the same coarse room. This is what makes quorum
    // reachable in a sparse region: the room grows, the occupants merge.
    const a = fromBits(0b110100, 6);
    const b = fromBits(0b110111, 6);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(coarsen(a, 2), coarsen(b, 2));
}

test "zero is not a place" {
    // A zeroed record must not be mistaken for a cell. Every valid CellId has the
    // sentinel set, so every valid CellId is non-zero.
    var p: u7 = 1;
    while (p <= max_precision) : (p += 1) {
        try std.testing.expect(@intFromEnum(fromBits(0, @intCast(p))) != 0);
    }
}
