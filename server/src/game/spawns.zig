//! Deterministic world content: everything on the map is a pure function of
//! (server_seed, geohash cell, time window), so the server stores no spawns and can validate any
//! id by recomputing it.
//!
//! Ids look like "e.dr5ru7k.2849112.1": kind, cell, window index, index within the window.
//! Caches use index 0; strongholds use window 0 and index 0.

const std = @import("std");
const data = @import("data.zig");
const geo = @import("geo.zig");
const rng_mod = @import("rng.zig");

const Rng = rng_mod.Rng;
const Geohash = geo.Geohash;

pub const enemy_window_ms: i64 = 10 * 60 * 1000;
pub const cache_window_ms: i64 = 30 * 60 * 1000;
pub const airdrop_window_ms: i64 = 2 * 60 * 60 * 1000;
pub const airdrop_live_ms: i64 = 45 * 60 * 1000;

pub const enemy_precision = 7;
pub const cache_precision = 7;
pub const airdrop_precision = 5;
pub const stronghold_precision = 6;

pub const cache_chance = 0.35;
pub const elite_chance = 0.08;

/// Chance of 0, 1, 2 and 3 enemies in a cell for one window: mean 1.21.
const enemy_count_weights = [_]f64{ 27, 36, 26, 11 };
pub const max_enemies_per_cell = 3;

pub const Kind = enum {
    enemy,
    cache,
    airdrop,
    stronghold,

    fn letter(self: Kind) u8 {
        return switch (self) {
            .enemy => 'e',
            .cache => 'c',
            .airdrop => 'a',
            .stronghold => 's',
        };
    }
};

pub fn windowIndex(now_ms: i64, window_ms: i64) i64 {
    return @divFloor(now_ms, window_ms);
}

pub fn windowStart(index: i64, window_ms: i64) i64 {
    return index * window_ms;
}

// --- Ids ---------------------------------------------------------------------------------------

