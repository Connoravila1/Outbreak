//! Achievements, the collection log and cosmetics on the server side: the running counters,
//! what a player has ever held, evaluating milestones when something changes, and what is owned.
//! The rules (what each milestone needs, what it pays) are in game/achievements.zig and
//! game/cosmetics.zig.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("ctx.zig");
const model = @import("model.zig");

const ga = game.achievements;
const gc = game.cosmetics;
const data = game.data;
const stats = game.stats;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Player = model.Player;

/// A newly earned achievement as the client toasts it: named for the player's own faction.
pub const EarnedView = struct {
    id: []const u8,
    name: []const u8,
    text: []const u8,
    salvage: u32,
    title: ?[]const u8,
    cosmetic: ?[]const u8,
};

// --- Counters and discoveries ------------------------------------------------------------------

/// Add `n` to a running total (or raise a best, for the two that keep a maximum).
pub fn bump(req: *Req, pid: i64, c: ga.Counter, n: u64) HandlerError!void {
    const sql = if (c.isMax())
        "INSERT INTO counters(player_id, key, n) VALUES(?,?,?) ON CONFLICT(player_id, key) DO UPDATE SET n = MAX(n, excluded.n)"
    else
        "INSERT INTO counters(player_id, key, n) VALUES(?,?,?) ON CONFLICT(player_id, key) DO UPDATE SET n = n + excluded.n";
    try req.ctx.db.run(sql, .{ pid, @tagName(c), n });
}

pub const Discovery = enum(u8) { base = 0, unique = 1, rarity = 2 };

/// Record that `pid` has held `item`: its base, its legendary unique if any, and its rarity.
pub fn discover(req: *Req, pid: i64, item: stats.Item) HandlerError!void {
    const db = &req.ctx.db;
    const sql = "INSERT OR IGNORE INTO discoveries(player_id, kind, idx, first_at) VALUES(?,?,?,?)";
    try db.run(sql, .{ pid, @intFromEnum(Discovery.base), item.base, req.now });
    if (item.unique) |u| try db.run(sql, .{ pid, @intFromEnum(Discovery.unique), u, req.now });
    try db.run(sql, .{ pid, @intFromEnum(Discovery.rarity), @intFromEnum(item.rarity), req.now });
}

/// Indexes discovered of one kind, ascending.
pub fn discovered(req: *Req, pid: i64, kind: Discovery) HandlerError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var st = try req.ctx.db.query("SELECT idx FROM discoveries WHERE player_id = ? AND kind = ? ORDER BY idx", .{ pid, @intFromEnum(kind) });
    defer st.finalize();
    while (try st.step()) try out.append(req.arena, @intCast(st.int(0)));
    return out.items;
}

// --- Metrics -------------------------------------------------------------------------------------

/// Every metric's current value for `p`.
pub fn metrics(req: *Req, p: *const Player) HandlerError!ga.Metrics {
    const db = &req.ctx.db;
    var m = ga.Metrics.initFill(0);
    m.set(.distance_m, p.distance_m);
    m.set(.contacts_won, p.contacts_won);
    m.set(.echoes_won, p.echoes_won);
    m.set(.caches, p.caches);
    m.set(.level, p.level);
    {
        var st = try db.query("SELECT key, n FROM counters WHERE player_id = ?", .{p.id});
        defer st.finalize();
        while (try st.step()) {
            if (std.meta.stringToEnum(ga.Counter, st.text(0))) |c| m.set(c.metric(), @intCast(@max(0, st.int(1))));
        }
    }
    m.set(.notes_found, @intCast(try db.scalar("SELECT COUNT(*) FROM player_notes WHERE player_id = ?", .{p.id}) orelse 0));
    m.set(.sets_claimed, @intCast(try db.scalar("SELECT COUNT(*) FROM note_claims WHERE player_id = ?", .{p.id}) orelse 0));
    m.set(.bases_found, @intCast(try db.scalar("SELECT COUNT(*) FROM discoveries WHERE player_id = ? AND kind = 0", .{p.id}) orelse 0));
    m.set(.uniques_found, @intCast(try db.scalar("SELECT COUNT(*) FROM discoveries WHERE player_id = ? AND kind = 1", .{p.id}) orelse 0));
    if (try db.scalar("SELECT MAX(idx) FROM discoveries WHERE player_id = ? AND kind = 2", .{p.id})) |r| {
        m.set(.best_rarity, ga.rarityMetric(@enumFromInt(r)));
    }
    if (try db.scalar("SELECT created_at FROM players WHERE id = ?", .{p.id})) |created| {
        m.set(.days, @intCast(@max(0, @divFloor(req.now - created, game.war.day_ms))));
    }
    return m;
}

