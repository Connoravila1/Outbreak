//! Clans, clan chat, strongholds and raid attacks.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("../ctx.zig");
const model = @import("../model.zig");
const views = @import("../views.zig");
const fight = @import("../fight.zig");
const rewards = @import("../rewards.zig");
const warstate = @import("../warstate.zig");
const snapshot = @import("../snapshot.zig");
const account = @import("account.zig");
const names = @import("../names.zig");
const world = @import("world.zig");
const raids = @import("../raids.zig");
const ach_db = @import("../achievements.zig");

const data = game.data;
const geo = game.geo;
const progression = game.progression;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Player = model.Player;
const Stringify = std.json.Stringify;

pub const clan_min_level = 10;
pub const stronghold_min_level = 15;
pub const raid_min_level = 20;
pub const clan_cost = 500;
pub const clan_max_members = 50;
pub const chat_max_len = 200;
pub const chat_gap_ms: i64 = 3000;
pub const chat_history = 50;

fn loadP(req: *Req) HandlerError!Player {
    return (try model.load(req, req.pid)).?;
}

// --- Clans -------------------------------------------------------------------------------------------------

const ClanSummary = struct { id: []const u8, name: []const u8, tag: []const u8, members: u32, level_sum: u32, faction: data.Faction };

pub fn clans(req: *Req, jw: *Stringify) HandlerError!void {
    const p = try loadP(req);
    const q = (try req.param("q")) orelse "";
    const like = try std.fmt.allocPrint(req.arena, "%{s}%", .{std.mem.trim(u8, q, " ")});
    var st = try req.ctx.db.query(
        \\SELECT c.id, c.name, c.tag, c.faction, COUNT(m.id), COALESCE(SUM(m.level), 0)
        \\FROM clans c LEFT JOIN players m ON m.clan_id = c.id
        \\WHERE c.faction = ? AND (c.name LIKE ? OR c.tag LIKE ?)
        \\GROUP BY c.id ORDER BY COUNT(m.id) DESC, c.id LIMIT 30
    , .{ p.fac(), like, like });
    defer st.finalize();
    var list: std.ArrayList(ClanSummary) = .empty;
    while (try st.step()) {
        try list.append(req.arena, .{
            .id = try std.fmt.allocPrint(req.arena, "{d}", .{st.int(0)}),
            .name = try st.dupe(req.arena, 1),
            .tag = try st.dupe(req.arena, 2),
            .faction = @enumFromInt(st.int(3)),
            .members = @intCast(st.int(4)),
            .level_sum = @intCast(st.int(5)),
        });
    }
    try jw.write(.{ .clans = list.items });
}

const MemberView = struct { callsign: []const u8, callsign_color: ?[]const u8, level: u8, title: []const u8, role: []const u8, weekly_points: u32 };
const ClanPerks = struct { xp_bonus: f32, strongholds: u32 };
const ClanDetail = struct {
    id: []const u8,
    name: []const u8,
    tag: []const u8,
    code: []const u8,
    members: []const MemberView,
    strongholds: u32,
    perks: ClanPerks,
};

