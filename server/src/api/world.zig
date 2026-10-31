//! World endpoints: /api/location (the world around you), /api/engage (fight an enemy or Echo),
//! /api/open (caches and airdrops).

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("../ctx.zig");
const model = @import("../model.zig");
const views = @import("../views.zig");
const fight = @import("../fight.zig");
const rewards = @import("../rewards.zig");
const missions = @import("../missions.zig");
const events = @import("../events.zig");
const echo_mod = @import("../echo.zig");
const live = @import("../live.zig");

const data = game.data;
const geo = game.geo;
const spawns = game.spawns;
const progression = game.progression;
const loot = game.loot;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Player = model.Player;
const Stringify = std.json.Stringify;

/// Content is shown within 450 m and can be touched within 50 m (plus GPS slack).
pub const view_radius_m = 450.0;
pub const reach_m = 50.0;
pub const reach_slack_max_m = 25.0;
pub const hostile_radius_m = 500.0;
pub const airdrop_radius_m = 2000.0;
pub const stronghold_radius_m = 1500.0;
/// A position implying more than this speed is rejected.
pub const max_speed_ms = 45.0;

pub fn withinReach(pos: live.Pos, lat: f64, lon: f64) bool {
    return geo.haversineM(pos.lat, pos.lon, lat, lon) <= reach_m + @min(@as(f64, pos.acc), reach_slack_max_m);
}

// --- /api/location -------------------------------------------------------------------------------------

const EnemyView = struct { id: []const u8, archetype: []const u8, level: u32, elite: bool, lat: f64, lon: f64, expires_at: i64 };
const CacheView = struct { id: []const u8, kind: []const u8, lat: f64, lon: f64, expires_at: i64 };
const EchoView = struct { id: []const u8, level: u8, faction: data.Faction, title: []const u8, rogue: bool, lat: f64, lon: f64, expires_at: i64 };
const ClanTag = struct { tag: []const u8, name: []const u8, faction: data.Faction };
const StrongholdView = struct { id: []const u8, lat: f64, lon: f64, clan: ?ClanTag };
const RaidView = struct { id: []const u8, boss: []const u8, lat: f64, lon: f64, hp: i64, max_hp: i64, ends_at: i64, fighters: u32, can_attack_at: i64 };

const Fix = struct { lat: f64, lon: f64, acc: f64 = 0, sanctuary: bool = false };

pub fn location(req: *Req, jw: *Stringify) HandlerError!void {
    const fix = try req.json(Fix);
    if (!(fix.lat >= -90 and fix.lat <= 90 and fix.lon >= -180 and fix.lon <= 180)) {
        return req.fail(400, "bad_request", "That is not a valid position.");
    }
    const ctx = req.ctx;
    const now = req.now;
    var p = (try model.load(req, req.pid)).?;
    const acc: f32 = @floatCast(std.math.clamp(if (std.math.isNan(fix.acc)) 0 else fix.acc, 0, 10_000));

    var pos = live.Pos{ .lat = fix.lat, .lon = fix.lon, .acc = acc, .sanctuary = fix.sanctuary, .faction = p.fac(), .at = now };
    if (ctx.live.position(p.id, now)) |prev| {
        const d = geo.haversineM(prev.lat, prev.lon, fix.lat, fix.lon);
        const dt_s = @max(1.0, @as(f64, @floatFromInt(now - prev.at)) / 1000.0);
        if (d / dt_s > max_speed_ms) {
            // A jump no one could walk (or drive): keep the old position and answer from it.
            pos = prev;
        } else {
            pos.carry_m = prev.carry_m;
            if (d / dt_s <= progression.walk_max_speed_ms and now - prev.at <= 60_000 and d >= 3.0) pos.carry_m += d;
        }
    }

    try payWalking(req, &p, &pos);
    try ctx.live.setPosition(p.id, pos);

    // Everything below is a function of the accepted position.
    var enemies: std.ArrayList(EnemyView) = .empty;
    var caches: std.ArrayList(CacheView) = .empty;
    var echoes: std.ArrayList(EchoView) = .empty;
    if (!pos.sanctuary) {
        try worldEnemies(req, &p, pos, &enemies);
        try worldCaches(req, &p, pos, &caches);
        if (try echo_mod.current(req, &p, pos)) |e| {
            const id = e.id();
            const id_str = try req.arena.dupe(u8, std.mem.sliceTo(&id, 0));
            if (!try isDone(req, p.id, id_str)) try echoes.append(req.arena, .{
                .id = id_str,
                .level = e.build.level,
                .faction = e.build.faction,
                .title = progression.title(e.build.faction, e.build.level),
                .rogue = e.rogue,
                .lat = e.lat,
                .lon = e.lon,
                .expires_at = e.expires_at,
            });
        }
    }

    var strongholds: std.ArrayList(StrongholdView) = .empty;
    try worldStrongholds(req, pos, &strongholds);
    var raids: std.ArrayList(RaidView) = .empty;
    try worldRaids(req, &p, pos, &raids);

    try jw.write(.{
        .now = now,
        .me = views.meLite(&p, now),
        .hostiles_near = !pos.sanctuary and hostilesNear(req, &p, pos),
        .enemies = enemies.items,
        .caches = caches.items,
        .echoes = echoes.items,
        .strongholds = strongholds.items,
        .raids = raids.items,
        .events = try events.takeUndelivered(req, p.id),
    });
}

