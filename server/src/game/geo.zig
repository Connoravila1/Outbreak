//! Geohash, neighbours, great-circle distance, and cell coverage of a circle.

const std = @import("std");

pub const earth_radius_m = 6_371_008.8;
pub const max_precision = 12;

const alphabet = "0123456789bcdefghjkmnpqrstuvwxyz";

/// A geohash string of 1 to 12 characters, stored inline so it can be passed by value.
pub const Geohash = struct {
    buf: [max_precision]u8 = [_]u8{0} ** max_precision,
    len: u8 = 0,

    pub fn str(self: *const Geohash) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn parse(s: []const u8) error{InvalidGeohash}!Geohash {
        if (s.len == 0 or s.len > max_precision) return error.InvalidGeohash;
        var g = Geohash{ .len = @intCast(s.len) };
        for (s, 0..) |c, i| {
            if (std.mem.indexOfScalar(u8, alphabet, c) == null) return error.InvalidGeohash;
            g.buf[i] = c;
        }
        return g;
    }

    pub fn eql(self: *const Geohash, other: *const Geohash) bool {
        return std.mem.eql(u8, self.str(), other.str());
    }

    /// The enclosing cell at a coarser precision.
    pub fn parent(self: *const Geohash, precision: u8) Geohash {
        std.debug.assert(precision >= 1 and precision <= self.len);
        var g = Geohash{ .len = precision };
        @memcpy(g.buf[0..precision], self.buf[0..precision]);
        return g;
    }
};

pub const BBox = struct {
    lat_min: f64,
    lat_max: f64,
    lon_min: f64,
    lon_max: f64,

    pub fn centerLat(self: BBox) f64 {
        return (self.lat_min + self.lat_max) / 2;
    }

    pub fn centerLon(self: BBox) f64 {
        return (self.lon_min + self.lon_max) / 2;
    }
};

pub fn encode(lat: f64, lon: f64, precision: u8) Geohash {
    std.debug.assert(precision >= 1 and precision <= max_precision);
    var lat_lo: f64 = -90;
    var lat_hi: f64 = 90;
    var lon_lo: f64 = -180;
    var lon_hi: f64 = 180;
    var g = Geohash{ .len = precision };
    var even = true;
    var bit: u3 = 0;
    var idx: u5 = 0;
    var n: usize = 0;
    while (n < precision) {
        if (even) {
            const mid = (lon_lo + lon_hi) / 2;
            if (lon >= mid) {
                idx = idx << 1 | 1;
                lon_lo = mid;
            } else {
                idx <<= 1;
                lon_hi = mid;
            }
        } else {
            const mid = (lat_lo + lat_hi) / 2;
            if (lat >= mid) {
                idx = idx << 1 | 1;
                lat_lo = mid;
            } else {
                idx <<= 1;
                lat_hi = mid;
            }
        }
        even = !even;
        if (bit == 4) {
            g.buf[n] = alphabet[idx];
            n += 1;
            bit = 0;
            idx = 0;
        } else {
            bit += 1;
        }
    }
    return g;
}

pub fn decode(gh: Geohash) BBox {
    var box = BBox{ .lat_min = -90, .lat_max = 90, .lon_min = -180, .lon_max = 180 };
    var even = true;
    for (gh.str()) |c| {
        const v: u5 = @intCast(std.mem.indexOfScalar(u8, alphabet, c).?);
        var mask: u5 = 16;
        while (mask != 0) : (mask >>= 1) {
            const set = v & mask != 0;
            if (even) {
                const mid = (box.lon_min + box.lon_max) / 2;
                if (set) box.lon_min = mid else box.lon_max = mid;
            } else {
                const mid = (box.lat_min + box.lat_max) / 2;
                if (set) box.lat_min = mid else box.lat_max = mid;
            }
            even = !even;
        }
    }
    return box;
}

pub fn decodeStr(s: []const u8) error{InvalidGeohash}!BBox {
    return decode(try Geohash.parse(s));
}

/// Cell size in degrees at `precision`: .lat is the height, .lon the width.
pub fn cellSize(precision: u8) struct { lat: f64, lon: f64 } {
    const bits: u32 = 5 * @as(u32, precision);
    const lon_bits = (bits + 1) / 2;
    const lat_bits = bits / 2;
    return .{
        .lat = 180.0 / @as(f64, @floatFromInt(@as(u64, 1) << @intCast(lat_bits))),
        .lon = 360.0 / @as(f64, @floatFromInt(@as(u64, 1) << @intCast(lon_bits))),
    };
}

