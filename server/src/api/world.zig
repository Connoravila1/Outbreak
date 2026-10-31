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
const daynight = game.daynight;
const landmarks = game.landmarks;
const stance_rules = game.stance;
const progression = game.progression;
const stats = game.stats;
const loot = game.loot;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Player = model.Player;
const Stringify = std.json.Stringify;

/// Content is shown within 400 m and can be touched within 50 m (plus GPS slack).
pub const view_radius_m = 400.0;
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

const EnemyView = struct { id: []const u8, archetype: []const u8, level: u32, elite: bool, tutorial: bool, lat: f64, lon: f64, expires_at: i64 };
const CacheView = struct { id: []const u8, kind: []const u8, lat: f64, lon: f64, expires_at: i64 };
const EchoView = struct { id: []const u8, level: u8, faction: data.Faction, title: []const u8, rogue: bool, lat: f64, lon: f64, expires_at: i64 };
const ClanTag = struct { tag: []const u8, name: []const u8, faction: data.Faction };
const StrongholdView = struct { id: []const u8, lat: f64, lon: f64, clan: ?ClanTag };
const RaidView = struct { id: []const u8, boss: []const u8, lat: f64, lon: f64, hp: i64, max_hp: i64, ends_at: i64, fighters: u32, can_attack_at: i64 };

const LandmarkView = struct { id: []const u8, kind: []const u8, name: ?[]const u8, lat: f64, lon: f64, available: bool, available_at: ?i64 };
const TimeView = struct { phase: []const u8, changes_at: i64 };

const Fix = struct { lat: f64, lon: f64, acc: f64 = 0, sanctuary: bool = false, places: []const landmarks.Report = &.{} };

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

    // Real places from the client's own map tiles; remembered in memory, never stored.
    var places: std.ArrayList(LandmarkView) = .empty;
    if (!pos.sanctuary) {
        for (fix.places[0..@min(fix.places.len, landmarks.max_per_report)]) |r| {
            const pl = landmarks.validate(r, pos.lat, pos.lon) orelse continue;
            _ = try ctx.live.rememberPlace(pl, p.id, now);
        }
        try worldLandmarks(req, &p, pos, &places);
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
        .landmarks = places.items,
        .time = timeView(now, pos.lon),
        .strongholds = strongholds.items,
        .raids = raids.items,
        .events = try events.takeUndelivered(req, p.id),
    });
}

fn timeView(now: i64, lon: f64) TimeView {
    return .{ .phase = @tagName(daynight.phaseAt(now, lon)), .changes_at = daynight.changesAt(now, lon) };
}

fn worldLandmarks(req: *Req, p: *const Player, pos: live.Pos, out: *std.ArrayList(LandmarkView)) HandlerError!void {
    var found: std.ArrayList(live.Remembered) = .empty;
    try req.ctx.live.placesFor(p.id, pos.lat, pos.lon, view_radius_m, req.now, &found, req.arena);
    const window = landmarks.windowIndex(req.now);
    for (found.items) |r| {
        if (out.items.len >= landmarks.max_per_report) break;
        const id = landmarks.formatId(r.place.keyStr(), window);
        const id_str = try req.arena.dupe(u8, id.str());
        const done = try isDone(req, p.id, id_str);
        try out.append(req.arena, .{
            .id = id_str,
            .kind = @tagName(r.place.kind),
            .name = if (r.place.name.len > 0) try req.arena.dupe(u8, r.place.name.str()) else null,
            .lat = r.place.lat,
            .lon = r.place.lon,
            .available = !done,
            .available_at = if (done) landmarks.nextWindowAt(req.now) else null,
        });
    }
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
            if (!e.visibleTo(p.level)) continue;
            const id = e.id();
            if (try isDone(req, p.id, id.str())) continue;
            try out.append(req.arena, .{
                .id = try req.arena.dupe(u8, id.str()),
                .archetype = @tagName(e.archetype),
                .level = e.levelFor(p.level),
                .elite = e.elite,
                .tutorial = false,
                .lat = e.lat,
                .lon = e.lon,
                .expires_at = e.expires_at,
            });
        }
        // After dark Humans meet one more in a quarter of the cells' worth of spawns.
        if (spawns.enemy(req.ctx.seed, cell, window, spawns.night_extra_idx)) |e| {
            if (!e.presentFor(p.fac(), req.now)) continue;
            if (geo.haversineM(pos.lat, pos.lon, e.lat, e.lon) > view_radius_m) continue;
            if (!e.visibleTo(p.level)) continue;
            const id = e.id();
            if (try isDone(req, p.id, id.str())) continue;
            try out.append(req.arena, .{
                .id = try req.arena.dupe(u8, id.str()),
                .archetype = @tagName(e.archetype),
                .level = e.levelFor(p.level),
                .elite = e.elite,
                .tutorial = false,
                .lat = e.lat,
                .lon = e.lon,
                .expires_at = e.expires_at,
            });
        }
    }
    if (try tutorialAnchor(req, p, pos)) |t| {
        var tid_buf: [24]u8 = undefined;
        try out.append(req.arena, .{
            .id = try req.arena.dupe(u8, spawns.tutorialId(&tid_buf, p.id)),
            .archetype = @tagName(tutorial_archetype),
            .level = p.level,
            .elite = false,
            .tutorial = true,
            .lat = t.lat,
            .lon = t.lon,
            .expires_at = t.expires_at,
        });
    }
}

