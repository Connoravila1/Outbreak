//! Development endpoints, only routed when the server runs with --dev.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("../ctx.zig");
const model = @import("../model.zig");
const views = @import("../views.zig");
const rewards = @import("../rewards.zig");
const contact = @import("../contact.zig");
const snapshot = @import("../snapshot.zig");
const fight = @import("../fight.zig");
const notes_db = @import("../notes.zig");
const worldevents = @import("../worldevents.zig");

const data = game.data;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Stringify = std.json.Stringify;

pub fn grant(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct {
        xp: ?u32 = null,
        salvage: ?u32 = null,
        item: ?struct { base: []const u8, rarity: []const u8 } = null,
        consumable: ?struct { id: []const u8, n: u32 = 1 } = null,
        /// A note id, or "all" for every note this faction can find.
        note: ?[]const u8 = null,
    });
    var p = (try model.load(req, req.pid)).?;
    if (body.salvage) |s| p.salvage += s;
    if (body.item) |it| {
        const base = data.findBase(it.base) orelse return req.fail(400, "bad_request", "Unknown base item.");
        const rarity = std.meta.stringToEnum(data.Rarity, it.rarity) orelse return req.fail(400, "bad_request", "Unknown rarity.");
        var item = game.stats.Item{ .base = base, .rarity = rarity, .perk_count = data.rarity(rarity).perks };
        var rng = game.rng.Rng.init(game.rng.hash(req.ctx.seed, .{ "grant", p.id, req.now, req.ctx.rng.next() }));
        item.perk_ids = .{ @enumFromInt(rng.below(data.perks.len)), @enumFromInt(rng.below(data.perks.len)) };
        if (item.perk_ids[0] == item.perk_ids[1]) item.perk_ids[1] = @enumFromInt((@as(usize, @intFromEnum(item.perk_ids[0])) + 1) % data.perks.len);
        _ = try model.insertItem(req, p.id, item, false);
    }
    if (body.consumable) |c| {
        const kind = std.meta.stringToEnum(data.Consumable, c.id) orelse return req.fail(400, "bad_request", "Unknown consumable.");
        try model.addConsumable(req, p.id, kind, c.n);
    }
    if (body.note) |id| {
        if (std.mem.eql(u8, id, "all")) {
            for (game.notes.notes, 0..) |n, i| {
                if (game.notes.visibleTo(n, p.fac())) _ = try notes_db.grant(req, p.id, @intCast(i));
            }
        } else {
            const i = game.notes.indexOf(id) orelse return req.fail(400, "bad_request", "Unknown note.");
            _ = try notes_db.grant(req, p.id, i);
        }
    }
    var acc = rewards.Acc{ .xp = body.xp orelse 0, .flat_xp = true, .deliver_level_up = true };
    _ = try rewards.apply(req, &p, &acc, null);
    try jw.write(.{ .me = try views.meFresh(req, p.id) });
}

/// Scale the chance of a found cosmetic (a dev server only), so the drop can be seen on demand.
pub fn cosmeticOdds(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { scale: f64 });
    req.ctx.cosmetic_odds = @max(0.0, body.scale);
    try jw.write(.{ .scale = req.ctx.cosmetic_odds });
}

pub fn heal(req: *Req, jw: *Stringify) HandlerError!void {
    var p = (try model.load(req, req.pid)).?;
    p.downed_until = null;
    p.setHp(p.maxHp(req.now), req.now);
    try model.save(req, &p);
    try jw.write(.{ .me = try views.meFresh(req, p.id) });
}

/// Put the caller in the Downed state (to try the Downed UI, revive items and the timer).
pub fn down(req: *Req, jw: *Stringify) HandlerError!void {
    var p = (try model.load(req, req.pid)).?;
    p.down(req.now);
    try model.save(req, &p);
    try jw.write(.{ .me = try views.meFresh(req, p.id) });
}

