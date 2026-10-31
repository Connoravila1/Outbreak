//! The 5-second tick: Contact matching between live players, and (once a minute) housekeeping:
//! stronghold income, raids, pruning, the weekly stronghold purge.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("ctx.zig");
const model = @import("model.zig");
const views = @import("views.zig");
const fight = @import("fight.zig");
const contact = @import("contact.zig");
const raids = @import("raids.zig");
const warstate = @import("warstate.zig");
const live = @import("live.zig");

const data = game.data;
const geo = game.geo;
const Ctx = ctx_mod.Ctx;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;

const log = std.log.scoped(.tick);

pub const interval_ms: u64 = 5000;
const housekeeping_gap_ms: i64 = 60 * 1000;

/// Salvage each member earns per held stronghold per day.
pub const daily_salvage = 20;

/// Run one tick under the global lock. Failures are logged and do not stop the server.
pub fn run(ctx: *Ctx) void {
    ctx.lock();
    defer ctx.unlock();
    runLocked(ctx, ctx.now());
}

/// One tick at `now`; the caller holds the lock. Tests call this directly.
pub fn runLocked(ctx: *Ctx, now: i64) void {
    ctx.live.prune(now);
    contacts(ctx, now) catch |e| log.err("contact matching failed: {s}", .{@errorName(e)});
    if (now - ctx.housekeeping_at >= housekeeping_gap_ms) {
        ctx.housekeeping_at = now;
        housekeeping(ctx, now) catch |e| log.err("housekeeping failed: {s}", .{@errorName(e)});
    }
}

fn newReq(ctx: *Ctx, arena: std.mem.Allocator, now: i64) Req {
    return .{ .ctx = ctx, .arena = arena, .now = now, .method = .other, .path = "", .query = "", .body = "" };
}

const Near = struct { a: i64, b: i64, dist: f64 };

fn contacts(ctx: *Ctx, now: i64) !void {
    const gpa = ctx.gpa;
    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(gpa);
    var it = ctx.live.positions.iterator();
    while (it.next()) |e| {
        const pos = e.value_ptr.*;
        if (!pos.fresh(now) or pos.sanctuary) continue;
        // No Contact from a moving vehicle.
        if (ctx.live.inTransit(e.key_ptr.*, now)) continue;
        try ids.append(gpa, e.key_ptr.*);
    }
    if (ids.items.len < 2) return;

    var pairs: std.ArrayList(Near) = .empty;
    defer pairs.deinit(gpa);
    for (ids.items, 0..) |ia, i| {
        const pa = ctx.live.positions.get(ia).?;
        for (ids.items[i + 1 ..]) |ib| {
            const pb = ctx.live.positions.get(ib).?;
            if (pa.faction == pb.faction) continue;
            if (@abs(pa.lat - pb.lat) > 0.001) continue; // ~110 m: a cheap filter before the exact distance
            const d = geo.haversineM(pa.lat, pa.lon, pb.lat, pb.lon);
            if (d <= contact.range_m) try pairs.append(gpa, .{ .a = ia, .b = ib, .dist = d });
        }
    }
    // Closest pairs first; a player fights at most once per tick.
    std.mem.sort(Near, pairs.items, {}, struct {
        fn less(_: void, x: Near, y: Near) bool {
            return x.dist < y.dist;
        }
    }.less);
    var used: std.AutoHashMapUnmanaged(i64, void) = .empty;
    defer used.deinit(gpa);
    for (pairs.items) |pr| {
        if (used.contains(pr.a) or used.contains(pr.b)) continue;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var req = newReq(ctx, arena.allocator(), now);
        const fought = resolvePair(&req, pr.a, pr.b) catch |e| blk: {
            log.err("contact failed: {s}", .{@errorName(e)});
            break :blk false;
        };
        if (fought) {
            try used.put(gpa, pr.a, {});
            try used.put(gpa, pr.b, {});
        }
    }
}