fn clanDetail(req: *Req, clan_id: i64) HandlerError!ClanDetail {
    const a = req.arena;
    const db = &req.ctx.db;
    var d: ClanDetail = undefined;
    {
        var st = try db.query("SELECT name, tag, code FROM clans WHERE id = ?", .{clan_id});
        defer st.finalize();
        if (!try st.step()) return error.Sqlite;
        d.name = try st.dupe(a, 0);
        d.tag = try st.dupe(a, 1);
        d.code = try st.dupe(a, 2);
    }
    d.id = try std.fmt.allocPrint(a, "{d}", .{clan_id});
    var members: std.ArrayList(MemberView) = .empty;
    {
        var st = try db.query(
            \\SELECT p.callsign, p.level, p.faction, COALESCE(p.clan_role, 'member'), p.callsign_color,
            \\  COALESCE((SELECT SUM(points) FROM war_player w WHERE w.player_id = p.id AND w.week = ?), 0)
            \\FROM players p WHERE p.clan_id = ?
            \\ORDER BY CASE p.clan_role WHEN 'leader' THEN 0 WHEN 'officer' THEN 1 ELSE 2 END, p.level DESC, p.id
        , .{ warstate.week(req.now), clan_id });
        defer st.finalize();
        while (try st.step()) {
            const level: u8 = @intCast(st.int(1));
            try members.append(a, .{
                .callsign = try st.dupe(a, 0),
                .callsign_color = try ach_db.colorOf(req, &st, 4),
                .level = level,
                .title = progression.title(@enumFromInt(st.int(2)), level),
                .role = try st.dupe(a, 3),
                .weekly_points = @intCast(st.int(5)),
            });
        }
    }
    d.members = members.items;
    d.strongholds = @intCast(try db.scalar("SELECT COUNT(*) FROM strongholds WHERE clan_id = ? AND week = ?", .{ clan_id, warstate.week(req.now) }) orelse 0);
    d.perks = .{ .xp_bonus = try warstate.adjacencyBonus(req, clan_id), .strongholds = d.strongholds };
    return d;
}

fn validClanText(s: []const u8, min: usize, max: usize, allow_space: bool) bool {
    if (s.len < min or s.len > max) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and !(allow_space and c == ' ')) return false;
    }
    return true;
}

pub fn createClan(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { name: []const u8, tag: []const u8 });
    var p = try loadP(req);
    if (p.level < clan_min_level) return req.fail(409, "locked", "Clans unlock at level 10.");
    if (p.clan_id != null) return req.fail(409, "already_in_clan", "Leave your clan first.");
    const name = std.mem.trim(u8, body.name, " ");
    const tag = std.mem.trim(u8, body.tag, " ");
    if (!validClanText(name, 3, 24, true)) return req.fail(400, "bad_request", "Clan names are 3 to 24 letters, digits, spaces, _ or -.");
    if (!validClanText(tag, 2, 4, false)) return req.fail(400, "bad_request", "Clan tags are 2 to 4 letters or digits.");
    if (!account.callsignAllowed(name) or !account.callsignAllowed(tag)) return req.fail(400, "name_not_allowed", names.rejection);
    if (p.salvage < clan_cost) return req.fail(409, "not_enough_salvage", "Founding a clan costs 500 salvage.");

    const db = &req.ctx.db;
    const name_lc = try std.ascii.allocLowerString(req.arena, name);
    const tag_up = try std.ascii.allocUpperString(req.arena, tag);
    const tag_lc = try std.ascii.allocLowerString(req.arena, tag);
    if ((try db.scalar("SELECT id FROM clans WHERE name_lc = ?", .{name_lc})) != null) return req.fail(409, "name_taken", "That clan name is taken.");
    if ((try db.scalar("SELECT id FROM clans WHERE tag_lc = ?", .{tag_lc})) != null) return req.fail(409, "tag_taken", "That tag is taken.");

    // Invite code: 8 characters, retried on the (unlikely) collision.
    var code: [8]u8 = undefined;
    while (true) {
        var raw: [8]u8 = undefined;
        req.ctx.randomBytes(&raw);
        for (raw, 0..) |b, i| code[i] = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"[b & 31];
        if ((try db.scalar("SELECT id FROM clans WHERE code = ?", .{@as([]const u8, &code)})) == null) break;
    }
    try db.run(
        "INSERT INTO clans(name, name_lc, tag, tag_lc, code, faction, created_at) VALUES(?,?,?,?,?,?,?)",
        .{ name, name_lc, tag_up, tag_lc, @as([]const u8, &code), p.fac(), req.now },
    );
    const clan_id = db.lastInsertId();
    p.salvage -= clan_cost;
    p.clan_id = clan_id;
    p.clan_role = "leader";
    try model.save(req, &p);
    try jw.write(.{ .clan = try clanDetail(req, clan_id), .me = try views.meFresh(req, p.id) });
}

