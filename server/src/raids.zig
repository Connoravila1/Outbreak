//! Raid bosses (DESIGN.md section 12): spawning on weekends, damage records, and the rewards paid
//! when a boss falls. Attacking itself is in api/social.zig.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("ctx.zig");
const model = @import("model.zig");
const rewards = @import("rewards.zig");
const fight = @import("fight.zig");

const data = game.data;
const geo = game.geo;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;

pub const duration_ms: i64 = 48 * 60 * 60 * 1000;
/// Boss HP pool per recently active player in the district.
pub const hp_per_player: i64 = 10_000;
pub const min_pool_players: i64 = 3;

const geohash_chars = "0123456789bcdefghjkmnpqrstuvwxyz";

pub const Raid = struct {
    id: []const u8,
    district: []const u8,
    hp: i64,
    max_hp: i64,
    ends_at: i64,
    settled: bool,
    lat: f64,
    lon: f64,
};

pub fn find(req: *Req, id: []const u8) HandlerError!?Raid {
    var st = try req.ctx.db.query("SELECT id, district, site, hp, max_hp, ends_at, settled FROM raids WHERE id = ?", .{id});
    defer st.finalize();
    if (!try st.step()) return null;
    const cell = geo.Geohash.parse(st.text(2)) catch return null;
    const site = game.spawns.stronghold(req.ctx.seed, cell);
    return .{
        .id = try st.dupe(req.arena, 0),
        .district = try st.dupe(req.arena, 1),
        .hp = st.int(3),
        .max_hp = st.int(4),
        .ends_at = st.int(5),
        .settled = st.int(6) != 0,
        .lat = site.lat,
        .lon = site.lon,
    };
}

pub fn lastAttack(req: *Req, raid_id: []const u8, pid: i64) HandlerError!i64 {
    return (try req.ctx.db.scalar("SELECT last_attack_at FROM raid_damage WHERE raid_id = ? AND player_id = ?", .{ raid_id, pid })) orelse 0;
}

pub fn hpLeft(req: *Req, raid_id: []const u8) HandlerError!i64 {
    return (try req.ctx.db.scalar("SELECT hp FROM raids WHERE id = ?", .{raid_id})) orelse 0;
}

pub fn recordDamage(req: *Req, raid_id: []const u8, pid: i64, dmg: i64) HandlerError!void {
    const db = &req.ctx.db;
    try db.run("UPDATE raids SET hp = MAX(0, hp - ?) WHERE id = ?", .{ dmg, raid_id });
    try db.run(
        "INSERT INTO raid_damage(raid_id, player_id, damage, last_attack_at) VALUES(?,?,?,?) ON CONFLICT(raid_id, player_id) DO UPDATE SET damage = damage + excluded.damage, last_attack_at = excluded.last_attack_at",
        .{ raid_id, pid, dmg, req.now },
    );
}

const Contributor = struct { pid: i64, damage: i64 };

