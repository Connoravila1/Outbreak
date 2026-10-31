//! In-memory state that is never persisted: the latest position of each player (dropped after two
//! minutes), active Echoes, and rate-limit buckets. Positions live here and nowhere else.

const std = @import("std");
const game = @import("game");
const snapshot = @import("snapshot.zig");

const geo = game.geo;
const landmarks = game.landmarks;

const Allocator = std.mem.Allocator;

pub const position_ttl_ms: i64 = 2 * 60 * 1000;

pub const Pos = struct {
    lat: f64,
    lon: f64,
    acc: f32,
    sanctuary: bool,
    faction: game.data.Faction = .human,
    at: i64,
    /// Metres walked since walking XP was last paid out.
    carry_m: f64 = 0,
};

/// An Echo offered to one player (or a tombstone recording that this window rolled nothing).
pub const Echo = struct {
    owner: i64,
    window: i64,
    /// True when the window's roll produced no echo.
    none: bool = false,
    rogue: bool = false,
    /// Player whose snapshot this is (gets the report), if any.
    source: ?i64 = null,
    build: snapshot.Build = undefined,
    lat: f64 = 0,
    lon: f64 = 0,
    expires_at: i64 = 0,

    pub fn id(self: *const Echo) [32]u8 {
        var buf = [_]u8{0} ** 32;
        _ = std.fmt.bufPrint(&buf, "x.{d}.{d}", .{ self.owner, self.window }) catch unreachable;
        return buf;
    }
};

/// Where a player's First Blood enemy currently stands (memory only, like positions).
pub const Tutorial = struct {
    lat: f64,
    lon: f64,
    /// Bumped on each re-anchor so the new spot differs from the old one.
    gen: u32,
    expires_at: i64,
};

pub const Bucket = struct { tokens: f64, at: i64 };

/// A real place players have reported, kept in memory only.
pub const Remembered = struct {
    place: landmarks.Place,
    seen_at: i64,
    /// The last few players whose maps showed it (0: empty). Only they are shown it again.
    reporters: [3]i64 = .{ 0, 0, 0 },
    next_reporter: u8 = 0,

    pub fn reportedBy(self: *const Remembered, pid: i64) bool {
        return std.mem.indexOfScalar(i64, &self.reporters, pid) != null;
    }

    fn addReporter(self: *Remembered, pid: i64) void {
        if (self.reportedBy(pid)) return;
        self.reporters[self.next_reporter] = pid;
        self.next_reporter = (self.next_reporter + 1) % @as(u8, self.reporters.len);
    }
};

pub const Area = struct {
    places: std.ArrayList(Remembered) = .empty,
};

/// Places are forgotten when nobody has reported them for this long.
pub const place_ttl_ms: i64 = 12 * 60 * 60 * 1000;
/// A reported place stays in its reporter's view for this long without a fresh report.
pub const place_view_ms: i64 = 30 * 60 * 1000;
pub const max_places_per_area = 150;
pub const max_places_total = 20_000;
/// Two reports of one key this far apart are not the same place; the first one stands.
pub const same_place_m = 60.0;