/// First Blood: a gentle Shambler for a player with no wins, 25 to 35 m away. It stays where it
/// was put until the player walks more than 150 m from it (or it times out), then it is placed
/// near them again. Only /api/location moves it.
const tutorial_archetype: data.Archetype = .shambler;
const tutorial_live_ms: i64 = 30 * 60 * 1000;

fn tutorialAnchor(req: *Req, p: *const Player, pos: live.Pos) HandlerError!?live.Tutorial {
    if (p.wins != 0) return null;
    const ctx = req.ctx;
    var gen: u32 = 0;
    if (ctx.live.tutorials.get(p.id)) |t| {
        if (t.expires_at > req.now and geo.haversineM(pos.lat, pos.lon, t.lat, t.lon) <= spawns.tutorial_reanchor_m) return t;
        gen = t.gen +% 1;
    }
    const pt = spawns.tutorialPoint(ctx.seed, p.id, gen, .{ .lat = pos.lat, .lon = pos.lon });
    const t = live.Tutorial{ .lat = pt.lat, .lon = pt.lon, .gen = gen, .expires_at = req.now + tutorial_live_ms };
    try ctx.live.tutorials.put(ctx.live.gpa, p.id, t);
    return t;
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

/// The stance a request asked for; careful when it does not say.
pub fn requestStance(req: *Req, text: ?[]const u8) HandlerError!data.Stance {
    const t = text orelse return stance_rules.default;
    return stance_rules.parse(t) orelse req.fail(400, "bad_request", "Stance must be \"aggressive\", \"careful\" or \"evasive\".");
}

pub fn engage(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { id: []const u8, stance: ?[]const u8 = null });
    const stance = try requestStance(req, body.stance);
    var p = (try model.load(req, req.pid)).?;
    const pos = try requireReady(req, &p);
    if (std.mem.startsWith(u8, body.id, "x.")) return engageEcho(req, jw, &p, pos, body.id, stance);
    return engageEnemy(req, jw, &p, pos, body.id, stance);
}

/// POST /api/stance: the default stance Contact fights use.
pub fn setStance(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { stance: []const u8 });
    const stance = try requestStance(req, body.stance);
    var p = (try model.load(req, req.pid)).?;
    p.stance = stance;
    try model.save(req, &p);
    try jw.write(.{ .me = try views.meView(req, &p) });
}

fn markDone(req: *Req, pid: i64, sid: []const u8, expires_at: i64) HandlerError!void {
    try req.ctx.db.run("INSERT OR IGNORE INTO done(player_id, sid, expires_at) VALUES(?,?,?)", .{ pid, sid, expires_at });
}

/// What a PvE engage resolved to: a world enemy or the player's First Blood enemy.
const Target = struct {
    archetype: data.Archetype,
    level: u32,
    elite: bool,
    tutorial: bool,
    lat: f64,
    lon: f64,
    expires_at: i64,
    /// Multiplier on the enemy's HP, ATK and DEF.
    mult: f32,
};

