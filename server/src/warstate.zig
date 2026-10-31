//! Server-side war bookkeeping: weekly points by district and player, faction shares and the
//! underdog bonus, district winners, and stronghold adjacency perks.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("ctx.zig");

const data = game.data;
const geo = game.geo;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;

const week_ms = game.war.week_ms;
const shares_ttl_ms: i64 = 60 * 1000;

pub fn week(now: i64) i64 {
    return game.war.weekIndex(now);
}

pub fn addPoints(req: *Req, pid: i64, faction: data.Faction, district: []const u8, pts: u32) HandlerError!void {
    if (pts == 0) return;
    const db = &req.ctx.db;
    const w = week(req.now);
    try db.run(
        "INSERT INTO war_district(week, district, faction, points) VALUES(?,?,?,?) ON CONFLICT(week, district, faction) DO UPDATE SET points = points + excluded.points",
        .{ w, district, @intFromEnum(faction), pts },
    );
    try db.run(
        "INSERT INTO war_player(week, player_id, district, points) VALUES(?,?,?,?) ON CONFLICT(week, player_id, district) DO UPDATE SET points = points + excluded.points",
        .{ w, pid, district, pts },
    );
}

pub fn weekPoints(req: *Req, pid: i64) HandlerError!u32 {
    return @intCast(try req.ctx.db.scalar("SELECT COALESCE(SUM(points), 0) FROM war_player WHERE week = ? AND player_id = ?", .{ week(req.now), pid }) orelse 0);
}

pub const Shares = struct {
    human: u32,
    zombie: u32,

    pub fn share(self: Shares, f: data.Faction) f32 {
        const total = self.human + self.zombie;
        if (total == 0) return 0.5;
        const n = if (f == .human) self.human else self.zombie;
        return @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(total));
    }

    /// The smaller faction, or null when they are level.
    pub fn underdog(self: Shares) ?data.Faction {
        if (self.human == self.zombie) return null;
        return if (self.human < self.zombie) .human else .zombie;
    }

    pub fn bonusFor(self: Shares, f: data.Faction) f32 {
        return game.progression.underdogBonus(self.share(f), self.share(f.opposite()));
    }
};

/// Players active in the last 7 days per faction (cached for a minute).
pub fn shares(req: *Req) HandlerError!Shares {
    const ctx = req.ctx;
    if (ctx.shares.valid and req.now - ctx.shares.at < shares_ttl_ms and req.now >= ctx.shares.at) {
        return .{ .human = ctx.shares.human, .zombie = ctx.shares.zombie };
    }
    const cutoff = req.now - week_ms;
    const h: u32 = @intCast(try ctx.db.scalar("SELECT COUNT(*) FROM players WHERE faction = 0 AND last_seen > ?", .{cutoff}) orelse 0);
    const z: u32 = @intCast(try ctx.db.scalar("SELECT COUNT(*) FROM players WHERE faction = 1 AND last_seen > ?", .{cutoff}) orelse 0);
    ctx.shares = .{ .valid = true, .at = req.now, .human = h, .zombie = z };
    return .{ .human = h, .zombie = z };
}

pub fn invalidateShares(ctx: *ctx_mod.Ctx) void {
    ctx.shares.valid = false;
}

/// Did `faction` win `district` last week? (More points than the other side.)
pub fn wonDistrictLastWeek(req: *Req, faction: data.Faction, district: []const u8) HandlerError!bool {
    var st = try req.ctx.db.query("SELECT faction, points FROM war_district WHERE week = ? AND district = ?", .{ week(req.now) - 1, district });
    defer st.finalize();
    var pts = [2]i64{ 0, 0 };
    while (try st.step()) {
        const f: usize = @intCast(st.int(0));
        if (f < 2) pts[f] = st.int(1);
    }
    return pts[@intFromEnum(faction)] > pts[@intFromEnum(faction.opposite())];
}

/// XP bonus for a clan holding 3+ (5%) or 6+ (10%) edge-adjacent strongholds this week.
pub fn adjacencyBonus(req: *Req, clan_id: i64) HandlerError!f32 {
    var cells: [64]geo.Geohash = undefined;
    var n: usize = 0;
    var st = try req.ctx.db.query("SELECT id FROM strongholds WHERE clan_id = ? AND week = ?", .{ clan_id, week(req.now) });
    defer st.finalize();
    while (try st.step()) {
        if (n == cells.len) break;
        const parsed = game.spawns.parseId(st.text(0)) catch continue;
        cells[n] = parsed.cell;
        n += 1;
    }
    const best = largestGroup(cells[0..n]);
    if (best >= 6) return 0.10;
    if (best >= 3) return 0.05;
    return 0;
}

fn largestGroup(cells: []const geo.Geohash) usize {
    var seen = [_]bool{false} ** 64;
    var stack: [64]usize = undefined;
    var best: usize = 0;
    for (cells, 0..) |_, start| {
        if (seen[start]) continue;
        var size: usize = 0;
        var top: usize = 1;
        stack[0] = start;
        seen[start] = true;
        while (top > 0) {
            top -= 1;
            const cur = stack[top];
            size += 1;
            const nb = geo.neighbors(cells[cur]);
            for ([_]usize{ 0, 2, 4, 6 }) |d| {
                const other = nb[d] orelse continue;
                for (cells, 0..) |c, j| {
                    if (!seen[j] and c.eql(&other)) {
                        seen[j] = true;
                        stack[top] = j;
                        top += 1;
                    }
                }
            }
        }
        best = @max(best, size);
    }
    return best;
}

test "adjacent strongholds form groups by shared edge" {
    const a = geo.encode(40.0, -74.0, 6);
    const east = geo.neighbors(a)[2].?;
    const east2 = geo.neighbors(east)[2].?;
    const far = geo.encode(10.0, 10.0, 6);
    const diag = geo.neighbors(a)[1].?;
    try std.testing.expectEqual(@as(usize, 3), largestGroup(&.{ a, east, east2, far }));
    try std.testing.expectEqual(@as(usize, 1), largestGroup(&.{ a, diag, far }));
    try std.testing.expectEqual(@as(usize, 0), largestGroup(&.{}));
}

test "shares and underdog bonus" {
    const s = Shares{ .human = 30, .zombie = 70 };
    try std.testing.expectEqual(@as(?data.Faction, .human), s.underdog());
    try std.testing.expectApproxEqAbs(0.2, s.bonusFor(.human), 1e-6);
    try std.testing.expectEqual(@as(f32, 0), s.bonusFor(.zombie));
    try std.testing.expectEqual(@as(?data.Faction, null), (Shares{ .human = 3, .zombie = 3 }).underdog());
    try std.testing.expectApproxEqAbs(0.25, (Shares{ .human = 1, .zombie = 99 }).bonusFor(.human), 1e-6);
    try std.testing.expectEqual(@as(f32, 0.5), (Shares{ .human = 0, .zombie = 0 }).share(.human));
}