pub fn joinClan(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { id: ?[]const u8 = null, code: ?[]const u8 = null });
    var p = try loadP(req);
    if (p.level < clan_min_level) return req.fail(409, "locked", "Clans unlock at level 10.");
    if (p.clan_id != null) return req.fail(409, "already_in_clan", "Leave your clan first.");
    const db = &req.ctx.db;

    var found: ?i64 = null;
    if (body.id) |id| {
        const n = std.fmt.parseInt(i64, id, 10) catch return req.fail(404, "not_found", "No such clan.");
        found = try db.scalar("SELECT id FROM clans WHERE id = ?", .{n});
    } else if (body.code) |code| {
        const up = try std.ascii.allocUpperString(req.arena, std.mem.trim(u8, code, " "));
        found = try db.scalar("SELECT id FROM clans WHERE code = ?", .{up});
    } else return req.fail(400, "bad_request", "Provide a clan id or invite code.");
    const clan_id = found orelse return req.fail(404, "not_found", "No such clan.");

    if ((try db.scalar("SELECT faction FROM clans WHERE id = ?", .{clan_id})).? != @intFromEnum(p.fac())) {
        return req.fail(409, "wrong_faction", "Clans are single-faction.");
    }
    if ((try db.scalar("SELECT COUNT(*) FROM players WHERE clan_id = ?", .{clan_id})).? >= clan_max_members) {
        return req.fail(409, "clan_full", "That clan is full.");
    }
    p.clan_id = clan_id;
    p.clan_role = "member";
    try model.save(req, &p);
    try jw.write(.{ .clan = try clanDetail(req, clan_id), .me = try views.meFresh(req, p.id) });
}

pub fn leaveClan(req: *Req, jw: *Stringify) HandlerError!void {
    var p = try loadP(req);
    const clan_id = p.clan_id orelse return req.fail(409, "no_clan", "You are not in a clan.");
    const was_leader = if (p.clan_role) |r| std.mem.eql(u8, r, "leader") else false;
    p.clan_id = null;
    p.clan_role = null;
    try model.save(req, &p);
    try afterMemberLeft(req, clan_id, was_leader);
    try jw.write(.{ .me = try views.meFresh(req, p.id) });
}

/// Housekeeping once a member (already detached from the clan) is gone: the last one out closes
/// the clan, and a departed leader hands over to the most senior officer, else the highest level.
pub fn afterMemberLeft(req: *Req, clan_id: i64, was_leader: bool) HandlerError!void {
    const db = &req.ctx.db;
    if ((try db.scalar("SELECT COUNT(*) FROM players WHERE clan_id = ?", .{clan_id})).? == 0) {
        // The last member left: the clan, its chat and its strongholds go with it.
        try db.run("DELETE FROM clans WHERE id = ?", .{clan_id});
    } else if (was_leader) {
        try db.run(
            \\UPDATE players SET clan_role = 'leader' WHERE id = (
            \\  SELECT id FROM players WHERE clan_id = ?
            \\  ORDER BY CASE clan_role WHEN 'officer' THEN 0 ELSE 1 END, level DESC, id LIMIT 1)
        , .{clan_id});
    }
}

pub fn clan(req: *Req, jw: *Stringify) HandlerError!void {
    const p = try loadP(req);
    const clan_id = p.clan_id orelse return req.fail(409, "no_clan", "You are not in a clan.");
    try jw.write(.{ .clan = try clanDetail(req, clan_id) });
}

const ChatMessage = struct { id: []const u8, callsign: []const u8, callsign_color: ?[]const u8, text: []const u8, at: i64 };