/// Check every Contact condition from the database and, if they hold, fight and settle both sides.
fn resolvePair(req: *Req, id_a: i64, id_b: i64) HandlerError!bool {
    const db = &req.ctx.db;
    const now = req.now;
    var pa = (try model.load(req, id_a)) orelse return false;
    var pb = (try model.load(req, id_b)) orelse return false;
    if (!contact.eligible(&pa, now) or !contact.eligible(&pb, now)) return false;
    if (pa.faction.? == pb.faction.?) return false;
    if (!game.progression.pvpLevelsMatch(pa.level, pb.level)) return false;
    const lo = @min(id_a, id_b);
    const hi = @max(id_a, id_b);
    if ((try db.scalar("SELECT 1 FROM contact_log WHERE a = ? AND b = ? AND at > ?", .{ lo, hi, now - contact.pair_cooldown_ms })) != null) return false;

    try db.begin();
    errdefer db.rollback();
    const side_a = try fight.selfSide(req, &pa);
    const side_b = try fight.selfSide(req, &pb);
    const seed = game.rng.hash(req.ctx.seed, .{ "contact", lo, hi, now });
    const o = try fight.run(req, side_a, side_b, seed);
    const o_b = try fight.flip(req.arena, o);

    // Districts come from where each player stands; only the district id is stored.
    const pos_a = req.ctx.live.position(id_a, now);
    const district = try req.arena.dupe(u8, if (pos_a) |pos| game.war.districtId(pos.lat, pos.lon).str() else "unknown");

    try contact.settleSide(req, &pa, side_a, contact.anonymous(side_b), o, district);
    try contact.settleSide(req, &pb, side_b, contact.anonymous(side_a), o_b, district);
    try db.run("INSERT INTO contact_log(a, b, at) VALUES(?,?,?)", .{ lo, hi, now });
    try db.commit();
    return true;
}

// --- Housekeeping -------------------------------------------------------------------------------------------

fn housekeeping(ctx: *Ctx, now: i64) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    var req = newReq(ctx, arena.allocator(), now);
    const db = &ctx.db;
    try db.begin();
    errdefer db.rollback();

    try db.run("DELETE FROM done WHERE expires_at < ?", .{now});
    try db.run("DELETE FROM contact_log WHERE at < ?", .{now - 24 * 60 * 60 * 1000});
    try db.run("DELETE FROM clan_chat WHERE at < ?", .{now - 7 * game.war.day_ms});
    try db.run("DELETE FROM events WHERE at < ?", .{now - 30 * game.war.day_ms});

    // The weekly purge: strongholds from earlier weeks are gone.
    try db.run("DELETE FROM strongholds WHERE week < ?", .{game.war.weekIndex(now)});
    try strongholdIncome(&req);
    try raids.upkeep(&req);
    try db.commit();
}

/// Held strongholds pay war points once per hour and every member salvage once per day.
fn strongholdIncome(req: *Req) HandlerError!void {
    const db = &req.ctx.db;
    const hour = @divFloor(req.now, std.time.ms_per_hour);
    const day = game.war.dayIndex(req.now);
    const week = game.war.weekIndex(req.now);

    const Held = struct { id: []const u8, clan_id: i64, district: []const u8, faction: data.Faction, hours: i64, days: i64 };
    var held: std.ArrayList(Held) = .empty;
    {
        var st = try db.query(
            \\SELECT s.id, s.clan_id, s.district, c.faction, s.last_hour, s.last_day
            \\FROM strongholds s JOIN clans c ON c.id = s.clan_id WHERE s.week = ?
        , .{week});
        defer st.finalize();
        while (try st.step()) {
            try held.append(req.arena, .{
                .id = try st.dupe(req.arena, 0),
                .clan_id = st.int(1),
                .district = try st.dupe(req.arena, 2),
                .faction = @enumFromInt(st.int(3)),
                .hours = hour - st.int(4),
                .days = day - st.int(5),
            });
        }
    }
    for (held.items) |h| {
        if (h.hours > 0) {
            // Points belong to the clan's faction in the stronghold's district; no single player earns them.
            const pts: u32 = @intCast(@min(h.hours, 24) * game.war.points(.stronghold_hour));
            try db.run(
                "INSERT INTO war_district(week, district, faction, points) VALUES(?,?,?,?) ON CONFLICT(week, district, faction) DO UPDATE SET points = points + excluded.points",
                .{ week, h.district, h.faction, pts },
            );
            try db.run("UPDATE strongholds SET last_hour = ? WHERE id = ?", .{ hour, h.id });
        }
        if (h.days > 0) {
            try db.run("UPDATE players SET salvage = salvage + ? WHERE clan_id = ?", .{ daily_salvage, h.clan_id });
            try db.run("UPDATE strongholds SET last_day = ? WHERE id = ?", .{ day, h.id });
        }
    }
}