/// Pay walking XP for the distance carried in the live position.
fn payWalking(req: *Req, p: *Player, pos: *live.Pos) HandlerError!void {
    const per = progression.walk_metres_per_xp;
    const whole: u32 = @intFromFloat(@floor(pos.carry_m));
    const metres = whole - whole % per;
    if (metres == 0) return;
    pos.carry_m -= @floatFromInt(metres);

    const today = game.war.dayIndex(req.now);
    if (p.walk_day != today) {
        p.walk_day = today;
        p.walk_xp_today = 0;
    }
    const xp = progression.walkXp(metres, p.walk_xp_today);
    p.walk_xp_today += xp;
    p.distance_m += metres;
    try missions.event(req, p, .{ .kind = .walk, .amount = metres });
    var acc = rewards.Acc{ .xp = xp, .deliver_level_up = true };
    _ = try rewards.apply(req, p, &acc, null);
}

fn isDone(req: *Req, pid: i64, sid: []const u8) HandlerError!bool {
    return (try req.ctx.db.scalar("SELECT 1 FROM done WHERE player_id = ? AND sid = ?", .{ pid, sid })) != null;
}

fn worldEnemies(req: *Req, p: *const Player, pos: live.Pos, out: *std.ArrayList(EnemyView)) HandlerError!void {
    var cells: [128]geo.Geohash = undefined;
    const n = geo.cellsWithin(pos.lat, pos.lon, view_radius_m, spawns.enemy_precision, &cells);
    const window = spawns.windowIndex(req.now, spawns.enemy_window_ms);
    var buf: [spawns.max_enemies_per_cell]spawns.Enemy = undefined;
    for (cells[0..n]) |cell| {
        for (spawns.enemiesInCell(req.ctx.seed, cell, window, &buf)) |e| {
            if (geo.haversineM(pos.lat, pos.lon, e.lat, e.lon) > view_radius_m) continue;
            const id = e.id();
            if (try isDone(req, p.id, id.str())) continue;
            try out.append(req.arena, .{
                .id = try req.arena.dupe(u8, id.str()),
                .archetype = @tagName(e.archetype),
                .level = e.levelFor(p.level),
                .elite = e.elite,
                .lat = e.lat,
                .lon = e.lon,
                .expires_at = e.expires_at,
            });
        }
    }
}

fn worldCaches(req: *Req, p: *const Player, pos: live.Pos, out: *std.ArrayList(CacheView)) HandlerError!void {
    var cells: [128]geo.Geohash = undefined;
    const n = geo.cellsWithin(pos.lat, pos.lon, view_radius_m, spawns.cache_precision, &cells);
    const window = spawns.windowIndex(req.now, spawns.cache_window_ms);
    for (cells[0..n]) |cell| {
        const c = spawns.cache(req.ctx.seed, cell, window) orelse continue;
        if (geo.haversineM(pos.lat, pos.lon, c.lat, c.lon) > view_radius_m) continue;
        const id = c.id();
        if (try isDone(req, p.id, id.str())) continue;
        try out.append(req.arena, .{ .id = try req.arena.dupe(u8, id.str()), .kind = "cache", .lat = c.lat, .lon = c.lon, .expires_at = c.expires_at });
    }
    if (p.level < airdrop_min_level) return;
    var regions: [32]geo.Geohash = undefined;
    const rn = geo.cellsWithin(pos.lat, pos.lon, airdrop_radius_m, spawns.airdrop_precision, &regions);
    const aw = spawns.windowIndex(req.now, spawns.airdrop_window_ms);
    for (regions[0..rn]) |region| {
        const a = spawns.airdrop(req.ctx.seed, region, aw);
        if (!a.liveAt(req.now)) continue;
        if (geo.haversineM(pos.lat, pos.lon, a.lat, a.lon) > airdrop_radius_m) continue;
        const id = a.id();
        if (try isDone(req, p.id, id.str())) continue;
        try out.append(req.arena, .{ .id = try req.arena.dupe(u8, id.str()), .kind = "airdrop", .lat = a.lat, .lon = a.lon, .expires_at = a.expires_at });
    }
}

