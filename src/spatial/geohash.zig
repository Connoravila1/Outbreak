//! SHELL (B1, B3, B6). THE COORDINATE WALL RUNS THROUGH THIS FILE.
//!
//! This is the only file in the system permitted to hold a coordinate, and it holds one
//! for the duration of a single expression. The float arrives, it is consumed, and it is
//! gone. It is never stored, never logged, never persisted, never forwarded, and never
//! returned. What crosses into the core is a u64 and nothing else.
//!
//! The privacy guarantee is not a promise made here. It is a consequence of this file
//! being the only one that could break it -- and it does not.
//!
//! There is no decoder. There is no inverse. A CellId does not convert back toward a
//! latitude and longitude, and the function that would do it is not missing by oversight
//! (A9).
//!
//! Written in-house per F2: bit interleaving and truncation, well under a hundred lines,
//! verified against published test vectors in geohash_vectors_test.zig.

const std = @import("std");
const cell = @import("cell.zig");

const CellId = cell.CellId;

pub const max_precision = cell.max_precision;

/// SHELL. Quantize a raw coordinate to a CellId, and discard the coordinate.
///
/// Returns null for a coordinate we will not accept: NaN, infinity, or out of range. A
/// presence that fails validation is dropped here, at the shell, and never enters the
/// core (E5). It is not an error -- an unusable reading is an absent presence, not a
/// failure to be propagated (E4).
pub fn quantize(lat_deg: f64, lon_deg: f64, precision: u6) ?CellId {
    if (!std.math.isFinite(lat_deg) or !std.math.isFinite(lon_deg)) return null;
    if (lat_deg < -90.0 or lat_deg > 90.0) return null;
    if (lon_deg < -180.0 or lon_deg > 180.0) return null;
    if (precision < 1 or precision > max_precision) return null;

    return cell.fromBits(interleave(lat_deg, lon_deg, precision), precision);
}

/// SHELL. Standard geohash bit interleave: longitude first, alternating, most
/// significant bit first. Returns `precision` bits, right-aligned.
///
/// The bit order is not a free choice -- it is what the published vectors encode, and
/// deviating from it would leave the one coordinate-touching function in the system with
/// no external check on its correctness.
pub fn interleave(lat_deg: f64, lon_deg: f64, precision: u6) u64 {
    std.debug.assert(precision >= 1 and precision <= max_precision);

    var lat_lo: f64 = -90.0;
    var lat_hi: f64 = 90.0;
    var lon_lo: f64 = -180.0;
    var lon_hi: f64 = 180.0;

    var bits: u64 = 0;
    var i: usize = 0;
    while (i < precision) : (i += 1) {
        bits <<= 1;
        if (i % 2 == 0) {
            const mid = (lon_lo + lon_hi) / 2.0;
            if (lon_deg >= mid) {
                bits |= 1;
                lon_lo = mid;
            } else {
                lon_hi = mid;
            }
        } else {
            const mid = (lat_lo + lat_hi) / 2.0;
            if (lat_deg >= mid) {
                bits |= 1;
                lat_lo = mid;
            } else {
                lat_hi = mid;
            }
        }
    }
    return bits;
}

test "an unusable reading is an absent presence, not an error" {
    const p: u6 = 39;
    try std.testing.expectEqual(@as(?CellId, null), quantize(std.math.nan(f64), 0, p));
    try std.testing.expectEqual(@as(?CellId, null), quantize(0, std.math.inf(f64), p));
    try std.testing.expectEqual(@as(?CellId, null), quantize(90.001, 0, p));
    try std.testing.expectEqual(@as(?CellId, null), quantize(-90.001, 0, p));
    try std.testing.expectEqual(@as(?CellId, null), quantize(0, 180.001, p));
    try std.testing.expectEqual(@as(?CellId, null), quantize(0, -180.001, p));
    try std.testing.expectEqual(@as(?CellId, null), quantize(0, 0, 0));
    try std.testing.expect(quantize(0, 0, p) != null);
}

test "the poles and the antimeridian quantize" {
    const p: u6 = 39;
    try std.testing.expect(quantize(90, 180, p) != null);
    try std.testing.expect(quantize(-90, -180, p) != null);
}

test "two coordinates in one room are one cell" {
    // The entire spatial algorithm depends on this and nothing else: co-location is
    // u64 equality. Two points a few metres apart share a cell; the game never learns
    // that they were ever distinct.
    const p: u6 = 39;
    const a = quantize(51.500000, -0.124000, p).?;
    const b = quantize(51.500050, -0.124050, p).?;
    try std.testing.expectEqual(a, b);
}

test "quantization is deterministic" {
    const p: u6 = 39;
    try std.testing.expectEqual(quantize(42.6, -5.6, p), quantize(42.6, -5.6, p));
}