/// The eight surrounding cells, clockwise from north: N, NE, E, SE, S, SW, W, NW. Null where a
/// neighbour would lie beyond a pole. Longitude wraps at the antimeridian.
pub fn neighbors(gh: Geohash) [8]?Geohash {
    const box = decode(gh);
    const size = cellSize(gh.len);
    const dlat = [8]f64{ 1, 1, 0, -1, -1, -1, 0, 1 };
    const dlon = [8]f64{ 0, 1, 1, 1, 0, -1, -1, -1 };
    var out: [8]?Geohash = undefined;
    for (0..8) |i| {
        const lat = box.centerLat() + dlat[i] * size.lat;
        var lon = box.centerLon() + dlon[i] * size.lon;
        if (lon >= 180) lon -= 360;
        if (lon < -180) lon += 360;
        out[i] = if (lat > 90 or lat < -90) null else encode(lat, lon, gh.len);
    }
    return out;
}

pub fn haversineM(lat1: f64, lon1: f64, lat2: f64, lon2: f64) f64 {
    const rad = std.math.pi / 180.0;
    const p1 = lat1 * rad;
    const p2 = lat2 * rad;
    const dp = (lat2 - lat1) * rad;
    const dl = (lon2 - lon1) * rad;
    const s1 = @sin(dp / 2);
    const s2 = @sin(dl / 2);
    const a = s1 * s1 + @cos(p1) * @cos(p2) * s2 * s2;
    return 2 * earth_radius_m * std.math.asin(@min(1.0, @sqrt(a)));
}

/// Distance in metres from a point to the nearest point of a cell (0 if inside).
pub fn distanceToBox(lat: f64, lon: f64, box: BBox) f64 {
    const clat = std.math.clamp(lat, box.lat_min, box.lat_max);
    const clon = std.math.clamp(lon, box.lon_min, box.lon_max);
    return haversineM(lat, lon, clat, clon);
}

/// Every cell at `precision` that lies within `radius_m` of the point, written to `out`
/// (truncated if it is too small). Returns how many were written. Not valid across the
/// antimeridian or the poles.
pub fn cellsWithin(lat: f64, lon: f64, radius_m: f64, precision: u8, out: []Geohash) usize {
    const size = cellSize(precision);
    const dlat = radius_m / 111_320.0;
    const cos_lat = @max(0.01, @cos(lat * std.math.pi / 180.0));
    const dlon = radius_m / (111_320.0 * cos_lat);
    const row0 = @floor((@max(-90.0, lat - dlat) + 90.0) / size.lat);
    const row1 = @floor((@min(89.999999, lat + dlat) + 90.0) / size.lat);
    const col0 = @floor((@max(-180.0, lon - dlon) + 180.0) / size.lon);
    const col1 = @floor((@min(179.999999, lon + dlon) + 180.0) / size.lon);
    var n: usize = 0;
    var row = row0;
    while (row <= row1) : (row += 1) {
        var col = col0;
        while (col <= col1) : (col += 1) {
            const box = BBox{
                .lat_min = row * size.lat - 90.0,
                .lat_max = (row + 1) * size.lat - 90.0,
                .lon_min = col * size.lon - 180.0,
                .lon_max = (col + 1) * size.lon - 180.0,
            };
            if (distanceToBox(lat, lon, box) > radius_m) continue;
            if (n == out.len) return n;
            out[n] = encode(box.centerLat(), box.centerLon(), precision);
            n += 1;
        }
    }
    return n;
}

test "geohash reference vectors" {
    try std.testing.expectEqualStrings("u4pruydqqvj", encode(57.64911, 10.40744, 11).str());
    try std.testing.expectEqualStrings("ezs42", encode(42.605, -5.603, 5).str());
    try std.testing.expectEqualStrings("s00000000000", encode(0, 0, 12).str());
    try std.testing.expectEqualStrings("9q8yy", encode(37.7749, -122.4194, 5).str());
}

test "decode brackets the point and reports sensible sizes" {
    const g = encode(57.64911, 10.40744, 11);
    const box = decode(g);
    try std.testing.expect(box.lat_min <= 57.64911 and 57.64911 <= box.lat_max);
    try std.testing.expect(box.lon_min <= 10.40744 and 10.40744 <= box.lon_max);
    const ez = try decodeStr("ezs42");
    try std.testing.expectApproxEqAbs(42.605, ez.centerLat(), 0.03);
    try std.testing.expectApproxEqAbs(-5.603, ez.centerLon(), 0.03);
    // geohash-7: 0.001373 deg tall and wide
    const s7 = cellSize(7);
    try std.testing.expectApproxEqAbs(0.001373, s7.lat, 1e-6);
    try std.testing.expectApproxEqAbs(0.001373, s7.lon, 1e-6);
    const cell = try decodeStr("dr5ru7k");
    try std.testing.expectApproxEqAbs(s7.lat, cell.lat_max - cell.lat_min, 1e-9);
    try std.testing.expectError(error.InvalidGeohash, Geohash.parse("abc!"));
    try std.testing.expectError(error.InvalidGeohash, Geohash.parse("a")); // 'a' is not in the alphabet
    try std.testing.expectError(error.InvalidGeohash, Geohash.parse(""));
}