pub const airdrop_min_level = 8;

fn worldStrongholds(req: *Req, pos: live.Pos, out: *std.ArrayList(StrongholdView)) HandlerError!void {
    var cells: [64]geo.Geohash = undefined;
    const n = geo.cellsWithin(pos.lat, pos.lon, stronghold_radius_m, spawns.stronghold_precision, &cells);
    const week = game.war.weekIndex(req.now);
    for (cells[0..n]) |cell| {
        const s = spawns.stronghold(req.ctx.seed, cell);
        if (geo.haversineM(pos.lat, pos.lon, s.lat, s.lon) > stronghold_radius_m) continue;
        const id = try req.arena.dupe(u8, s.id().str());
        var clan: ?ClanTag = null;
        var st = try req.ctx.db.query(
            "SELECT c.tag, c.name, c.faction FROM strongholds s JOIN clans c ON c.id = s.clan_id WHERE s.id = ? AND s.week = ?",
            .{ id, week },
        );
        defer st.finalize();
        if (try st.step()) clan = .{ .tag = try st.dupe(req.arena, 0), .name = try st.dupe(req.arena, 1), .faction = @enumFromInt(st.int(2)) };
        try out.append(req.arena, .{ .id = id, .lat = s.lat, .lon = s.lon, .clan = clan });
    }
}

const raid_view_radius_m = 3000.0;
pub const raid_attack_gap_ms: i64 = 60 * 60 * 1000;

fn worldRaids(req: *Req, p: *const Player, pos: live.Pos, out: *std.ArrayList(RaidView)) HandlerError!void {
    var st = try req.ctx.db.query(
        \\SELECT r.id, r.site, r.hp, r.max_hp, r.ends_at,
        \\  (SELECT COUNT(*) FROM raid_damage d WHERE d.raid_id = r.id),
        \\  COALESCE((SELECT last_attack_at FROM raid_damage d WHERE d.raid_id = r.id AND d.player_id = ?), 0)
        \\FROM raids r WHERE r.ends_at > ? AND r.settled = 0 AND r.hp > 0
    , .{ p.id, req.now });
    defer st.finalize();
    while (try st.step()) {
        const cell = geo.Geohash.parse(st.text(1)) catch continue;
        const site = spawns.stronghold(req.ctx.seed, cell);
        if (geo.haversineM(pos.lat, pos.lon, site.lat, site.lon) > raid_view_radius_m) continue;
        const last = st.int(6);
        try out.append(req.arena, .{
            .id = try st.dupe(req.arena, 0),
            .boss = data.archetype(.abomination).name.get(p.fac()),
            .lat = site.lat,
            .lon = site.lon,
            .hp = st.int(2),
            .max_hp = st.int(3),
            .ends_at = st.int(4),
            .fighters = @intCast(st.int(5)),
            .can_attack_at = if (last == 0) 0 else last + raid_attack_gap_ms,
        });
    }
}

fn hostilesNear(req: *Req, p: *const Player, pos: live.Pos) bool {
    var it = req.ctx.live.positions.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.* == p.id) continue;
        const o = e.value_ptr.*;
        if (req.now - o.at > live.position_ttl_ms or o.sanctuary or o.faction == p.fac()) continue;
        if (geo.haversineM(pos.lat, pos.lon, o.lat, o.lon) <= hostile_radius_m) return true;
    }
    return false;
}

// --- Fighting ----------------------------------------------------------------------------------------------