/// Spawn (or refill) a raid boss at the stronghold of the cell the caller stands in.
pub fn spawnRaid(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { hp: ?i64 = null });
    const pos = req.ctx.live.position(req.pid, req.now) orelse return req.fail(409, "no_position", "Post a location first.");
    const cell = game.geo.encode(pos.lat, pos.lon, game.spawns.stronghold_precision);
    const district = game.war.districtId(pos.lat, pos.lon);
    const week = game.war.weekIndex(req.now);
    const id = try std.fmt.allocPrint(req.arena, "r.{d}.{s}", .{ week, district.str() });
    const hp = body.hp orelse 30_000;
    const db = &req.ctx.db;
    try db.run("DELETE FROM raids WHERE id = ?", .{id});
    try db.run(
        "INSERT INTO raids(id, district, week, site, hp, max_hp, created_at, ends_at) VALUES(?,?,?,?,?,?,?,?)",
        .{ id, district.str(), week, cell.str(), hp, hp, req.now, req.now + 48 * 60 * 60 * 1000 },
    );
    try jw.write(.{ .id = id });
}

/// Start a one-off event now (ends any running): `{type, hours?, kind?}`; `kind` is the swarm's archetype.
pub fn startEvent(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { type: []const u8, hours: ?i64 = null, kind: ?[]const u8 = null });
    const t = std.meta.stringToEnum(data.EventType, body.type) orelse return req.fail(400, "bad_request", "Unknown event type.");
    const kind = if (body.kind) |k| (data.findArchetype(k) orelse return req.fail(400, "bad_request", "Unknown archetype.")) else data.Archetype.runner;
    const id = try worldevents.startAdmin(&req.ctx.db, req.now, t, std.math.clamp(body.hours orelse 48, 1, 24 * 14), kind, req.ctx.opts.events);
    try jw.write(.{ .id = id });
}

pub fn stopEvent(req: *Req, jw: *Stringify) HandlerError!void {
    const n = try worldevents.stopAll(&req.ctx.db, req.now, req.ctx.opts.events);
    try jw.write(.{ .stopped = n });
}

pub fn resetCooldowns(req: *Req, jw: *Stringify) HandlerError!void {
    const db = &req.ctx.db;
    try db.run("DELETE FROM contact_log", .{});
    try db.run("UPDATE players SET last_pvp_at = 0", .{});
    try db.run("UPDATE raid_damage SET last_attack_at = 0", .{});
    req.ctx.live.chat_last.clearRetainingCapacity();
    req.ctx.live.echoes.clearRetainingCapacity();
    req.ctx.live.buckets.clearRetainingCapacity();
    try jw.write(.{ .ok = true });
}

pub fn botContact(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { rarity: ?[]const u8 = null, level: ?u8 = null, as: ?[]const u8 = null });
    var p = (try model.load(req, req.pid)).?;
    if (p.downed(req.now)) return req.fail(409, "downed", "You are down. Heal first.");
    var rng = game.rng.Rng.init(game.rng.hash(req.ctx.seed, .{ "bot", p.id, req.now, req.ctx.rng.next() }));
    const lvl: i32 = if (body.level) |l| std.math.clamp(@as(i32, l), 1, data.max_level) else std.math.clamp(@as(i32, p.level) + rng.intRange(-3, 3), 1, data.max_level);
    const roll = rng.float();
    var rarity: data.Rarity = if (roll < 0.6) .common else if (roll < 0.9) .uncommon else .rare;
    if (body.rarity) |r| rarity = std.meta.stringToEnum(data.Rarity, r) orelse return req.fail(400, "bad_request", "Unknown rarity.");
    var foe = snapshot.kitBuild(p.fac().opposite(), @intCast(lvl), rarity);
    // A chosen rarity is the weapon's; the armor and utility step down so the kit is mixed.
    if (body.rarity != null) for ([_]data.Rarity{ .uncommon, .common }, 1..) |r, i| {
        if (foe.items[i]) |*it| {
            it.rarity = r;
            it.perk_count = data.rarity(r).perks;
        }
    };
    const district: []const u8 = if (req.ctx.live.position(p.id, req.now)) |pos| try req.arena.dupe(u8, game.war.districtId(pos.lat, pos.lon).str()) else "dev0";
    const as: fight.CombatantKind = if (body.as) |n| (std.meta.stringToEnum(fight.CombatantKind, n) orelse return req.fail(400, "bad_request", "Unknown kind.")) else .player;
    try contact.stageBot(req, &p, &foe, district, as);
    try jw.write(.{ .ok = true });
}