test "round trip: the centre of a cell encodes back to the same cell" {
    var r = @import("rng.zig").Rng.init(11);
    for (0..500) |_| {
        const lat = r.range(-85, 85);
        const lon = r.range(-179, 179);
        const p: u8 = @intCast(r.intRange(3, 10));
        const g = encode(lat, lon, p);
        const box = decode(g);
        try std.testing.expect(g.eql(&encode(box.centerLat(), box.centerLon(), p)));
    }
}

test "neighbours: eight distinct adjacent cells" {
    const g = try Geohash.parse("dr5ru7k");
    const ns = neighbors(g);
    const box = decode(g);
    const size = cellSize(7);
    for (ns, 0..) |maybe, i| {
        const n = maybe.?;
        try std.testing.expect(!n.eql(&g));
        const nb = decode(n);
        // Touching: the centres are within one cell in each axis.
        try std.testing.expect(@abs(nb.centerLat() - box.centerLat()) < size.lat * 1.01);
        try std.testing.expect(@abs(nb.centerLon() - box.centerLon()) < size.lon * 1.01);
        for (ns[0..i]) |other| try std.testing.expect(!n.eql(&other.?));
    }
    // N is north of the cell, E is east.
    try std.testing.expect(decode(ns[0].?).centerLat() > box.centerLat());
    try std.testing.expect(decode(ns[2].?).centerLon() > box.centerLon());
    // Known value: the north neighbour of "ezs42" is "ezs48".
    try std.testing.expectEqualStrings("ezs48", neighbors(try Geohash.parse("ezs42"))[0].?.str());
}

test "neighbours wrap the antimeridian and stop at the poles" {
    const east_edge = encode(10, 179.9999, 5);
    const east = neighbors(east_edge)[2].?;
    try std.testing.expect(decode(east).centerLon() < 0);
    const polar = encode(89.99999, 0, 5);
    try std.testing.expect(neighbors(polar)[0] == null);
}

test "haversine sanity" {
    try std.testing.expectEqual(@as(f64, 0), haversineM(10, 10, 10, 10));
    // London to Paris, about 343.5 km
    try std.testing.expectApproxEqRel(343_500.0, haversineM(51.5074, -0.1278, 48.8566, 2.3522), 0.01);
    // One degree of latitude is about 111.2 km
    try std.testing.expectApproxEqRel(111_195.0, haversineM(0, 0, 1, 0), 0.001);
    // Symmetric
    try std.testing.expectEqual(haversineM(1, 2, 3, 4), haversineM(3, 4, 1, 2));
    // 50 m east at 45N
    const d = haversineM(45, 10, 45, 10 + 50.0 / (111_320.0 * @cos(45.0 * std.math.pi / 180.0)));
    try std.testing.expectApproxEqAbs(50.0, d, 0.5);
}

test "cellsWithin covers a 450 m radius with geohash-7 cells" {
    var out: [128]Geohash = undefined;
    const lat = 40.7484;
    const lon = -73.9857;
    const n = cellsWithin(lat, lon, 450, 7, &out);
    // The circle spans ~6 cells across; with corners cut that is roughly 40 to 55 cells.
    try std.testing.expect(n >= 25 and n <= 64);
    // The home cell is in there, and every cell is really within range.
    const home = encode(lat, lon, 7);
    var found = false;
    for (out[0..n]) |g| {
        if (g.eql(&home)) found = true;
        try std.testing.expect(distanceToBox(lat, lon, decode(g)) <= 450);
    }
    try std.testing.expect(found);
    // Completeness: random points inside the radius land in listed cells.
    var r = @import("rng.zig").Rng.init(3);
    for (0..500) |_| {
        const ang = r.range(0, 2 * std.math.pi);
        const dist = r.range(0, 449);
        const plat = lat + dist * @sin(ang) / 111_320.0;
        const plon = lon + dist * @cos(ang) / (111_320.0 * @cos(lat * std.math.pi / 180.0));
        const cell = encode(plat, plon, 7);
        var listed = false;
        for (out[0..n]) |g| {
            if (g.eql(&cell)) listed = true;
        }
        try std.testing.expect(listed);
    }
    // Truncation is safe.
    var small: [3]Geohash = undefined;
    try std.testing.expectEqual(@as(usize, 3), cellsWithin(lat, lon, 450, 7, &small));
}