fn requireReady(req: *Req, p: *const Player) HandlerError!live.Pos {
    if (p.downed(req.now)) return req.fail(409, "downed", "You are down. Heal, or wait to get back up.");
    const pos = req.ctx.live.position(p.id, req.now) orelse
        return req.fail(409, "no_position", "Your position is unknown. Wait for a location update.");
    if (pos.sanctuary) return req.fail(409, "sanctuary", "Nothing can be fought in a sanctuary.");
    return pos;
}

fn districtOf(arena: std.mem.Allocator, lat: f64, lon: f64) ![]const u8 {
    return arena.dupe(u8, game.war.districtId(lat, lon).str());
}

pub fn engage(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { id: []const u8 });
    var p = (try model.load(req, req.pid)).?;
    const pos = try requireReady(req, &p);
    if (std.mem.startsWith(u8, body.id, "x.")) return engageEcho(req, jw, &p, pos, body.id);
    return engageEnemy(req, jw, &p, pos, body.id);
}

fn markDone(req: *Req, pid: i64, sid: []const u8, expires_at: i64) HandlerError!void {
    try req.ctx.db.run("INSERT OR IGNORE INTO done(player_id, sid, expires_at) VALUES(?,?,?)", .{ pid, sid, expires_at });
}

fn engageEnemy(req: *Req, jw: *Stringify, p: *Player, pos: live.Pos, id: []const u8) HandlerError!void {
    const en = spawns.resolveEnemy(req.ctx.seed, id, req.now) orelse return req.fail(404, "not_found", "That enemy is gone.");
    if (!withinReach(pos, en.lat, en.lon)) return req.fail(409, "too_far", "Get closer to engage.");
    if (try isDone(req, p.id, id)) return req.fail(409, "already_defeated", "You already defeated that one.");

    const level = en.levelFor(p.level);
    const a = try fight.selfSide(req, p);
    const b = try fight.enemySide(req.arena, p.fac(), en.archetype, level, en.elite, false);
    const o = try fight.run(req, a, b, fight.seedFor(req, p.id, game.rng.hashBytes(1, id)));
    const row = data.archetype(en.archetype);

    var acc = rewards.Acc{};
    const win_xp = progression.pveWinXp(level, if (en.elite) .elite else .normal, row.reward_mult);
    const district = try districtOf(req.arena, en.lat, en.lon);
    if (o.won()) {
        acc.xp = win_xp;
        var lrng = game.rng.Rng.init(game.rng.hash(o.seed, .{"loot"}));
        try acc.addDrop(req, loot.rollPve(&lrng, .{ .player_level = p.level, .enemy_level = level, .archetype = en.archetype, .loot_mult = rewards.lootMult(p, req.now) }));
        acc.war_points = game.war.points(if (en.elite) .pve_elite else .pve_win);
        p.wins += 1;
        try markDone(req, p.id, id, en.expires_at);
    } else {
        acc.xp = progression.pveLossXp(win_xp);
        p.losses += 1;
    }
    rewards.settleHp(p, o.result.hp_a, req.now);
    const rw = try rewards.apply(req, p, &acc, district);
    if (o.won()) try missions.event(req, p, .{ .kind = .pve_win, .archetype = en.archetype, .elite = en.elite });

    const me = try views.meFresh(req, p.id);
    try jw.write(try fight.battleView(req, .pve, a, b, o, rw, me));
}

fn engageEcho(req: *Req, jw: *Stringify, p: *Player, pos: live.Pos, id: []const u8) HandlerError!void {
    const ctx = req.ctx;
    const window = echo_mod.windowOf(req.now);
    const e = ctx.live.echoFor(p.id, window) orelse return req.fail(404, "not_found", "That echo has faded.");
    var expect = e.id();
    if (e.none or !std.mem.eql(u8, std.mem.sliceTo(&expect, 0), id) or e.expires_at <= req.now) {
        return req.fail(404, "not_found", "That echo has faded.");
    }
    if (!withinReach(pos, e.lat, e.lon)) return req.fail(409, "too_far", "Get closer to engage.");
    if (try isDone(req, p.id, id)) return req.fail(409, "already_defeated", "You already faced that echo.");

    const a = try fight.selfSide(req, p);
    const b = try fight.buildSide(req.arena, &e.build, if (e.rogue) .rogue else .echo, null);
    const o = try fight.run(req, a, b, fight.seedFor(req, p.id, game.rng.hashBytes(2, id)));

    var acc = rewards.Acc{};
    const win_xp = progression.echoWinXp(e.build.level);
    const district = try districtOf(req.arena, e.lat, e.lon);
    if (o.won()) {
        acc.xp = win_xp;
        var lrng = game.rng.Rng.init(game.rng.hash(o.seed, .{"loot"}));
        try acc.addDrop(req, loot.rollPvp(&lrng, p.level, e.build.level, rewards.lootMult(p, req.now)));
        acc.war_points = game.war.points(.echo_win);
        p.wins += 1;
    } else {
        acc.xp = progression.lossXp(win_xp, progression.pvp_loss_fraction);
        p.losses += 1;
    }
    p.echoes += 1;
    try markDone(req, p.id, id, e.expires_at);
    ctx.live.dropEcho(p.id);
    rewards.settleHp(p, o.result.hp_a, req.now);
    const rw = try rewards.apply(req, p, &acc, district);
    if (o.won()) try missions.event(req, p, .{ .kind = .contact_win });
    if (e.source) |owner| try reportToOwner(req, owner, o.won(), p.fac());

    const me = try views.meFresh(req, p.id);
    try jw.write(try fight.battleView(req, .echo, a, b, o, rw, me));
}

