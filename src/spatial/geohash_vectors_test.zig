//! Published geohash test vectors.
//!
//! The quantizer is written in-house (F2), which means we own its correctness. These
//! vectors are the only external check that exists on the one function in the system
//! that touches a coordinate, so they are not optional and they are not decoration.
//!
//! The base32 rendering below exists ONLY in this test, to compare our interleaved bits
//! against the published strings. It is not a decoder: it recovers no coordinate, and it
//! does not appear in the shipped module. It renders a cell id; it does not invert one.

const std = @import("std");
const geohash = @import("geohash.zig");

/// The geohash alphabet. Note the omissions: a, i, l, o.
const alphabet = "0123456789bcdefghjkmnpqrstuvwxyz";

fn base32(bits: u64, chars: usize, out: []u8) []const u8 {
    var i: usize = 0;
    while (i < chars) : (i += 1) {
        const shift: u6 = @intCast((chars - 1 - i) * 5);
        out[i] = alphabet[@intCast((bits >> shift) & 0x1f)];
    }
    return out[0..chars];
}

test "published geohash vectors" {
    const cases = [_]struct {
        lat: f64,
        lon: f64,
        chars: usize,
        expect: []const u8,
    }{
        .{ .lat = 42.6, .lon = -5.6, .chars = 5, .expect = "ezs42" },
        .{ .lat = 57.64911, .lon = 10.40744, .chars = 11, .expect = "u4pruydqqvj" },
        .{ .lat = 37.8324, .lon = 112.5584, .chars = 9, .expect = "ww8p1r4t8" },
        .{ .lat = 0.0, .lon = 0.0, .chars = 5, .expect = "s0000" },
    };

    var buf: [16]u8 = undefined;
    for (cases) |c| {
        const precision: u6 = @intCast(c.chars * 5);
        const bits = geohash.interleave(c.lat, c.lon, precision);
        try std.testing.expectEqualStrings(c.expect, base32(bits, c.chars, &buf));
    }
}

test "a shorter vector is a prefix of a longer one" {
    // Truncation is the coarsening rule (I8) seen from the other side: dropping bits
    // grows the room, and the coarse code is a prefix of the fine one. If this ever
    // stopped holding, coarsening would move a player to an unrelated cell.
    var buf: [16]u8 = undefined;
    const long = geohash.interleave(57.64911, 10.40744, 55);
    const short = geohash.interleave(57.64911, 10.40744, 25);
    try std.testing.expectEqualStrings("u4pru", base32(short, 5, &buf));
    try std.testing.expectEqualStrings("u4pru", base32(long >> 30, 5, &buf));
}
