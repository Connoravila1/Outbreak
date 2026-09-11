//! THE MAP MODULE — quarantined absolutely (D7).
//!
//! It consumes a `CellId` and produces pixels. No game-state module imports it; it writes to no
//! game state; it imports nothing from the game. If the map vanished tomorrow, only this file
//! would fail to compile.
//!
//! This file is the sixth coordinate bearer, and that is a decision made out loud, the way the
//! guard demands. The contract on a CellId -- "a room, not a point" -- is what keeps the game
//! honest everywhere else; this module exists because a map that cannot find the cell is not a
//! map. The inverse lives HERE and nowhere else: the geohash bits a cell carries are decoded
//! into a geographic extent inside this file, used to pick tile images, and never leave it.
//!
//! WHAT THE MAP MAY SHOW: real streets around the player's own cell -- the same thing a glance
//! at any map app already tells them. What it may NEVER show: anything game-state positioned on
//! it. No cell outline, no fight marker, no tell pin, no ring, no "warmer". A labelled geography
//! two players could compare to confirm they share a room is the inference channel I2 exists to
//! close (I2, I9). The war stays off the map; the map is backdrop.
//!
//! TILES: raster images in a local cache, keyed z/x/y like any slippy map. For development they
//! are fetched by tools/fetch_tiles.sh; in production they must be proxied through our own
//! server -- a phone asking a third-party tile host for the tiles around its cell hands that
//! host the player's rough location, which is a "where" leak to someone who is not even playing.

const std = @import("std");
const spatial = @import("spatial.zig");

pub const Region = struct {
    lat_lo: f64,
    lat_hi: f64,
    lon_lo: f64,
    lon_hi: f64,

    pub fn center(r: Region) struct { lat: f64, lon: f64 } {
        return .{ .lat = (r.lat_lo + r.lat_hi) / 2.0, .lon = (r.lon_lo + r.lon_hi) / 2.0 };
    }
};

/// THE SANCTIONED INVERSE. A cell's geohash bits, deinterleaved back into the interval they
/// encode -- longitude first, most significant bit first, the mirror of geohash.interleave.
/// This is the only function in the codebase that turns a room back toward a place, and it is
/// inside the one module permitted to know what a place looks like.
pub fn region(id: spatial.CellId) Region {
    const v = @intFromEnum(id);
    if (v == 0) return .{ .lat_lo = 0, .lat_hi = 0, .lon_lo = 0, .lon_hi = 0 };
    const p = spatial.precisionOf(id);
    const payload = v >> @intCast(64 - @as(u8, p));

    var lat_lo: f64 = -90.0;
    var lat_hi: f64 = 90.0;
    var lon_lo: f64 = -180.0;
    var lon_hi: f64 = 180.0;

    var i: u6 = 0;
    while (i < p) : (i += 1) {
        const bit = (payload >> (p - 1 - i)) & 1;
        if (i % 2 == 0) {
            const mid = (lon_lo + lon_hi) / 2.0;
            if (bit == 1) lon_lo = mid else lon_hi = mid;
        } else {
            const mid = (lat_lo + lat_hi) / 2.0;
            if (bit == 1) lat_lo = mid else lat_hi = mid;
        }
    }
    return .{ .lat_lo = lat_lo, .lat_hi = lat_hi, .lon_lo = lon_lo, .lon_hi = lon_hi };
}

/// Slippy-map tile coordinates at a zoom level.
pub const Tile = struct { z: u5, x: u32, y: u32 };

