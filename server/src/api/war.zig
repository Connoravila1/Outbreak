//! The war screen, leaderboards and the event feed.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("../ctx.zig");
const events = @import("../events.zig");
const warstate = @import("../warstate.zig");
const model = @import("../model.zig");
const ach_db = @import("../achievements.zig");

const data = game.data;
const progression = game.progression;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Stringify = std.json.Stringify;

const TopEntry = struct { callsign: []const u8, callsign_color: ?[]const u8, level: u8, title: []const u8, points: u32 };
const DistrictBar = struct { id: []const u8, human: u32, zombie: u32 };

fn factionTotals(req: *Req, district: ?[]const u8) HandlerError![2]u32 {
    var out = [2]u32{ 0, 0 };
    var st = if (district) |d|
        try req.ctx.db.query("SELECT faction, SUM(points) FROM war_district WHERE week = ? AND district = ? GROUP BY faction", .{ warstate.week(req.now), d })
    else
        try req.ctx.db.query("SELECT faction, SUM(points) FROM war_district WHERE week = ? GROUP BY faction", .{warstate.week(req.now)});
    defer st.finalize();
    while (try st.step()) {
        const f: usize = @intCast(st.int(0));
        if (f < 2) out[f] = @intCast(st.int(1));
    }
    return out;
}

pub fn war(req: *Req, jw: *Stringify) HandlerError!void {
    const p = (try model.load(req, req.pid)).?;
    const week = warstate.week(req.now);
    const global = try factionTotals(req, null);

    var district: ?DistrictBar = null;
    if (req.ctx.live.position(p.id, req.now)) |pos| {
        const id = try req.arena.dupe(u8, game.war.districtId(pos.lat, pos.lon).str());
        const t = try factionTotals(req, id);
        district = .{ .id = id, .human = t[0], .zombie = t[1] };
    }

    var top: std.ArrayList(TopEntry) = .empty;
    {
        var st = try req.ctx.db.query(
            \\SELECT p.callsign, p.level, SUM(w.points) AS pts, p.callsign_color FROM war_player w JOIN players p ON p.id = w.player_id
            \\WHERE w.week = ? AND p.faction = ? GROUP BY w.player_id ORDER BY pts DESC, p.id LIMIT 10
        , .{ week, p.fac() });
        defer st.finalize();
        while (try st.step()) {
            const level: u8 = @intCast(st.int(1));
            try top.append(req.arena, .{ .callsign = try st.dupe(req.arena, 0), .callsign_color = try ach_db.colorOf(req, &st, 3), .level = level, .title = progression.title(p.fac(), level), .points = @intCast(st.int(2)) });
        }
    }
    try jw.write(.{
        .week = week,
        .ends_at = game.war.weekEnd(req.now),
        .global = .{ .human = global[0], .zombie = global[1] },
        .district = district,
        .top = top.items,
        .my_points = try warstate.weekPoints(req, p.id),
    });
}

const BoardEntry = struct { rank: u32, callsign: []const u8, callsign_color: ?[]const u8, level: u8, title: []const u8, faction: data.Faction, value: u32, clan_tag: ?[]const u8 };

pub fn leaderboard(req: *Req, jw: *Stringify) HandlerError!void {
    const board = (try req.param("board")) orelse "weekly";
    const weekly = std.mem.eql(u8, board, "weekly");
    const contacts = std.mem.eql(u8, board, "contacts");
    if (!weekly and !contacts and !std.mem.eql(u8, board, "level")) return req.fail(400, "bad_request", "Board must be \"weekly\", \"contacts\" or \"level\".");
    var st = if (contacts)
        try req.ctx.db.query(
            \\SELECT p.callsign, p.level, p.faction, w.wins AS v, c.tag, p.callsign_color FROM contact_week w
            \\JOIN players p ON p.id = w.player_id LEFT JOIN clans c ON c.id = p.clan_id
            \\WHERE w.week = ? AND w.wins > 0 AND p.faction IS NOT NULL ORDER BY v DESC, p.id LIMIT 50
        , .{warstate.week(req.now)})
    else if (weekly)
        try req.ctx.db.query(
            \\SELECT p.callsign, p.level, p.faction, SUM(w.points) AS v, c.tag, p.callsign_color FROM war_player w
            \\JOIN players p ON p.id = w.player_id LEFT JOIN clans c ON c.id = p.clan_id
            \\WHERE w.week = ? AND p.faction IS NOT NULL GROUP BY w.player_id ORDER BY v DESC, p.id LIMIT 50
        , .{warstate.week(req.now)})
    else
        try req.ctx.db.query(
            \\SELECT p.callsign, p.level, p.faction, p.level AS v, c.tag, p.callsign_color FROM players p
            \\LEFT JOIN clans c ON c.id = p.clan_id WHERE p.faction IS NOT NULL
            \\ORDER BY p.level DESC, p.xp DESC, p.id LIMIT 50
        , .{});
    defer st.finalize();
    var list: std.ArrayList(BoardEntry) = .empty;
    while (try st.step()) {
        const level: u8 = @intCast(st.int(1));
        const f: data.Faction = @enumFromInt(st.int(2));
        try list.append(req.arena, .{
            .rank = @intCast(list.items.len + 1),
            .callsign = try st.dupe(req.arena, 0),
            .callsign_color = try ach_db.colorOf(req, &st, 5),
            .level = level,
            .title = progression.title(f, level),
            .faction = f,
            .value = @intCast(st.int(3)),
            .clan_tag = if (st.optText(4)) |t| try req.arena.dupe(u8, t) else null,
        });
    }
    try jw.write(.{ .entries = list.items });
}

pub fn feed(req: *Req, jw: *Stringify) HandlerError!void {
    try jw.write(.{ .events = try events.recent(req, req.pid) });
}