pub fn earnedSet(req: *Req, pid: i64) HandlerError!ga.Earned {
    var have = ga.Earned.initEmpty();
    var st = try req.ctx.db.query("SELECT ach_id FROM achievements WHERE player_id = ?", .{pid});
    defer st.finalize();
    while (try st.step()) {
        if (ga.find(st.text(0))) |i| have.set(i);
    }
    return have;
}

/// Earn whatever `p` now qualifies for: record it, pay the salvage (into `p`, which the caller
/// saves), unlock cosmetics and queue one "achievement" event each. With `deliver` the event waits
/// for the next poll (the player is not looking at a response that shows it); otherwise it goes
/// straight to the feed.
pub fn check(req: *Req, p: *Player, deliver: bool) HandlerError![]const EarnedView {
    const have = try earnedSet(req, p.id);
    const m = try metrics(req, p);
    var buf: [ga.list.len]u8 = undefined;
    const idxs = ga.newlyEarned(m, have, &buf);
    if (idxs.len == 0) return &.{};
    const db = &req.ctx.db;
    const f = p.fac();
    var out: std.ArrayList(EarnedView) = .empty;
    for (idxs) |i| {
        const a = ga.list[i];
        try db.run("INSERT OR IGNORE INTO achievements(player_id, ach_id, earned_at) VALUES(?,?,?)", .{ p.id, a.id, req.now });
        if (db.changes() == 0) continue;
        p.salvage += a.salvage;
        if (a.cosmetic) |c| try grantCosmetic(req, p.id, c);
        const v = EarnedView{
            .id = a.id,
            .name = a.name.get(f),
            .text = a.text,
            .salvage = a.salvage,
            .title = if (a.title) |t| t.get(f) else null,
            .cosmetic = a.cosmetic,
        };
        try out.append(req.arena, v);
        const one = [1]EarnedView{v};
        const body = try std.json.Stringify.valueAlloc(req.arena, .{ .achievements = &one }, .{});
        const text = try std.fmt.allocPrint(req.arena, "Achievement: {s} (+{d} salvage).", .{ v.name, v.salvage });
        try model.pushEvent(req, p.id, "achievement", text, null, body, !deliver);
    }
    return out.items;
}

/// The cosmetic titles earned by achievements, in the order they were earned.
pub fn titles(req: *Req, pid: i64, f: data.Faction) HandlerError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var st = try req.ctx.db.query("SELECT ach_id FROM achievements WHERE player_id = ? ORDER BY earned_at, rowid", .{pid});
    defer st.finalize();
    while (try st.step()) {
        const i = ga.find(st.text(0)) orelse continue;
        if (ga.list[i].title) |t| try out.append(req.arena, t.get(f));
    }
    return out.items;
}

// --- Cosmetics -----------------------------------------------------------------------------------

pub fn grantCosmetic(req: *Req, pid: i64, id: []const u8) HandlerError!void {
    try req.ctx.db.run("INSERT OR IGNORE INTO cosmetics(player_id, cosmetic_id, acquired_at) VALUES(?,?,?)", .{ pid, id, req.now });
}

pub fn owns(req: *Req, pid: i64, id: []const u8) HandlerError!bool {
    return (try req.ctx.db.scalar("SELECT 1 FROM cosmetics WHERE player_id = ? AND cosmetic_id = ?", .{ pid, id })) != null;
}

/// Ids owned, in the order of the catalogue.
pub fn owned(req: *Req, pid: i64) HandlerError![]const []const u8 {
    var have: std.StaticBitSet(gc.list.len) = .initEmpty();
    var st = try req.ctx.db.query("SELECT cosmetic_id FROM cosmetics WHERE player_id = ?", .{pid});
    defer st.finalize();
    while (try st.step()) {
        if (gc.find(st.text(0))) |i| have.set(i);
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (gc.list, 0..) |c, i| {
        if (have.isSet(i)) try out.append(req.arena, c.id);
    }
    return out.items;
}

/// `null` for "none equipped".
pub fn optId(text: []const u8) ?[]const u8 {
    return if (text.len == 0) null else text;
}

/// The equipped colour in column `col` of the row being read (null for none), copied into the arena.
pub fn colorOf(req: *Req, st: anytype, col: usize) HandlerError!?[]const u8 {
    const t = st.text(col);
    if (t.len == 0) return null;
    return try req.arena.dupe(u8, t);
}
