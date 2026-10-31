//! In-memory state that is never persisted: the latest position of each player (dropped after two
//! minutes), active Echoes, and rate-limit buckets. Positions live here and nowhere else.

const std = @import("std");
const game = @import("game");
const snapshot = @import("snapshot.zig");

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

pub const Live = struct {
    gpa: Allocator,
    positions: std.AutoHashMapUnmanaged(i64, Pos) = .empty,
    echoes: std.AutoHashMapUnmanaged(i64, Echo) = .empty,
    buckets: std.AutoHashMapUnmanaged(i64, Bucket) = .empty,
    tutorials: std.AutoHashMapUnmanaged(i64, Tutorial) = .empty,
    chat_last: std.AutoHashMapUnmanaged(i64, i64) = .empty,

    pub fn init(gpa: Allocator) Live {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Live) void {
        self.positions.deinit(self.gpa);
        self.echoes.deinit(self.gpa);
        self.buckets.deinit(self.gpa);
        self.tutorials.deinit(self.gpa);
        self.chat_last.deinit(self.gpa);
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
        // Echoes of this player's build offered to others.
        var doomed: std.ArrayList(i64) = .empty;
        defer doomed.deinit(self.gpa);
        var it = self.echoes.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.source == pid) doomed.append(self.gpa, kv.key_ptr.*) catch continue;
        }
        for (doomed.items) |k| _ = self.echoes.remove(k);
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