pub const Live = struct {
    gpa: Allocator,
    positions: std.AutoHashMapUnmanaged(i64, Pos) = .empty,
    echoes: std.AutoHashMapUnmanaged(i64, Echo) = .empty,
    buckets: std.AutoHashMapUnmanaged(i64, Bucket) = .empty,
    tutorials: std.AutoHashMapUnmanaged(i64, Tutorial) = .empty,
    chat_last: std.AutoHashMapUnmanaged(i64, i64) = .empty,
    /// Reported real places by geohash-6 area (never persisted).
    places: std.AutoHashMapUnmanaged([landmarks.area_precision]u8, Area) = .empty,
    place_count: usize = 0,
    landmark_opens: std.AutoHashMapUnmanaged(i64, landmarks.Opens) = .empty,

    pub fn init(gpa: Allocator) Live {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Live) void {
        self.positions.deinit(self.gpa);
        self.echoes.deinit(self.gpa);
        self.buckets.deinit(self.gpa);
        self.tutorials.deinit(self.gpa);
        self.chat_last.deinit(self.gpa);
        var it = self.places.valueIterator();
        while (it.next()) |a| a.places.deinit(self.gpa);
        self.places.deinit(self.gpa);
        self.landmark_opens.deinit(self.gpa);
    }

    /// The latest accepted position, or null if there is none or it is older than two minutes.
    pub fn position(self: *const Live, pid: i64, now: i64) ?Pos {
        const p = self.positions.get(pid) orelse return null;
        if (now - p.at > position_ttl_ms) return null;
        return p;
    }

    pub fn setPosition(self: *Live, pid: i64, pos: Pos) Allocator.Error!void {
        try self.positions.put(self.gpa, pid, pos);
    }

    pub fn online(self: *const Live, now: i64) usize {
        var n: usize = 0;
        var it = self.positions.valueIterator();
        while (it.next()) |p| {
            if (now - p.at <= position_ttl_ms) n += 1;
        }
        return n;
    }

    /// The player's echo for this window (or its tombstone).
    pub fn echoFor(self: *const Live, pid: i64, window: i64) ?Echo {
        const e = self.echoes.get(pid) orelse return null;
        return if (e.window == window) e else null;
    }

    /// A player holds at most one echo (the current window's).
    pub fn putEcho(self: *Live, e: Echo) Allocator.Error!void {
        try self.echoes.put(self.gpa, e.owner, e);
    }

    pub fn dropEcho(self: *Live, pid: i64) void {
        _ = self.echoes.remove(pid);
    }

    /// Forget everything held in memory for a deleted player.
    pub fn forget(self: *Live, pid: i64) void {
        _ = self.positions.remove(pid);
        _ = self.echoes.remove(pid);
        _ = self.buckets.remove(pid);
        _ = self.tutorials.remove(pid);
        _ = self.chat_last.remove(pid);
        _ = self.landmark_opens.remove(pid);
        var areas = self.places.valueIterator();
        while (areas.next()) |a| {
            for (a.places.items) |*r| {
                for (&r.reporters) |*x| {
                    if (x.* == pid) x.* = 0;
                }
            }
        }
        // Echoes of this player's build offered to others.
        var doomed: std.ArrayList(i64) = .empty;
        defer doomed.deinit(self.gpa);
        var it = self.echoes.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.source == pid) doomed.append(self.gpa, kv.key_ptr.*) catch continue;
        }
        for (doomed.items) |k| _ = self.echoes.remove(k);
    }

    /// Remember a validated place reported by `pid`. The first report of a key fixes its kind and
    /// position; later ones (from anyone) refresh it and add the reporter. Returns the stored place,
    /// or null when it was refused (a conflicting position, or the memory is full).
    pub fn rememberPlace(self: *Live, place: landmarks.Place, pid: i64, now: i64) Allocator.Error!?Remembered {
        if (self.findPtr(place.keyStr(), place.lat, place.lon)) |r| {
            if (geo.haversineM(r.place.lat, r.place.lon, place.lat, place.lon) > same_place_m) return null;
            r.seen_at = now;
            r.addReporter(pid);
            if (r.place.name.len == 0) r.place.name = place.name;
            return r.*;
        }
        if (self.place_count >= max_places_total) return null;
        const cell = geo.encode(place.lat, place.lon, landmarks.area_precision);
        const gop = try self.places.getOrPut(self.gpa, cell.buf[0..landmarks.area_precision].*);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const area = gop.value_ptr;
        if (area.places.items.len >= max_places_per_area) {
            // Make room by dropping the place seen longest ago.
            var oldest: usize = 0;
            for (area.places.items, 0..) |r, i| {
                if (r.seen_at < area.places.items[oldest].seen_at) oldest = i;
            }
            _ = area.places.swapRemove(oldest);
            self.place_count -= 1;
        }
        var r = Remembered{ .place = place, .seen_at = now };
        r.addReporter(pid);
        try area.places.append(self.gpa, r);
        self.place_count += 1;
        return r;
    }

    fn findPtr(self: *Live, key: []const u8, lat: f64, lon: f64) ?*Remembered {
        var cells: [16]geo.Geohash = undefined;
        const n = geo.cellsWithin(lat, lon, landmarks.report_radius_m, landmarks.area_precision, &cells);
        for (cells[0..n]) |cell| {
            const area = self.places.getPtr(cell.buf[0..landmarks.area_precision].*) orelse continue;
            for (area.places.items) |*r| {
                if (std.mem.eql(u8, r.place.keyStr(), key)) return r;
            }
        }
        return null;
    }

    /// A remembered place by key near a point (searches the areas within the report radius).
    pub fn findPlace(self: *const Live, key: []const u8, lat: f64, lon: f64, now: i64) ?Remembered {
        var cells: [16]geo.Geohash = undefined;
        const n = geo.cellsWithin(lat, lon, landmarks.report_radius_m, landmarks.area_precision, &cells);
        for (cells[0..n]) |cell| {
            const area = self.places.get(cell.buf[0..landmarks.area_precision].*) orelse continue;
            for (area.places.items) |r| {
                if (now - r.seen_at > place_ttl_ms) continue;
                if (std.mem.eql(u8, r.place.keyStr(), key)) return r;
            }
        }
        return null;
    }

    /// Places `pid` reported recently that lie within `radius_m` of a point.
    pub fn placesFor(self: *const Live, pid: i64, lat: f64, lon: f64, radius_m: f64, now: i64, out: *std.ArrayList(Remembered), arena: Allocator) Allocator.Error!void {
        var cells: [16]geo.Geohash = undefined;
        const n = geo.cellsWithin(lat, lon, radius_m, landmarks.area_precision, &cells);
        for (cells[0..n]) |cell| {
            const area = self.places.get(cell.buf[0..landmarks.area_precision].*) orelse continue;
            for (area.places.items) |r| {
                if (now - r.seen_at > place_view_ms or !r.reportedBy(pid)) continue;
                if (geo.haversineM(lat, lon, r.place.lat, r.place.lon) > radius_m) continue;
                try out.append(arena, r);
            }
        }
    }

    /// Token bucket: refills `rate` tokens per second up to `burst`; false when empty.
    pub fn allow(self: *Live, key: i64, now: i64, burst: f64, rate: f64) Allocator.Error!bool {
        const gop = try self.buckets.getOrPut(self.gpa, key);
        if (!gop.found_existing) gop.value_ptr.* = .{ .tokens = burst, .at = now };
        const b = gop.value_ptr;
        const dt: f64 = @floatFromInt(@max(0, now - b.at));
        b.tokens = @min(burst, b.tokens + dt / 1000.0 * rate);
        b.at = now;
        if (b.tokens < 1.0) return false;
        b.tokens -= 1.0;
        return true;
    }

    fn prunePlaces(self: *Live, now: i64) void {
        var doomed: std.ArrayList([landmarks.area_precision]u8) = .empty;
        defer doomed.deinit(self.gpa);
        var it = self.places.iterator();
        while (it.next()) |e| {
            var list = &e.value_ptr.places;
            var i: usize = 0;
            while (i < list.items.len) {
                if (now - list.items[i].seen_at > place_ttl_ms) {
                    _ = list.swapRemove(i);
                    self.place_count -= 1;
                } else i += 1;
            }
            if (list.items.len == 0) doomed.append(self.gpa, e.key_ptr.*) catch continue;
        }
        for (doomed.items) |k| {
            if (self.places.fetchRemove(k)) |kv| {
                var a = kv.value;
                a.places.deinit(self.gpa);
            }
        }
    }

    /// Drop stale positions, finished echoes and idle buckets.
    pub fn prune(self: *Live, now: i64) void {
        pruneMap(Pos, &self.positions, now, struct {
            fn old(p: Pos, t: i64) bool {
                return t - p.at > position_ttl_ms;
            }
        }.old);
        pruneMap(Echo, &self.echoes, now, struct {
            fn old(e: Echo, t: i64) bool {
                return e.expires_at <= t;
            }
        }.old);
        pruneMap(Tutorial, &self.tutorials, now, struct {
            fn old(t: Tutorial, n: i64) bool {
                return t.expires_at <= n;
            }
        }.old);
        pruneMap(Bucket, &self.buckets, now, struct {
            fn old(b: Bucket, t: i64) bool {
                return t - b.at > 10 * 60 * 1000;
            }
        }.old);
        pruneMap(landmarks.Opens, &self.landmark_opens, now, struct {
            fn old(o: landmarks.Opens, t: i64) bool {
                return o.blockedUntil(t) == null;
            }
        }.old);
        self.prunePlaces(now);
        pruneMap(i64, &self.chat_last, now, struct {
            fn old(at: i64, t: i64) bool {
                return t - at > 60 * 1000;
            }
        }.old);
    }
};