fn chatMessages(req: *Req, clan_id: i64) HandlerError![]const ChatMessage {
    var st = try req.ctx.db.query(
        \\SELECT * FROM (
        \\  SELECT m.id, COALESCE(p.callsign, '[deleted]'), m.text, m.at, COALESCE(p.callsign_color, '') FROM clan_chat m LEFT JOIN players p ON p.id = m.player_id
        \\  WHERE m.clan_id = ? ORDER BY m.id DESC LIMIT ?) ORDER BY id
    , .{ clan_id, chat_history });
    defer st.finalize();
    var list: std.ArrayList(ChatMessage) = .empty;
    while (try st.step()) {
        try list.append(req.arena, .{
            .id = try std.fmt.allocPrint(req.arena, "{d}", .{st.int(0)}),
            .callsign = try st.dupe(req.arena, 1),
            .callsign_color = try ach_db.colorOf(req, &st, 4),
            .text = try st.dupe(req.arena, 2),
            .at = st.int(3),
        });
    }
    return list.items;
}

pub fn chat(req: *Req, jw: *Stringify) HandlerError!void {
    const p = try loadP(req);
    const clan_id = p.clan_id orelse return req.fail(409, "no_clan", "You are not in a clan.");
    if (req.method == .post) {
        const body = try req.json(struct { text: []const u8 });
        const text = std.mem.trim(u8, body.text, " \t\r\n");
        if (text.len == 0 or text.len > chat_max_len) return req.fail(400, "bad_request", "Messages are 1 to 200 characters.");
        if (!std.unicode.utf8ValidateSlice(text)) return req.fail(400, "bad_request", "Messages must be text.");
        const live = &req.ctx.live;
        if (live.chat_last.get(p.id)) |last| {
            if (req.now - last < chat_gap_ms) return req.fail(429, "slow_down", "One message every 3 seconds.");
        }
        try live.chat_last.put(live.gpa, p.id, req.now);
        try req.ctx.db.run("INSERT INTO clan_chat(clan_id, player_id, text, at) VALUES(?,?,?,?)", .{ clan_id, p.id, text, req.now });
    }
    try jw.write(.{ .messages = try chatMessages(req, clan_id) });
}

// --- Strongholds ---------------------------------------------------------------------------------------------

pub fn claimStronghold(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { id: []const u8, stance: ?[]const u8 = null });
    const stance = try world.requestStance(req, body.stance);
    var p = try loadP(req);
    try world.refuseInTransit(req, p.id);
    if (p.level < stronghold_min_level) return req.fail(409, "locked", "Territory unlocks at level 15.");
    const clan_id = p.clan_id orelse return req.fail(409, "no_clan", "Join a clan to claim territory.");
    if (p.downed(req.now)) return req.fail(409, "downed", "You are down. Heal, or wait to get back up.");
    const pos = req.ctx.live.position(p.id, req.now) orelse return req.fail(409, "no_position", "Your position is unknown. Wait for a location update.");
    if (pos.sanctuary) return req.fail(409, "sanctuary", "Nothing can be claimed in a sanctuary.");
    const site = game.spawns.resolveStronghold(req.ctx.seed, body.id) orelse return req.fail(404, "not_found", "No such stronghold.");
    if (!world.withinReach(pos, site.lat, site.lon)) return req.fail(409, "too_far", "Get closer to the stronghold.");

    const db = &req.ctx.db;
    const week = warstate.week(req.now);
    const holder = try db.scalar("SELECT clan_id FROM strongholds WHERE id = ? AND week = ?", .{ body.id, week });
    if (holder != null and holder.? == clan_id) return req.fail(409, "already_held", "Your clan already holds this ground.");
    if (!try model.takeConsumable(req, p.id, .flag)) return req.fail(409, "no_flag", "You need a flag to claim territory.");

    var battles: std.ArrayList(fight.BattleView) = .empty;
    var claimed = true;
    if (holder) |hid| {
        // The holding clan's garrison: Echoes of up to three of its members, fought in sequence.
        var st = try db.query(
            \\SELECT s.level, s.items, s.abilities, s.faction FROM snapshots s
            \\JOIN players p ON p.id = s.player_id WHERE p.clan_id = ? AND p.banned_until <= ? ORDER BY s.level DESC, s.player_id LIMIT 3
        , .{ hid, req.now });
        defer st.finalize();
        while (try st.step()) {
            const foe = snapshot.Build.decode(@enumFromInt(st.int(3)), @intCast(st.int(0)), st.text(1), st.text(2));
            const a = try fight.selfSideWith(req, &p, stance, null);
            const b = try fight.buildSide(req.arena, &foe, .echo, null);
            const o = try fight.run(req, a, b, fight.seedFor(req, p.id, game.rng.hashBytes(3, body.id)));
            rewards.settleHp(&p, fight.hpAfter(a, o), req.now);
            try model.save(req, &p);
            try battles.append(req.arena, try fight.battleView(req, .garrison, a, b, o, .{}, try views.meFresh(req, p.id)));
            if (!o.won()) {
                claimed = false;
                break;
            }
        }
    }
    if (claimed) {
        try db.run(
            "INSERT OR REPLACE INTO strongholds(id, clan_id, week, district, claimed_at, last_hour, last_day) VALUES(?,?,?,?,?,?,?)",
            .{ body.id, clan_id, week, game.war.districtId(site.lat, site.lon).str(), req.now, @divFloor(req.now, std.time.ms_per_hour), game.war.dayIndex(req.now) },
        );
    }
    try jw.write(.{ .battles = battles.items, .claimed = claimed, .me = try views.meFresh(req, p.id) });
}