/// Where one tile lands on screen, in the window's logical pixels.
pub const Placement = struct {
    tile: Tile,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// The zoom the map runs at: close enough that street blocks read, wide enough that a cell
/// (tens of metres) is a neighbourhood and not a pin. One tile is ~600 m across at the
/// mid-latitudes, so a phone-sized window spans a few blocks.
pub const zoom: u5 = 16;

fn globalPx(lon: f64, lat: f64, z: u5) struct { x: f64, y: f64 } {
    const n: f64 = @floatFromInt(@as(u64, 1) << z);
    const x = (lon + 180.0) / 360.0 * n * 256.0;
    const lat_rad = lat * std.math.pi / 180.0;
    const y = (1.0 - @log(@tan(lat_rad) + 1.0 / @cos(lat_rad)) / std.math.pi) / 2.0 * n * 256.0;
    return .{ .x = x, .y = y };
}

/// Which tiles cover a `w` x `h` viewport centred on the cell, and where each lands on screen.
/// Returns the count written into `out`. The viewport is centred on the CELL CENTRE -- the map
/// does not know, and cannot be told, where in the cell the player stands.
pub fn layout(id: spatial.CellId, w: i32, h: i32, out: []Placement) usize {
    const r = region(id);
    const c = r.center();
    const centre = globalPx(c.lon, c.lat, zoom);

    const vx = centre.x - @as(f64, @floatFromInt(w)) / 2.0;
    const vy = centre.y - @as(f64, @floatFromInt(h)) / 2.0;

    const tx0: u32 = @intFromFloat(@floor(vx / 256.0));
    const tx1: u32 = @intFromFloat(@floor((vx + @as(f64, @floatFromInt(w))) / 256.0));
    const ty0: u32 = @intFromFloat(@floor(vy / 256.0));
    const ty1: u32 = @intFromFloat(@floor((vy + @as(f64, @floatFromInt(h))) / 256.0));

    var n: usize = 0;
    var ty = ty0;
    while (ty <= ty1) : (ty += 1) {
        var tx = tx0;
        while (tx <= tx1) : (tx += 1) {
            if (n >= out.len) return n;
            out[n] = .{
                .tile = .{ .z = zoom, .x = tx, .y = ty },
                .x = @intFromFloat(@floor(@as(f64, @floatFromInt(tx)) * 256.0 - vx)),
                .y = @intFromFloat(@floor(@as(f64, @floatFromInt(ty)) * 256.0 - vy)),
                .w = 256,
                .h = 256,
            };
            n += 1;
        }
    }
    return n;
}

/// The cache path for one tile. `dir` is the cache root the shell owns.
pub fn tilePath(dir: []const u8, tile: Tile, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{d}/{d}/{d}.png", .{ dir, tile.z, tile.x, tile.y }) catch unreachable;
}

/// THE GRADE. A stock tile is a bright, friendly thing; ours is not. Whatever the tile drew --
/// street, park, water -- it comes out of here the way the rest of the interface looks: near
/// black, lit only in red. Runs in place on decoded RGBA.
///
/// The trick is that a street map's features are drawn darker than the page they sit on. The
/// darkness of the source pixel becomes the brightness of ours, so roads glow faint red and the
/// blank land between them stays void. Anything the source painted blue is water and water is
/// black glass -- darker than the land, not redder.
pub fn grade(pixels: []u8) void {
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        const r: u32 = pixels[i];
        const g: u32 = pixels[i + 1];
        const b: u32 = pixels[i + 2];
        const luma = (r * 30 + g * 59 + b * 11) / 100;
        const d = 255 - luma;

        const is_water = b > r + 14 and b > g + 4;
        if (is_water) {
            // Water is the darkest thing on the sheet -- near black with a cold edge.
            pixels[i] = 8;
            pixels[i + 1] = 12;
            pixels[i + 2] = 16;
        } else {
            // Compress the ramp: the land sits near void, streets smoulder, and only the
            // darkest printed marks -- names, icons, the blackest lines -- burn bright.
            const red: u32 = d * 3 / 2 + 6;
            pixels[i] = @intCast(@min(255, red));
            pixels[i + 1] = @intCast(@min(255, 4 + d / 12));
            pixels[i + 2] = @intCast(@min(255, 6 + d / 10));
        }
        pixels[i + 3] = 255;
    }
}

const testing = std.testing;

test "the cell the map draws is the cell the quantizer made" {
    // A region decoded from a CellId must contain the coordinate that produced it -- that is
    // the whole of the contract this module adds. The vector is a real place (London).
    const cell = spatial.quantize(51.5007, -0.1246, spatial.default_precision).?;
    const r = region(cell);
    try testing.expect(51.5007 >= r.lat_lo and 51.5007 < r.lat_hi);
    try testing.expect(-0.1246 >= r.lon_lo and -0.1246 < r.lon_hi);
    // At 39 bits the room is tens of metres, not a city.
    try testing.expect(r.lon_hi - r.lon_lo < 0.001);
    try testing.expect(r.lat_hi - r.lat_lo < 0.001);
}