fn pruneMap(comptime V: type, map: *std.AutoHashMapUnmanaged(i64, V), now: i64, comptime old: fn (V, i64) bool) void {
    var it = map.iterator();
    while (it.next()) |e| {
        if (old(e.value_ptr.*, now)) map.removeByPtr(e.key_ptr);
    }
}

test "positions expire after two minutes" {
    var live = Live.init(std.testing.allocator);
    defer live.deinit();
    try live.setPosition(1, .{ .lat = 1, .lon = 2, .acc = 5, .sanctuary = false, .at = 1000 });
    try std.testing.expect(live.position(1, 1000 + position_ttl_ms) != null);
    try std.testing.expect(live.position(1, 1001 + position_ttl_ms) == null);
    try std.testing.expect(live.position(2, 1000) == null);
    try std.testing.expectEqual(@as(usize, 1), live.online(2000));
    live.prune(1000 + position_ttl_ms + 5);
    try std.testing.expectEqual(@as(usize, 0), live.positions.count());
}

test "token bucket refills over time" {
    var live = Live.init(std.testing.allocator);
    defer live.deinit();
    for (0..3) |_| try std.testing.expect(try live.allow(7, 0, 3, 1.0));
    try std.testing.expect(!try live.allow(7, 0, 3, 1.0));
    try std.testing.expect(!try live.allow(7, 500, 3, 1.0));
    try std.testing.expect(try live.allow(7, 1500, 3, 1.0));
    try std.testing.expect(try live.allow(8, 0, 3, 1.0));
}