/// Tell the player whose snapshot was fought how it did; if it held they earn a little XP.
fn reportToOwner(req: *Req, owner_id: i64, echo_won_for_challenger: bool, challenger: data.Faction) HandlerError!void {
    var owner = (try model.load(req, owner_id)) orelse return;
    const who = if (challenger == .human) "a Human" else "a Zombie";
    if (echo_won_for_challenger) {
        try model.pushEvent(req, owner.id, "echo_report", "Your echo fell.", null, null, false);
        return;
    }
    var acc = rewards.Acc{ .xp = 10 + owner.level / 2, .flat_xp = true, .deliver_level_up = true };
    const rw = try rewards.apply(req, &owner, &acc, null);
    const text = try std.fmt.allocPrint(req.arena, "Your echo held against {s} (+{d} XP).", .{ who, rw.xp });
    const body = try fight.toJson(req.arena, rw);
    try model.pushEvent(req, owner.id, "echo_report", text, null, body, false);
}

// --- /api/open ---------------------------------------------------------------------------------------------

pub fn open(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { id: []const u8 });
    var p = (try model.load(req, req.pid)).?;
    const id = body.id;
    if (p.downed(req.now)) {
        // Looting does not need a fight, but a downed player is in no state to walk up to a crate.
        return req.fail(409, "downed", "You are down. Heal, or wait to get back up.");
    }
    const pos = req.ctx.live.position(p.id, req.now) orelse
        return req.fail(409, "no_position", "Your position is unknown. Wait for a location update.");
    if (pos.sanctuary) return req.fail(409, "sanctuary", "Nothing can be opened in a sanctuary.");

    var lat: f64 = undefined;
    var lon: f64 = undefined;
    var expires: i64 = undefined;
    var airdrop = false;
    if (spawns.resolveCache(req.ctx.seed, id, req.now)) |c| {
        lat = c.lat;
        lon = c.lon;
        expires = c.expires_at;
    } else if (spawns.resolveAirdrop(req.ctx.seed, id, req.now)) |a| {
        if (p.level < airdrop_min_level) return req.fail(409, "locked", "Airdrops unlock at level 8.");
        lat = a.lat;
        lon = a.lon;
        expires = a.expires_at;
        airdrop = true;
    } else return req.fail(404, "not_found", "That is gone.");

    if (!withinReach(pos, lat, lon)) return req.fail(409, "too_far", "Get closer to open it.");
    if (try isDone(req, p.id, id)) return req.fail(409, "already_opened", "You already opened that.");
    try markDone(req, p.id, id, expires);

    var lrng = game.rng.Rng.init(game.rng.hash(req.ctx.seed, .{ "open", p.id, id, req.now }));
    const mult = rewards.lootMult(&p, req.now);
    var acc = rewards.Acc{ .xp = progression.cacheXp(p.level), .war_points = game.war.points(.cache) };
    try acc.addDrop(req, if (airdrop) loot.rollAirdrop(&lrng, p.level, mult) else loot.rollCache(&lrng, p.level, mult));
    p.caches += 1;
    const rw = try rewards.apply(req, &p, &acc, try districtOf(req.arena, lat, lon));
    try missions.event(req, &p, .{ .kind = .cache_open });
    try jw.write(.{ .loot = rw, .me = try views.meFresh(req, p.id) });
}