/// Close a raid. When `killed`, every contributor is paid by damage share: salvage and XP always,
/// and a Rare-or-better item (very likely Legendary) for the top three.
pub fn settle(req: *Req, raid_id: []const u8, killed: bool) HandlerError!void {
    const db = &req.ctx.db;
    try db.run("UPDATE raids SET settled = 1 WHERE id = ?", .{raid_id});
    if (!killed) return;

    var list: std.ArrayList(Contributor) = .empty;
    var total: i64 = 0;
    {
        var st = try db.query("SELECT player_id, damage FROM raid_damage WHERE raid_id = ? AND damage > 0 ORDER BY damage DESC, player_id", .{raid_id});
        defer st.finalize();
        while (try st.step()) {
            try list.append(req.arena, .{ .pid = st.int(0), .damage = st.int(1) });
            total += st.int(1);
        }
    }
    if (total == 0) return;
    for (list.items, 0..) |c, rank| {
        var pl = (try model.load(req, c.pid)) orelse continue;
        const share: f32 = @as(f32, @floatFromInt(c.damage)) / @as(f32, @floatFromInt(total));
        var rng = game.rng.Rng.init(game.rng.hash(req.ctx.seed, .{ "raidloot", raid_id, c.pid }));
        var acc = rewards.Acc{ .flat_xp = true };
        const full = game.progression.pveWinXp(@as(u32, pl.level) + 2, .boss, 1.0);
        acc.xp = @intFromFloat(@round(@as(f32, @floatFromInt(full)) * (0.5 + share)));
        acc.salvage = 50 + @as(u32, @intFromFloat(@round(400.0 * share)));
        acc.deliver_level_up = true;
        if (rank < 3) {
            try acc.items.append(req.arena, game.loot.rollItem(&rng, .{ .level = pl.level, .min_rarity = .rare, .legendary_mult = 5.0 }));
        } else if (rng.chance(0.5)) {
            try acc.items.append(req.arena, game.loot.rollItem(&rng, .{ .level = pl.level, .min_rarity = .uncommon }));
        }
        const rw = try rewards.apply(req, &pl, &acc, null);
        const boss = data.archetype(.abomination).name.get(pl.fac());
        const text = try std.fmt.allocPrint(req.arena, "The {s} has fallen. You dealt {d}% of the damage with {d} fighters.", .{
            boss, @as(u32, @intFromFloat(@round(share * 100))), list.items.len,
        });
        try model.pushEvent(req, pl.id, "raid", text, null, try fight.toJson(req.arena, rw), false);
    }
}

fn isWeekend(now: i64) bool {
    // Day 0 (1970-01-01) was a Thursday; Monday is 0 here.
    const monday_based = @mod(game.war.dayIndex(now) - 4, 7);
    return monday_based >= 5;
}

/// Weekend upkeep (called from the tick): a boss for every district with activity in the last
/// 7 days, and the end of expired raids.
pub fn upkeep(req: *Req) HandlerError!void {
    const db = &req.ctx.db;
    try db.run("UPDATE raids SET settled = 1 WHERE settled = 0 AND ends_at <= ?", .{req.now});
    if (!isWeekend(req.now)) return;
    const week = game.war.weekIndex(req.now);

    var districts: std.ArrayList([]const u8) = .empty;
    {
        var st = try db.query("SELECT DISTINCT district FROM war_player WHERE week >= ?", .{week - 1});
        defer st.finalize();
        while (try st.step()) try districts.append(req.arena, try st.dupe(req.arena, 0));
    }
    for (districts.items) |district| {
        const id = try std.fmt.allocPrint(req.arena, "r.{d}.{s}", .{ week, district });
        if ((try db.scalar("SELECT 1 FROM raids WHERE id = ?", .{id})) != null) continue;
        const active = (try db.scalar("SELECT COUNT(DISTINCT player_id) FROM war_player WHERE district = ? AND week >= ?", .{ district, week - 1 })) orelse 1;
        const max_hp = @max(min_pool_players, active) * hp_per_player;
        var rng = game.rng.derive(req.ctx.seed, .{ "raidsite", district, week });
        var site_buf: [6]u8 = undefined;
        @memcpy(site_buf[0..4], district[0..4]);
        site_buf[4] = geohash_chars[rng.below(32)];
        site_buf[5] = geohash_chars[rng.below(32)];
        try db.run(
            "INSERT INTO raids(id, district, week, site, hp, max_hp, created_at, ends_at) VALUES(?,?,?,?,?,?,?,?)",
            .{ id, district, week, @as([]const u8, &site_buf), max_hp, max_hp, req.now, req.now + duration_ms },
        );
    }
}

test "weekend detection" {
    // 2026-10-31 is a Saturday; 2026-10-26 a Monday.
    const sat: i64 = 1_793_448_000_000;
    try std.testing.expect(isWeekend(sat));
    try std.testing.expect(isWeekend(sat + game.war.day_ms));
    try std.testing.expect(!isWeekend(sat + 2 * game.war.day_ms));
    try std.testing.expect(!isWeekend(sat - 5 * game.war.day_ms));
}