// --- Raids -----------------------------------------------------------------------------------------------------

pub fn raidAttack(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { id: []const u8, stance: ?[]const u8 = null });
    const stance = try world.requestStance(req, body.stance);
    var p = try loadP(req);
    try world.refuseInTransit(req, p.id);
    if (p.level < raid_min_level) return req.fail(409, "locked", "Raids unlock at level 20.");
    if (p.downed(req.now)) return req.fail(409, "downed", "You are down. Heal, or wait to get back up.");
    const pos = req.ctx.live.position(p.id, req.now) orelse return req.fail(409, "no_position", "Your position is unknown. Wait for a location update.");
    if (pos.sanctuary) return req.fail(409, "sanctuary", "Nothing can be fought in a sanctuary.");

    const raid = (try raids.find(req, body.id)) orelse return req.fail(404, "not_found", "No such raid.");
    if (raid.settled or raid.hp <= 0 or raid.ends_at <= req.now) return req.fail(409, "raid_over", "That raid is over.");
    if (!world.withinReach(pos, raid.lat, raid.lon)) return req.fail(409, "too_far", "Get closer to the boss.");
    const last = try raids.lastAttack(req, raid.id, p.id);
    if (last != 0 and req.now - last < world.raid_attack_gap_ms) return req.fail(409, "cooldown", "You can attack again in an hour.");

    const boss_level: u32 = @min(p.level + 2, data.max_level + 2);
    const a = try fight.selfSideWith(req, &p, stance, null);
    const b = try fight.enemySide(req.arena, p.fac(), .abomination, boss_level, false, true, 1.0);
    const o = try fight.run(req, a, b, fight.seedFor(req, p.id, game.rng.hashBytes(4, body.id)));

    const dealt: i64 = @max(0, b.combatant.hp - o.result.hp_b);
    const share: f32 = @as(f32, @floatFromInt(dealt)) / @as(f32, @floatFromInt(@max(1, b.combatant.stats.hp)));
    const full_xp = progression.pveWinXp(boss_level, .boss, 1.0);
    var acc = rewards.Acc{ .xp = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(full_xp)) * share)))) };
    acc.war_points = game.war.raidPoints(@as(f32, @floatFromInt(dealt)) / @as(f32, @floatFromInt(@max(1, raid.max_hp))));
    if (o.won()) p.wins += 1 else p.losses += 1;
    rewards.settleHp(&p, fight.hpAfter(a, o), req.now);
    try ach_db.bump(req, p.id, .raid_hits, 1);
    const rw = try rewards.apply(req, &p, &acc, raid.district);
    try raids.recordDamage(req, raid.id, p.id, dealt);
    if (try raids.hpLeft(req, raid.id) <= 0) try raids.settle(req, raid.id, true);

    try jw.write(try fight.battleView(req, .raid, a, b, o, rw, try views.meFresh(req, p.id)));
}