fn resolveTarget(req: *Req, p: *const Player, id: []const u8, night: bool) HandlerError!Target {
    if (std.mem.startsWith(u8, id, "t.")) {
        var buf: [24]u8 = undefined;
        const t = req.ctx.live.tutorials.get(p.id);
        if (p.wins != 0 or t == null or t.?.expires_at <= req.now or !std.mem.eql(u8, id, spawns.tutorialId(&buf, p.id))) {
            return req.fail(404, "not_found", "That enemy is gone.");
        }
        return .{ .archetype = tutorial_archetype, .level = p.level, .elite = false, .tutorial = true, .lat = t.?.lat, .lon = t.?.lon, .expires_at = t.?.expires_at, .mult = stats.tutorial_factor };
    }
    const en = spawns.resolveEnemy(req.ctx.seed, id, req.now) orelse return req.fail(404, "not_found", "That enemy is gone.");
    if (!en.visibleTo(p.level) or !en.presentFor(p.fac(), req.now)) return req.fail(404, "not_found", "That enemy is gone.");
    // After dark the enemies Humans face are 10% tougher.
    const mult = stats.graceFactor(p.level) * daynight.enemyMult(p.fac(), night);
    return .{ .archetype = en.archetype, .level = en.levelFor(p.level), .elite = en.elite, .tutorial = false, .lat = en.lat, .lon = en.lon, .expires_at = en.expires_at, .mult = mult };
}

fn engageEnemy(req: *Req, jw: *Stringify, p: *Player, pos: live.Pos, id: []const u8, stance: data.Stance) HandlerError!void {
    const night = daynight.isNight(req.now, pos.lon);
    const en = try resolveTarget(req, p, id, night);
    if (!withinReach(pos, en.lat, en.lon)) return req.fail(409, "too_far", "Get closer to engage.");
    if (!en.tutorial and try isDone(req, p.id, id)) return req.fail(409, "already_defeated", "You already defeated that one.");

    const level = en.level;
    const a = try fight.selfSideWith(req, p, stance, en.archetype);
    const b = try fight.enemySide(req.arena, p.fac(), en.archetype, level, en.elite, false, en.mult);
    const o = try fight.run(req, a, b, fight.seedFor(req, p.id, game.rng.hashBytes(1, id)));
    const row = data.archetype(en.archetype);

    var acc = rewards.Acc{};
    // Risk and reward: Humans earn more PvE XP by night, Zombies by day.
    const base_xp = progression.pveWinXp(level, if (en.elite) .elite else .normal, row.reward_mult);
    const win_xp: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(base_xp)) * daynight.pveXpMult(p.fac(), night)));
    p.bestiary[@intFromEnum(en.archetype)] +|= 1;
    const district = try districtOf(req.arena, en.lat, en.lon);
    if (o.won()) {
        acc.xp = win_xp;
        var lrng = game.rng.Rng.init(game.rng.hash(o.seed, .{"loot"}));
        try acc.addDrop(req, loot.rollPve(&lrng, .{ .player_level = p.level, .enemy_level = level, .archetype = en.archetype, .loot_mult = rewards.lootMult(p, req.now) }));
        // First Blood always leaves something worth wearing.
        if (en.tutorial) try acc.items.append(req.arena, loot.rollItem(&lrng, .{ .level = p.level, .min_rarity = .uncommon }));
        // ...and the first note of the story; otherwise a small chance of one.
        if (en.tutorial) {
            try acc.addNote(req, game.notes.indexOf(game.notes.first_blood_id).?);
        } else try acc.rollNote(req, p, if (en.elite) .elite else .pve, null, o.seed);
        acc.war_points = game.war.points(if (en.elite) .pve_elite else .pve_win);
        p.wins += 1;
        if (en.tutorial) {
            _ = req.ctx.live.tutorials.remove(p.id);
        } else try markDone(req, p.id, id, en.expires_at);
    } else {
        acc.xp = progression.pveLossXp(win_xp);
        p.losses += 1;
    }
    rewards.settleHp(p, fight.hpAfter(a, o), req.now);
    const rw = try rewards.apply(req, p, &acc, district);
    if (o.won()) try missions.event(req, p, .{ .kind = .pve_win, .archetype = en.archetype, .elite = en.elite });

    const me = try views.meFresh(req, p.id);
    try jw.write(try fight.battleView(req, .pve, a, b, o, rw, me));
}

