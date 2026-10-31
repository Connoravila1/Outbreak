//! Player reports: a callsign, a clan, or a clan chat message. Reports are read by the server's
//! owner with `outbreak-server admin reports`; nothing here reaches other players.

const std = @import("std");
const ctx_mod = @import("../ctx.zig");

const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Stringify = std.json.Stringify;

/// Reports one player may send per hour, over all targets.
pub const hourly_limit = 5;
pub const note_max_len = 140;

const reasons = [_][]const u8{ "name", "harassment", "cheating", "other" };

fn validReason(r: []const u8) bool {
    for (reasons) |x| {
        if (std.mem.eql(u8, x, r)) return true;
    }
    return false;
}

/// What a report is about, resolved from the request.
const Target = struct {
    kind: []const u8,
    key: []const u8,
    player_id: ?i64 = null,
    clan_id: ?i64 = null,
    message_id: ?i64 = null,
    label: []const u8,
    excerpt: []const u8 = "",
};

fn resolvePlayer(req: *Req, callsign: []const u8) HandlerError!Target {
    const lc = try std.ascii.allocLowerString(req.arena, std.mem.trim(u8, callsign, " "));
    var st = try req.ctx.db.query("SELECT id, callsign FROM players WHERE callsign_lc = ? AND callsign <> ''", .{lc});
    defer st.finalize();
    if (!try st.step()) return req.fail(404, "not_found", "No such player.");
    const id = st.int(0);
    if (id == req.pid) return req.fail(400, "bad_request", "You cannot report yourself.");
    return .{
        .kind = "player",
        .key = try std.fmt.allocPrint(req.arena, "p:{d}", .{id}),
        .player_id = id,
        .label = try st.dupe(req.arena, 1),
    };
}

fn resolveClan(req: *Req, text: []const u8) HandlerError!Target {
    const id = std.fmt.parseInt(i64, text, 10) catch return req.fail(404, "not_found", "No such clan.");
    var st = try req.ctx.db.query("SELECT tag, name FROM clans WHERE id = ?", .{id});
    defer st.finalize();
    if (!try st.step()) return req.fail(404, "not_found", "No such clan.");
    return .{
        .kind = "clan",
        .key = try std.fmt.allocPrint(req.arena, "c:{d}", .{id}),
        .clan_id = id,
        .label = try std.fmt.allocPrint(req.arena, "[{s}] {s}", .{ st.text(0), st.text(1) }),
    };
}

/// A message can be reported only by someone in the clan that can read it.
fn resolveMessage(req: *Req, text: []const u8) HandlerError!Target {
    const id = std.fmt.parseInt(i64, text, 10) catch return req.fail(404, "not_found", "No such message.");
    var st = try req.ctx.db.query(
        \\SELECT m.player_id, COALESCE(p.callsign, '[deleted]'), m.text FROM clan_chat m
        \\LEFT JOIN players p ON p.id = m.player_id
        \\WHERE m.id = ? AND m.clan_id = (SELECT clan_id FROM players WHERE id = ?)
    , .{ id, req.pid });
    defer st.finalize();
    if (!try st.step()) return req.fail(404, "not_found", "No such message.");
    const author = st.optInt(0);
    if (author != null and author.? == req.pid) return req.fail(400, "bad_request", "You cannot report yourself.");
    return .{
        .kind = "message",
        .key = try std.fmt.allocPrint(req.arena, "m:{d}", .{id}),
        .player_id = author,
        .message_id = id,
        .label = try st.dupe(req.arena, 1),
        .excerpt = try st.dupe(req.arena, 2),
    };
}

/// POST /api/report {kind: "player" | "clan" | "message", target, reason, note?}
pub fn report(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { kind: []const u8, target: []const u8, reason: []const u8, note: ?[]const u8 = null });
    if (!validReason(body.reason)) return req.fail(400, "bad_request", "Choose a reason: name, harassment, cheating or other.");
    const note = std.mem.trim(u8, body.note orelse "", " \t\r\n");
    if (!std.unicode.utf8ValidateSlice(note)) return req.fail(400, "bad_request", "The note must be text.");
    if (note.len > note_max_len) return req.fail(400, "bad_request", "Keep the note under 140 characters.");

    const t: Target = if (std.mem.eql(u8, body.kind, "player"))
        try resolvePlayer(req, body.target)
    else if (std.mem.eql(u8, body.kind, "clan"))
        try resolveClan(req, body.target)
    else if (std.mem.eql(u8, body.kind, "message"))
        try resolveMessage(req, body.target)
    else
        return req.fail(400, "bad_request", "Report a player, a clan or a message.");

    const db = &req.ctx.db;
    if ((try db.scalar("SELECT id FROM reports WHERE reporter_id = ? AND target_key = ? AND status = 'open'", .{ req.pid, t.key })) != null) {
        return req.fail(409, "already_reported", "You already reported this. It is waiting to be reviewed.");
    }
    const recent = (try db.scalar("SELECT COUNT(*) FROM reports WHERE reporter_id = ? AND created_at > ?", .{ req.pid, req.now - std.time.ms_per_hour })) orelse 0;
    if (recent >= hourly_limit) return req.fail(429, "report_limit", "You have sent several reports already. Try again in an hour.");

    try db.run(
        \\INSERT INTO reports(reporter_id, kind, target_key, target_player_id, target_clan_id, message_id, label, excerpt, reason, note, created_at)
        \\VALUES(?,?,?,?,?,?,?,?,?,?,?)
    , .{ req.pid, t.kind, t.key, t.player_id, t.clan_id, t.message_id, t.label, t.excerpt, body.reason, note, req.now });
    try jw.write(.{ .ok = true });
}