test "echoes are per window and prune when finished" {
    var live = Live.init(std.testing.allocator);
    defer live.deinit();
    try live.putEcho(.{ .owner = 5, .window = 10, .expires_at = 100 });
    try std.testing.expect(live.echoFor(5, 10) != null);
    try std.testing.expect(live.echoFor(5, 11) == null);
    try std.testing.expectEqualStrings("x.5.10", std.mem.sliceTo(&live.echoFor(5, 10).?.id(), 0));
    live.prune(100);
    try std.testing.expect(live.echoFor(5, 10) == null);
}

test "places are remembered per area; the first report fixes a key" {
    var live = Live.init(std.testing.allocator);
    defer live.deinit();
    const place = landmarks.validate(.{ .key = "n1", .kind = "pharmacy", .lat = 40.7490, .lon = -73.9850, .name = "Duane Reade" }, 40.7484, -73.9857).?;
    const first = (try live.rememberPlace(place, 7, 1000)).?;
    try std.testing.expect(first.reportedBy(7) and !first.reportedBy(8));
    // Another player reporting the same place shares the landmark; it does not duplicate.
    const again = (try live.rememberPlace(place, 8, 2000)).?;
    try std.testing.expect(again.reportedBy(7) and again.reportedBy(8));
    try std.testing.expectEqual(@as(usize, 1), live.place_count);
    // The same key somewhere else is refused; the original stands.
    var moved = place;
    moved.lat += 0.002;
    try std.testing.expect((try live.rememberPlace(moved, 9, 3000)) == null);
    try std.testing.expectEqual(@as(usize, 1), live.place_count);
    // Found by key near the player, not far away or after it expires.
    try std.testing.expect(live.findPlace("n1", 40.7484, -73.9857, 4000) != null);
    try std.testing.expect(live.findPlace("n2", 40.7484, -73.9857, 4000) == null);
    try std.testing.expect(live.findPlace("n1", 41.5, -73.9857, 4000) == null);
    try std.testing.expect(live.findPlace("n1", 40.7484, -73.9857, 1000 + place_ttl_ms + 2001) == null);
    // Only reporters see it, and only while the report is fresh.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(Remembered) = .empty;
    try live.placesFor(7, 40.7484, -73.9857, 400, 5000, &out, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    out.clearRetainingCapacity();
    try live.placesFor(99, 40.7484, -73.9857, 400, 5000, &out, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try live.placesFor(7, 40.7484, -73.9857, 400, 2000 + place_view_ms + 1, &out, arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    // Forgotten after twelve hours without a report.
    live.prune(2000 + place_ttl_ms + 1);
    try std.testing.expectEqual(@as(usize, 0), live.place_count);
    try std.testing.expectEqual(@as(usize, 0), live.places.count());
}

test "an area keeps at most 150 places, dropping the stalest" {
    var live = Live.init(std.testing.allocator);
    defer live.deinit();
    for (0..max_places_per_area + 10) |i| {
        var key: [8]u8 = undefined;
        const k = try std.fmt.bufPrint(&key, "k{d}", .{i});
        const place = landmarks.validate(.{ .key = k, .kind = "diner", .lat = 40.7484, .lon = -73.9857 }, 40.7484, -73.9857).?;
        _ = try live.rememberPlace(place, 1, @intCast(1000 + i));
    }
    try std.testing.expectEqual(@as(usize, max_places_per_area), live.place_count);
    try std.testing.expect(live.findPlace("k0", 40.7484, -73.9857, 2000) == null);
    try std.testing.expect(live.findPlace("k159", 40.7484, -73.9857, 2000) != null);
}