fn engageEcho(req: *Req, jw: *Stringify, p: *Player, pos: live.Pos, id: []const u8, stance: data.Stance) HandlerError!void {
    const ctx = req.ctx;
    const window = echo_mod.windowOf(req.now);
    const e = ctx.live.echoFor(p.id, window) orelse return req.fail(404, "not_found", "That echo has faded.");
    var expect = e.id();
    if (e.none or !std.mem.eql(u8, std.mem.sliceTo(&expect, 0), id) or e.expires_at <= req.now) {
        return req.fail(404, "not_found", "That echo has faded.");
    }
    if (!withinReach(pos, e.lat, e.lon)) return req.fail(409, "too_far", "Get closer to engage.");
    if (try isDone(req, p.id, id)) return req.fail(409, "already_defeated", "You already faced that echo.");

    const a = try fight.selfSideWith(req, p, stance, null);
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
    rewards.settleHp(p, fight.hpAfter(a, o), req.now);
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

    if (std.mem.startsWith(u8, id, "l.")) return openLandmark(req, jw, &p, pos, id);

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
    try acc.rollNote(req, &p, if (airdrop) .airdrop else .cache, null, lrng.next());
    p.caches += 1;
    const rw = try rewards.apply(req, &p, &acc, try districtOf(req.arena, lat, lon));
    try missions.event(req, &p, .{ .kind = .cache_open });
    try jw.write(.{ .loot = rw, .me = try views.meFresh(req, p.id) });
}

/// A landmark cache: a real place a player's map reported, once per player per 4-hour window,
/// at most six per half hour.
fn openLandmark(req: *Req, jw: *Stringify, p: *Player, pos: live.Pos, id: []const u8) HandlerError!void {
    const ctx = req.ctx;
    const parsed = landmarks.resolveId(id, req.now) orelse return req.fail(404, "not_found", "That is gone.");
    const place = ctx.live.findPlace(parsed.key, pos.lat, pos.lon, req.now) orelse return req.fail(404, "not_found", "That is gone.");
    if (!withinReach(pos, place.place.lat, place.place.lon)) return req.fail(409, "too_far", "Get closer to open it.");
    if (try isDone(req, p.id, id)) return req.fail(409, "already_opened", "You already searched here. It restocks later.");
    const opens = ctx.live.landmark_opens.get(p.id) orelse landmarks.Opens{};
    if (opens.blockedUntil(req.now)) |until| {
        const minutes = @divFloor(until - req.now + 59_999, 60_000);
        const msg = try std.fmt.allocPrint(req.arena, "You have searched a lot of places lately. Try again in {d} min.", .{minutes});
        return req.fail(409, "landmark_limit", msg);
    }

    try markDone(req, p.id, id, landmarks.nextWindowAt(req.now));
    var lrng = game.rng.Rng.init(game.rng.hash(ctx.seed, .{ "landmark", p.id, id, req.now }));
    var acc = rewards.Acc{ .xp = progression.cacheXp(p.level), .war_points = game.war.points(.cache) };
    try acc.addDrop(req, loot.rollLandmark(&lrng, p.level, rewards.lootMult(p, req.now), data.placeKind(place.place.kind)));
    try acc.rollNote(req, p, .landmark, place.place.kind, lrng.next());
    p.caches += 1;
    const rw = try rewards.apply(req, p, &acc, try districtOf(req.arena, place.place.lat, place.place.lon));
    try missions.event(req, p, .{ .kind = .cache_open });
    // Only a landmark that paid out counts against the limit.
    var o = opens;
    o.record(req.now);
    try ctx.live.landmark_opens.put(ctx.live.gpa, p.id, o);
    try jw.write(.{ .loot = rw, .me = try views.meFresh(req, p.id) });
}