pub const Id = struct {
    buf: [48]u8 = [_]u8{0} ** 48,
    len: u8 = 0,

    pub fn str(self: *const Id) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Parsed = struct {
    kind: Kind,
    cell: Geohash,
    window: i64,
    idx: u8,
};

pub fn formatId(kind: Kind, cell: Geohash, window: i64, idx: u8) Id {
    var id = Id{};
    const s = std.fmt.bufPrint(&id.buf, "{c}.{s}.{d}.{d}", .{ kind.letter(), cell.str(), window, idx }) catch unreachable;
    id.len = @intCast(s.len);
    return id;
}

pub fn parseId(s: []const u8) error{InvalidId}!Parsed {
    var it = std.mem.splitScalar(u8, s, '.');
    const k = it.next() orelse return error.InvalidId;
    const cell_s = it.next() orelse return error.InvalidId;
    const win_s = it.next() orelse return error.InvalidId;
    const idx_s = it.next() orelse return error.InvalidId;
    if (it.next() != null or k.len != 1) return error.InvalidId;
    const kind: Kind = switch (k[0]) {
        'e' => .enemy,
        'c' => .cache,
        'a' => .airdrop,
        's' => .stronghold,
        else => return error.InvalidId,
    };
    const cell = Geohash.parse(cell_s) catch return error.InvalidId;
    const window = std.fmt.parseInt(i64, win_s, 10) catch return error.InvalidId;
    const idx = std.fmt.parseInt(u8, idx_s, 10) catch return error.InvalidId;
    return .{ .kind = kind, .cell = cell, .window = window, .idx = idx };
}

// --- Positions -----------------------------------------------------------------------------------

pub const Point = struct { lat: f64, lon: f64 };

fn pointIn(rng: *Rng, cell: Geohash) Point {
    const box = geo.decode(cell);
    return .{ .lat = rng.range(box.lat_min, box.lat_max), .lon = rng.range(box.lon_min, box.lon_max) };
}

// --- Enemies ---------------------------------------------------------------------------------------

pub fn enemyCount(seed: u64, cell: Geohash, window: i64) u8 {
    var rng = rng_mod.derive(seed, .{ "ec", cell.str(), window });
    return @intCast(rng.weighted(&enemy_count_weights));
}

pub const Enemy = struct {
    cell: Geohash,
    window: i64,
    idx: u8,
    archetype: data.Archetype,
    /// Level relative to the viewer, -2..+2 (+3..+5 for elites).
    offset: i8,
    elite: bool,
    lat: f64,
    lon: f64,
    expires_at: i64,

    pub fn id(self: *const Enemy) Id {
        return formatId(.enemy, self.cell, self.window, self.idx);
    }

    /// The enemy's level as seen by a player of `player_level`.
    pub fn levelFor(self: *const Enemy, player_level: u32) u32 {
        const lvl = @as(i64, player_level) + self.offset;
        return @intCast(std.math.clamp(lvl, 1, data.max_level + 5));
    }
};

/// Enemy `idx` of `cell` in `window`, or null if the cell has fewer enemies than that.
pub fn enemy(seed: u64, cell: Geohash, window: i64, idx: u8) ?Enemy {
    if (idx >= enemyCount(seed, cell, window)) return null;
    var rng = rng_mod.derive(seed, .{ "e", cell.str(), window, idx });
    const arch: data.Archetype = @enumFromInt(rng.weighted(&data.archetype_weights));
    const elite = rng.chance(elite_chance);
    const offset: i32 = if (elite) rng.intRange(3, 5) else rng.intRange(-2, 2);
    const p = pointIn(&rng, cell);
    return .{
        .cell = cell,
        .window = window,
        .idx = idx,
        .archetype = arch,
        .offset = @intCast(offset),
        .elite = elite,
        .lat = p.lat,
        .lon = p.lon,
        .expires_at = windowStart(window + 1, enemy_window_ms),
    };
}

/// All enemies of a cell in a window; `out` must have room for `max_enemies_per_cell`.
pub fn enemiesInCell(seed: u64, cell: Geohash, window: i64, out: *[max_enemies_per_cell]Enemy) []const Enemy {
    const n = enemyCount(seed, cell, window);
    for (0..n) |i| out[i] = enemy(seed, cell, window, @intCast(i)).?;
    return out[0..n];
}

// --- Caches ------------------------------------------------------------------------------------------

pub const Cache = struct {
    cell: Geohash,
    window: i64,
    lat: f64,
    lon: f64,
    expires_at: i64,

    pub fn id(self: *const Cache) Id {
        return formatId(.cache, self.cell, self.window, 0);
    }
};

/// The cell's cache for a 30-minute window (35% of cells have one).
pub fn cache(seed: u64, cell: Geohash, window: i64) ?Cache {
    var rng = rng_mod.derive(seed, .{ "c", cell.str(), window });
    if (!rng.chance(cache_chance)) return null;
    const p = pointIn(&rng, cell);
    return .{ .cell = cell, .window = window, .lat = p.lat, .lon = p.lon, .expires_at = windowStart(window + 1, cache_window_ms) };
}

// --- Airdrops --------------------------------------------------------------------------------------

pub const Airdrop = struct {
    /// A geohash-5 cell.
    cell: Geohash,
    window: i64,
    lat: f64,
    lon: f64,
    starts_at: i64,
    expires_at: i64,

    pub fn id(self: *const Airdrop) Id {
        return formatId(.airdrop, self.cell, self.window, 0);
    }

    pub fn liveAt(self: *const Airdrop, now_ms: i64) bool {
        return now_ms >= self.starts_at and now_ms < self.expires_at;
    }
};

/// The region's airdrop for a 2-hour window; it lands at a hashed time and stays 45 minutes.
pub fn airdrop(seed: u64, cell: Geohash, window: i64) Airdrop {
    var rng = rng_mod.derive(seed, .{ "a", cell.str(), window });
    const slack: f64 = @floatFromInt(airdrop_window_ms - airdrop_live_ms);
    const start = windowStart(window, airdrop_window_ms) + @as(i64, @intFromFloat(rng.float() * slack));
    const p = pointIn(&rng, cell);
    return .{ .cell = cell, .window = window, .lat = p.lat, .lon = p.lon, .starts_at = start, .expires_at = start + airdrop_live_ms };
}

// --- Strongholds -------------------------------------------------------------------------------------

pub const Stronghold = struct {
    /// A geohash-6 cell.
    cell: Geohash,
    lat: f64,
    lon: f64,

    pub fn id(self: *const Stronghold) Id {
        return formatId(.stronghold, self.cell, 0, 0);
    }
};

/// The cell's stronghold: a fixed point that never moves (it depends only on the seed).
pub fn stronghold(seed: u64, cell: Geohash) Stronghold {
    var rng = rng_mod.derive(seed, .{ "s", cell.str() });
    const p = pointIn(&rng, cell);
    return .{ .cell = cell, .lat = p.lat, .lon = p.lon };
}

// --- Validation ----------------------------------------------------------------------------------------

/// Recompute the enemy behind an id and check it is live at `now_ms`. Null for anything the
/// server did not generate: bad syntax, wrong precision, empty slot, or the wrong window.
pub fn resolveEnemy(seed: u64, id: []const u8, now_ms: i64) ?Enemy {
    const p = parseId(id) catch return null;
    if (p.kind != .enemy or p.cell.len != enemy_precision) return null;
    if (p.window != windowIndex(now_ms, enemy_window_ms)) return null;
    return enemy(seed, p.cell, p.window, p.idx);
}

pub fn resolveCache(seed: u64, id: []const u8, now_ms: i64) ?Cache {
    const p = parseId(id) catch return null;
    if (p.kind != .cache or p.cell.len != cache_precision or p.idx != 0) return null;
    if (p.window != windowIndex(now_ms, cache_window_ms)) return null;
    return cache(seed, p.cell, p.window);
}

pub fn resolveAirdrop(seed: u64, id: []const u8, now_ms: i64) ?Airdrop {
    const p = parseId(id) catch return null;
    if (p.kind != .airdrop or p.cell.len != airdrop_precision or p.idx != 0) return null;
    const a = airdrop(seed, p.cell, p.window);
    if (!a.liveAt(now_ms)) return null;
    return a;
}

pub fn resolveStronghold(seed: u64, id: []const u8) ?Stronghold {
    const p = parseId(id) catch return null;
    if (p.kind != .stronghold or p.cell.len != stronghold_precision or p.window != 0 or p.idx != 0) return null;
    return stronghold(seed, p.cell);
}

// --- Tests ---------------------------------------------------------------------------------------------

const testing = std.testing;
const world: u64 = 0xfeedface;

fn cellAt(lat: f64, lon: f64, p: u8) Geohash {
    return geo.encode(lat, lon, p);
}

test "id format and parse round trip" {
    const cell = try Geohash.parse("dr5ru7k");
    const id = formatId(.enemy, cell, 2849112, 1);
    try testing.expectEqualStrings("e.dr5ru7k.2849112.1", id.str());
    const p = try parseId(id.str());
    try testing.expectEqual(Kind.enemy, p.kind);
    try testing.expect(p.cell.eql(&cell));
    try testing.expectEqual(@as(i64, 2849112), p.window);
    try testing.expectEqual(@as(u8, 1), p.idx);
    for ([_][]const u8{ "", "e", "x.dr5ru7k.1.0", "e.dr5ru7k.1", "e.dr5ru7k.1.0.9", "e.DR5RU7K.1.0", "e.dr5ru7k.x.0", "e.dr5ru7k.1.300", "ee.dr5ru7k.1.0", "e..1.0" }) |bad| {
        try testing.expectError(error.InvalidId, parseId(bad));
    }
}

test "world content is deterministic and world dependent" {
    const cell = cellAt(40.7484, -73.9857, 7);
    var a: [3]Enemy = undefined;
    var b: [3]Enemy = undefined;
    var differs = false;
    for (0..40) |w| {
        const ea = enemiesInCell(world, cell, @intCast(w), &a);
        const eb = enemiesInCell(world, cell, @intCast(w), &b);
        try testing.expectEqual(ea.len, eb.len);
        for (ea, eb) |x, y| try testing.expectEqualDeep(x, y);
        if (enemiesInCell(world +% 1, cell, @intCast(w), &b).len != ea.len) differs = true;
    }
    try testing.expect(differs);
    try testing.expectEqualDeep(cache(world, cell, 77), cache(world, cell, 77));
    try testing.expectEqualDeep(airdrop(world, cell.parent(5), 9), airdrop(world, cell.parent(5), 9));
}

test "enemy counts average 1.2 and stay within 0..3" {
    var total: f64 = 0;
    var counts = [_]f64{0} ** 4;
    const base = cellAt(48.8566, 2.3522, 7);
    var cell = base;
    var n: f64 = 0;
    for (0..40) |i| {
        if (i > 0) cell = geo.neighbors(cell)[2].?;
        for (0..100) |w| {
            const c = enemyCount(world, cell, @intCast(w + 1000));
            total += @floatFromInt(c);
            counts[c] += 1;
            n += 1;
        }
    }
    try testing.expectApproxEqAbs(1.21, total / n, 0.05);
    try testing.expectApproxEqAbs(0.27, counts[0] / n, 0.03);
    try testing.expectApproxEqAbs(0.11, counts[3] / n, 0.03);
}

test "enemies sit inside their cell with designed levels, archetypes and elite rate" {
    var cell = cellAt(35.68, 139.69, 7);
    var arch = [_]f64{0} ** 7;
    var elites: f64 = 0;
    var total: f64 = 0;
    for (0..60) |i| {
        cell = geo.neighbors(cell)[1].?;
        for (0..60) |w| {
            var buf: [3]Enemy = undefined;
            for (enemiesInCell(world, cell, @intCast(w), &buf)) |e| {
                const box = geo.decode(cell);
                try testing.expect(e.lat >= box.lat_min and e.lat <= box.lat_max);
                try testing.expect(e.lon >= box.lon_min and e.lon <= box.lon_max);
                try testing.expect(e.archetype != .abomination);
                if (e.elite) {
                    try testing.expect(e.offset >= 3 and e.offset <= 5);
                    elites += 1;
                } else try testing.expect(e.offset >= -2 and e.offset <= 2);
                arch[@intFromEnum(e.archetype)] += 1;
                total += 1;
                try testing.expectEqual(windowStart(@as(i64, @intCast(w)) + 1, enemy_window_ms), e.expires_at);
            }
        }
        _ = i;
    }
    try testing.expectApproxEqAbs(0.08, elites / total, 0.015);
    try testing.expectApproxEqAbs(0.40, arch[0] / total, 0.03);
    try testing.expectApproxEqAbs(0.20, arch[1] / total, 0.03);
    try testing.expectApproxEqAbs(0.05, arch[5] / total, 0.015);
}

test "enemy levels are relative to the viewer and clamped" {
    var e: Enemy = undefined;
    e.offset = -2;
    try testing.expectEqual(@as(u32, 1), e.levelFor(1));
    try testing.expectEqual(@as(u32, 8), e.levelFor(10));
    e.offset = 5;
    try testing.expectEqual(@as(u32, 15), e.levelFor(10));
}

test "caches appear in about 35% of cell-windows" {
    var cell = cellAt(51.5, -0.12, 7);
    var hits: f64 = 0;
    var n: f64 = 0;
    for (0..30) |_| {
        cell = geo.neighbors(cell)[2].?;
        for (0..100) |w| {
            n += 1;
            if (cache(world, cell, @intCast(w))) |c| {
                hits += 1;
                const box = geo.decode(cell);
                try testing.expect(c.lat >= box.lat_min and c.lat <= box.lat_max);
                try testing.expectEqual(windowStart(@as(i64, @intCast(w)) + 1, cache_window_ms), c.expires_at);
            }
        }
    }
    try testing.expectApproxEqAbs(0.35, hits / n, 0.03);
}

test "airdrops live 45 minutes inside their 2-hour window" {
    const region = cellAt(40.0, -74.0, 5);
    var w: i64 = 100;
    while (w < 200) : (w += 1) {
        const a = airdrop(world, region, w);
        try testing.expectEqual(airdrop_live_ms, a.expires_at - a.starts_at);
        try testing.expect(a.starts_at >= windowStart(w, airdrop_window_ms));
        try testing.expect(a.expires_at <= windowStart(w + 1, airdrop_window_ms));
        try testing.expect(a.liveAt(a.starts_at) and a.liveAt(a.expires_at - 1));
        try testing.expect(!a.liveAt(a.expires_at) and !a.liveAt(a.starts_at - 1));
        const box = geo.decode(region);
        try testing.expect(a.lat >= box.lat_min and a.lat <= box.lat_max);
    }
}

test "strongholds are fixed per geohash-6 cell" {
    const cell = cellAt(40.7, -74.0, 6);
    const s = stronghold(world, cell);
    try testing.expectEqualDeep(s, stronghold(world, cell));
    const box = geo.decode(cell);
    try testing.expect(s.lat >= box.lat_min and s.lat <= box.lat_max);
    try testing.expect(s.lon >= box.lon_min and s.lon <= box.lon_max);
    const id = s.id();
    try testing.expectEqualDeep(s, resolveStronghold(world, id.str()).?);
    try testing.expect(resolveStronghold(world, "s.dr5ru7k.0.0") == null);
}

test "ids resolve by recomputation and reject forgeries" {
    const now: i64 = 1_760_000_000_000;
    const w = windowIndex(now, enemy_window_ms);
    var cell = cellAt(40.7484, -73.9857, 7);
    // Find a cell with at least two enemies in this window.
    while (enemyCount(world, cell, w) < 2) cell = geo.neighbors(cell)[2].?;
    const e = enemy(world, cell, w, 1).?;
    const id = e.id();
    try testing.expectEqualDeep(e, resolveEnemy(world, id.str(), now).?);
    // Wrong window, empty slot, other world's content, wrong kind and wrong precision.
    try testing.expect(resolveEnemy(world, id.str(), now + enemy_window_ms) == null);
    const empty = formatId(.enemy, cell, w, 2 + enemyCount(world, cell, w));
    try testing.expect(resolveEnemy(world, empty.str(), now) == null);
    const cid = formatId(.cache, cell, w, 0);
    try testing.expect(resolveEnemy(world, cid.str(), now) == null);
    try testing.expect(resolveEnemy(world, "e.dr5ru7.1.0", now) == null);
    try testing.expect(resolveEnemy(world, "garbage", now) == null);

    // Caches
    const cw = windowIndex(now, cache_window_ms);
    var cc = cell;
    while (cache(world, cc, cw) == null) cc = geo.neighbors(cc)[2].?;
    const c = cache(world, cc, cw).?;
    const ccid = c.id();
    try testing.expectEqualDeep(c, resolveCache(world, ccid.str(), now).?);
    try testing.expect(resolveCache(world, ccid.str(), now + cache_window_ms) == null);

    // Airdrops
    const region = cell.parent(5);
    const aw = windowIndex(now, airdrop_window_ms);
    const a = airdrop(world, region, aw);
    const aid = a.id();
    try testing.expectEqualDeep(a, resolveAirdrop(world, aid.str(), a.starts_at + 1000).?);
    try testing.expect(resolveAirdrop(world, aid.str(), a.expires_at) == null);
    try testing.expect(resolveAirdrop(world, aid.str(), a.starts_at - 1) == null);
}
