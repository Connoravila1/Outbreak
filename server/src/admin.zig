//! The moderation commands behind `outbreak-server admin ...`. Everything works on an open database
//! handle and writes to a writer, so tests drive it directly. There is no network surface: the
//! commands run on the server's own machine against the same SQLite file (WAL, busy timeout), so
//! they are safe while the server is running.
//!
//! No command prints a position, a fight history or an email address.

const std = @import("std");
const game = @import("game");
const db_mod = @import("db.zig");

const Db = db_mod.Db;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

/// `Failed` means the problem was already printed for the person at the keyboard.
pub const Error = error{ Failed, Sqlite, OutOfMemory, WriteFailed };

pub const usage =
    \\usage: outbreak-server admin [--data DIR] <command>
    \\
    \\  reports                        open reports, grouped by target
    \\  player <callsign>              account summary (no location data)
    \\  rename <callsign>              reset to a generated callsign; they choose a new one on next launch
    \\  clan-rename <tag>              reset a clan to a generated name and tag
    \\  delete-message <id>            remove a clan chat message (ids are shown in `reports`)
    \\  ban <callsign> [--days N] [--reason "text"]
    \\                                 suspend an account (forever unless --days is given)
    \\  unban <callsign>               lift a suspension
    \\  resolve <report-id>            close one report without acting on it
    \\  errors [--since 7d]            crash and error reports from the app, grouped (d days, h hours)
    \\  errors clear                   delete every stored error report
    \\
    \\Acting on a player, clan or message also closes the open reports about it.
    \\The data directory defaults to ./data (or OUTBREAK_DATA); it is the one the server uses.
    \\
;

/// Permanent suspension marker, matching `Req.failBanned`.
const forever = std.math.maxInt(i64);
const default_ban_reason = "Breaking the community rules.";

pub const Ctx = struct {
    arena: Allocator,
    db: *Db,
    now: i64,
    rng: *game.rng.Rng,
    out: *Writer,
};

/// Run one command. `args` starts at the command name. Usage mistakes and "no such player" print a
/// plain sentence to `out` and return error.Failed.
pub fn run(gpa: Allocator, db: *Db, now: i64, rng: *game.rng.Rng, args: []const []const u8, out: *Writer) Error!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const c = Ctx{ .arena = arena_state.allocator(), .db = db, .now = now, .rng = rng, .out = out };
    if (args.len == 0) {
        try out.writeAll(usage);
        return error.Failed;
    }
    const cmd = args[0];
    const rest = args[1..];
    if (eql(cmd, "reports")) return reports(c);
    if (eql(cmd, "player")) return player(c, try one(c, rest, "player <callsign>"));
    if (eql(cmd, "rename")) return rename(c, try one(c, rest, "rename <callsign>"));
    if (eql(cmd, "clan-rename")) return clanRename(c, try one(c, rest, "clan-rename <tag>"));
    if (eql(cmd, "delete-message")) return deleteMessage(c, try one(c, rest, "delete-message <id>"));
    if (eql(cmd, "unban")) return unban(c, try one(c, rest, "unban <callsign>"));
    if (eql(cmd, "resolve")) return resolve(c, try one(c, rest, "resolve <report-id>"));
    if (eql(cmd, "ban")) return ban(c, rest);
    if (eql(cmd, "errors")) return errors(c, rest);
    if (eql(cmd, "help") or eql(cmd, "--help") or eql(cmd, "-h")) return out.writeAll(usage);
    try out.print("Unknown command \"{s}\".\n\n{s}", .{ cmd, usage });
    return error.Failed;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn one(c: Ctx, rest: []const []const u8, what: []const u8) Error![]const u8 {
    if (rest.len != 1) {
        try c.out.print("Usage: outbreak-server admin {s}\n", .{what});
        return error.Failed;
    }
    return rest[0];
}

fn say(c: Ctx, comptime fmt: []const u8, args: anytype) Error!void {
    try c.out.print(fmt ++ "\n", args);
}

fn fail(c: Ctx, comptime fmt: []const u8, args: anytype) Error {
    c.out.print(fmt ++ "\n", args) catch {};
    return error.Failed;
}

// --- Formatting ---------------------------------------------------------------------------------------

/// "2026-10-31 14:05" in UTC.
pub fn stamp(arena: Allocator, ms: i64) Allocator.Error![]const u8 {
    const secs: u64 = @intCast(@max(0, @divFloor(ms, 1000)));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(),
    });
}

/// One line, at most `max` bytes, control characters turned into spaces.
fn clip(arena: Allocator, s: []const u8, max: usize) Allocator.Error![]const u8 {
    const buf = try arena.alloc(u8, @min(s.len, max) + 3);
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < max) : (i += 1) {
        buf[n] = if (s[i] < 32) ' ' else s[i];
        n += 1;
    }
    // Do not end half way through a multi-byte character.
    if (i < s.len) {
        while (n > 0 and buf[n - 1] >= 0x80 and buf[n - 1] < 0xC0) n -= 1;
        if (n > 0 and buf[n - 1] >= 0xC0) n -= 1;
        @memcpy(buf[n .. n + 3], "...");
        n += 3;
    }
    return buf[0..n];
}

fn displayWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

const Rows = std.ArrayList([]const []const u8);

fn table(c: Ctx, headers: []const []const u8, rows: []const []const []const u8) Error!void {
    const widths = try c.arena.alloc(usize, headers.len);
    for (headers, 0..) |h, i| widths[i] = displayWidth(h);
    for (rows) |r| for (r, 0..) |cell, i| {
        widths[i] = @max(widths[i], displayWidth(cell));
    };
    try tableLine(c, headers, widths);
    for (widths, 0..) |w, i| {
        if (i > 0) try c.out.writeAll("  ");
        try c.out.splatByteAll('-', w);
    }
    try c.out.writeAll("\n");
    for (rows) |r| try tableLine(c, r, widths);
}

fn tableLine(c: Ctx, cells: []const []const u8, widths: []const usize) Error!void {
    for (cells, 0..) |cell, i| {
        if (i > 0) try c.out.writeAll("  ");
        try c.out.writeAll(cell);
        if (i + 1 < cells.len) try c.out.splatByteAll(' ', widths[i] - displayWidth(cell));
    }
    try c.out.writeAll("\n");
}

fn rowOf(c: Ctx, items: anytype) Allocator.Error![]const []const u8 {
    const out = try c.arena.alloc([]const u8, items.len);
    inline for (items, 0..) |it, i| out[i] = it;
    return out;
}

// --- Lookups --------------------------------------------------------------------------------------------

const Found = struct { id: i64, name: []const u8 };

fn findPlayer(c: Ctx, callsign: []const u8) Error!Found {
    const lc = try std.ascii.allocLowerString(c.arena, std.mem.trim(u8, callsign, " "));
    var st = try c.db.query("SELECT id, callsign FROM players WHERE callsign_lc = ? AND callsign <> ''", .{lc});
    defer st.finalize();
    if (!try st.step()) return fail(c, "No player with the callsign \"{s}\". Callsigns are not case sensitive; check the spelling.", .{callsign});
    return .{ .id = st.int(0), .name = try st.dupe(c.arena, 1) };
}

/// Close open reports; returns how many.
fn closeReports(c: Ctx, comptime where: []const u8, arg: i64) Error!i64 {
    try c.db.run("UPDATE reports SET status = 'resolved', resolved_at = ? WHERE status = 'open' AND " ++ where, .{ c.now, arg });
    return c.db.changes();
}

fn noteClosed(c: Ctx, n: i64) Error!void {
    if (n > 0) try say(c, "Closed {d} open report{s} about it.", .{ n, if (n == 1) "" else "s" });
}

// --- reports --------------------------------------------------------------------------------------------

fn reports(c: Ctx) Error!void {
    // Summary: one row per target.
    var summary: Rows = .empty;
    var total: i64 = 0;
    {
        var st = try c.db.query(
            \\SELECT kind, label, COUNT(*), MAX(created_at), GROUP_CONCAT(DISTINCT reason), MIN(id)
            \\FROM reports WHERE status = 'open' GROUP BY target_key ORDER BY COUNT(*) DESC, MAX(created_at) DESC
        , .{});
        defer st.finalize();
        while (try st.step()) {
            total += st.int(2);
            const kind = st.text(0);
            const label = try clip(c.arena, st.text(1), 40);
            try summary.append(c.arena, try rowOf(c, .{
                try std.fmt.allocPrint(c.arena, "{s} {s}", .{ kind, label }),
                try std.fmt.allocPrint(c.arena, "{d}", .{st.int(2)}),
                try c.arena.dupe(u8, st.text(4)),
                try stamp(c.arena, st.int(3)),
            }));
        }
    }
    if (summary.items.len == 0) return say(c, "No open reports.", .{});
    try say(c, "{d} open report{s} on {d} target{s}\n", .{ total, if (total == 1) "" else "s", summary.items.len, if (summary.items.len == 1) "" else "s" });
    try table(c, &.{ "TARGET", "REPORTS", "REASONS", "LATEST (UTC)" }, summary.items);

    // Detail: every open report, newest target first as above.
    var detail: Rows = .empty;
    {
        var st = try c.db.query(
            \\SELECT r.id, r.created_at, r.kind, r.label, r.reason, COALESCE(p.callsign, '[deleted]'), r.note, r.excerpt, r.message_id
            \\FROM reports r LEFT JOIN players p ON p.id = r.reporter_id WHERE r.status = 'open'
            \\ORDER BY (SELECT COUNT(*) FROM reports x WHERE x.status = 'open' AND x.target_key = r.target_key) DESC, r.target_key, r.id
        , .{});
        defer st.finalize();
        while (try st.step()) {
            var text: []const u8 = try clip(c.arena, st.text(6), 60);
            if (std.mem.eql(u8, st.text(2), "message")) {
                text = try std.fmt.allocPrint(c.arena, "msg {d}: \"{s}\" {s}", .{ st.int(8), try clip(c.arena, st.text(7), 50), text });
            }
            try detail.append(c.arena, try rowOf(c, .{
                try std.fmt.allocPrint(c.arena, "{d}", .{st.int(0)}),
                try stamp(c.arena, st.int(1)),
                try std.fmt.allocPrint(c.arena, "{s} {s}", .{ st.text(2), try clip(c.arena, st.text(3), 40) }),
                try c.arena.dupe(u8, st.text(4)),
                try c.arena.dupe(u8, st.text(5)),
                text,
            }));
        }
    }
    try say(c, "", .{});
    try table(c, &.{ "ID", "WHEN (UTC)", "TARGET", "REASON", "FROM", "NOTE" }, detail.items);
    try say(c, "\nAct with: ban, rename, clan-rename, delete-message (each closes the reports about it), or `resolve <id>` to dismiss one.", .{});
}

fn resolve(c: Ctx, id_text: []const u8) Error!void {
    const id = std.fmt.parseInt(i64, id_text, 10) catch return fail(c, "\"{s}\" is not a report number. Use the ID column from `reports`.", .{id_text});
    const n = try closeReports(c, "id = ?", id);
    if (n == 0) return fail(c, "No open report with the number {d}.", .{id});
    try say(c, "Report {d} closed.", .{id});
}

// --- player ---------------------------------------------------------------------------------------------

fn player(c: Ctx, callsign: []const u8) Error!void {
    const f = try findPlayer(c, callsign);
    var st = try c.db.query(
        \\SELECT p.faction, p.level, p.created_at, p.last_seen, p.banned_until, p.ban_reason, p.must_rename,
        \\  p.wins, p.losses, p.contacts_won, p.contacts_lost, COALESCE(cl.tag, ''), COALESCE(cl.name, ''), COALESCE(p.clan_role, ''),
        \\  COALESCE((SELECT GROUP_CONCAT(provider) FROM identities i WHERE i.player_id = p.id), ''),
        \\  p.mock_sessions, p.mock_at
        \\FROM players p LEFT JOIN clans cl ON cl.id = p.clan_id WHERE p.id = ?
    , .{f.id});
    defer st.finalize();
    if (!try st.step()) return fail(c, "No such player.", .{});

    var rows: Rows = .empty;
    const fac = if (st.optInt(0)) |v| @tagName(@as(game.data.Faction, @enumFromInt(v))) else "none chosen";
    const providers = st.text(14);
    try rows.append(c.arena, try rowOf(c, .{ "Callsign", f.name }));
    try rows.append(c.arena, try rowOf(c, .{ "Faction, level", try std.fmt.allocPrint(c.arena, "{s}, level {d}", .{ fac, st.int(1) }) }));
    try rows.append(c.arena, try rowOf(c, .{ "Account", if (providers.len == 0) "guest (this phone only)" else try std.fmt.allocPrint(c.arena, "signed in with {s}", .{providers}) }));
    try rows.append(c.arena, try rowOf(c, .{ "Created", try stamp(c.arena, st.int(2)) }));
    try rows.append(c.arena, try rowOf(c, .{ "Last active", try stamp(c.arena, st.int(3)) }));
    if (st.text(11).len > 0) {
        try rows.append(c.arena, try rowOf(c, .{ "Clan", try std.fmt.allocPrint(c.arena, "[{s}] {s} ({s})", .{ st.text(11), st.text(12), st.text(13) }) }));
    } else try rows.append(c.arena, try rowOf(c, .{ "Clan", "none" }));
    try rows.append(c.arena, try rowOf(c, .{ "Record", try std.fmt.allocPrint(c.arena, "{d} wins, {d} losses; Contact {d} won, {d} lost", .{ st.int(7), st.int(8), st.int(9), st.int(10) }) }));
    const until = st.int(4);
    const banned = try banText(c, until, st.text(5));
    try rows.append(c.arena, try rowOf(c, .{ "Suspension", banned }));
    try rows.append(c.arena, try rowOf(c, .{ "Must rename", if (st.int(6) != 0) "yes, on next launch" else "no" }));
    // Sessions played with the phone reporting a simulated location (no position is ever stored).
    const mock_sessions = st.int(15);
    try rows.append(c.arena, try rowOf(c, .{
        "Fake GPS",
        if (mock_sessions == 0) "never reported" else try std.fmt.allocPrint(c.arena, "{d} session{s}, last {s} UTC", .{ mock_sessions, if (mock_sessions == 1) "" else "s", try stamp(c.arena, st.int(16)) }),
    }));

    const msgs = (try c.db.scalar("SELECT COUNT(*) FROM clan_chat WHERE player_id = ?", .{f.id})) orelse 0;
    const against = (try c.db.scalar("SELECT COUNT(*) FROM reports WHERE target_player_id = ? AND status = 'open'", .{f.id})) orelse 0;
    const against_all = (try c.db.scalar("SELECT COUNT(*) FROM reports WHERE target_player_id = ?", .{f.id})) orelse 0;
    const filed = (try c.db.scalar("SELECT COUNT(*) FROM reports WHERE reporter_id = ?", .{f.id})) orelse 0;
    try rows.append(c.arena, try rowOf(c, .{ "Clan chat messages", try std.fmt.allocPrint(c.arena, "{d}", .{msgs}) }));
    try rows.append(c.arena, try rowOf(c, .{ "Reports about them", try std.fmt.allocPrint(c.arena, "{d} open, {d} in all", .{ against, against_all }) }));
    try rows.append(c.arena, try rowOf(c, .{ "Reports they filed", try std.fmt.allocPrint(c.arena, "{d}", .{filed}) }));
    try table(c, &.{ "FIELD", "VALUE" }, rows.items);
}

fn banText(c: Ctx, until: i64, reason: []const u8) Error![]const u8 {
    if (until <= c.now) return "none";
    if (until == forever) return std.fmt.allocPrint(c.arena, "banned for good. Reason: {s}", .{reason});
    return std.fmt.allocPrint(c.arena, "banned until {s} UTC. Reason: {s}", .{ try stamp(c.arena, until), reason });
}

// --- errors ---------------------------------------------------------------------------------------------

/// "7d" or "36h" in milliseconds; a bare number is days.
fn parseSpan(text: []const u8) ?i64 {
    if (text.len == 0) return null;
    const unit: i64 = switch (text[text.len - 1]) {
        'h' => std.time.ms_per_hour,
        'd' => std.time.ms_per_day,
        '0'...'9' => std.time.ms_per_day,
        else => return null,
    };
    const digits = if (text[text.len - 1] >= '0' and text[text.len - 1] <= '9') text else text[0 .. text.len - 1];
    const n = std.fmt.parseInt(i64, digits, 10) catch return null;
    if (n <= 0 or n > 3650 * 24) return null;
    return n * unit;
}

fn plural(n: i64) []const u8 {
    return if (n == 1) "" else "s";
}

fn errors(c: Ctx, rest: []const []const u8) Error!void {
    if (rest.len == 1 and eql(rest[0], "clear")) {
        const n = (try c.db.scalar("SELECT COUNT(*) FROM client_errors", .{})) orelse 0;
        try c.db.run("DELETE FROM client_errors", .{});
        return say(c, "Deleted {d} error report{s}.", .{ n, plural(n) });
    }
    var span: ?i64 = null;
    if (rest.len == 2 and eql(rest[0], "--since")) {
        span = parseSpan(rest[1]) orelse return fail(c, "\"{s}\" is not a span. Use a number of days or hours, such as 7d or 36h.", .{rest[1]});
    } else if (rest.len != 0) {
        try c.out.print("Usage: outbreak-server admin errors [--since 7d] | errors clear\n", .{});
        return error.Failed;
    }
    const since: i64 = if (span) |s| c.now - s else 0;

    const total = (try c.db.scalar("SELECT COUNT(*) FROM client_errors WHERE at >= ?", .{since})) orelse 0;
    if (total == 0) return say(c, "No error reports{s}.", .{if (span != null) " in that time" else ""});
    // The bare columns (message, frame) come from the row holding MAX(at): the latest report of the group.
    var st = try c.db.query(
        \\SELECT COUNT(*), MAX(at), GROUP_CONCAT(DISTINCT version), GROUP_CONCAT(DISTINCT platform), message, frame
        \\FROM client_errors WHERE at >= ? GROUP BY hash ORDER BY COUNT(*) DESC, MAX(at) DESC LIMIT 50
    , .{since});
    defer st.finalize();
    var rows: Rows = .empty;
    while (try st.step()) {
        try rows.append(c.arena, try rowOf(c, .{
            try std.fmt.allocPrint(c.arena, "{d}", .{st.int(0)}),
            try stamp(c.arena, st.int(1)),
            try clip(c.arena, st.optText(2) orelse "", 20),
            try clip(c.arena, st.optText(3) orelse "", 16),
            try clip(c.arena, st.text(4), 70),
            try clip(c.arena, st.text(5), 60),
        }));
    }
    const groups = (try c.db.scalar("SELECT COUNT(DISTINCT hash) FROM client_errors WHERE at >= ?", .{since})) orelse 0;
    const when: []const u8 = if (span != null) " in that time" else "";
    try say(c, "{d} report{s} in {d} group{s}{s}. The table keeps the newest 5000.\n", .{ total, plural(total), groups, plural(groups), when });
    try table(c, &.{ "COUNT", "LAST SEEN (UTC)", "VERSIONS", "PLATFORMS", "MESSAGE", "TOP FRAME" }, rows.items);
}

// --- rename -------------------------------------------------------------------------------------------

fn rename(c: Ctx, callsign: []const u8) Error!void {
    const f = try findPlayer(c, callsign);
    var name: []const u8 = undefined;
    var lc: []const u8 = undefined;
    while (true) {
        name = try std.fmt.allocPrint(c.arena, "Survivor{d:0>4}", .{c.rng.below(10000)});
        lc = try std.ascii.allocLowerString(c.arena, name);
        if ((try c.db.scalar("SELECT id FROM players WHERE callsign_lc = ?", .{lc})) == null) break;
    }
    try c.db.run("UPDATE players SET callsign = ?, callsign_lc = ?, must_rename = 1 WHERE id = ?", .{ name, lc, f.id });
    try say(c, "{s} is now {s}. They will be asked to choose a new callsign next time the app opens.", .{ f.name, name });
    try noteClosed(c, try closeReports(c, "kind = 'player' AND target_player_id = ?", f.id));
}

fn clanRename(c: Ctx, tag: []const u8) Error!void {
    const tag_lc = try std.ascii.allocLowerString(c.arena, std.mem.trim(u8, tag, " []"));
    var id: i64 = 0;
    var old: []const u8 = "";
    {
        var st = try c.db.query("SELECT id, tag, name FROM clans WHERE tag_lc = ?", .{tag_lc});
        defer st.finalize();
        if (!try st.step()) return fail(c, "No clan with the tag \"{s}\".", .{tag});
        id = st.int(0);
        old = try std.fmt.allocPrint(c.arena, "[{s}] {s}", .{ st.text(1), st.text(2) });
    }
    var name: []const u8 = undefined;
    var new_tag: []const u8 = undefined;
    var name_lc: []const u8 = undefined;
    var new_tag_lc: []const u8 = undefined;
    while (true) {
        const n = c.rng.below(1000);
        name = try std.fmt.allocPrint(c.arena, "Clan {d:0>3}", .{n});
        new_tag = try std.fmt.allocPrint(c.arena, "C{d:0>3}", .{n});
        name_lc = try std.ascii.allocLowerString(c.arena, name);
        new_tag_lc = try std.ascii.allocLowerString(c.arena, new_tag);
        if ((try c.db.scalar("SELECT id FROM clans WHERE name_lc = ? OR tag_lc = ?", .{ name_lc, new_tag_lc })) == null) break;
    }
    try c.db.run("UPDATE clans SET name = ?, name_lc = ?, tag = ?, tag_lc = ? WHERE id = ?", .{ name, name_lc, new_tag, new_tag_lc, id });
    try say(c, "{s} is now [{s}] {s}.", .{ old, new_tag, name });
    try noteClosed(c, try closeReports(c, "target_clan_id = ?", id));
}

fn deleteMessage(c: Ctx, id_text: []const u8) Error!void {
    const id = std.fmt.parseInt(i64, id_text, 10) catch return fail(c, "\"{s}\" is not a message number. `reports` shows message numbers.", .{id_text});
    var who: []const u8 = "";
    var text: []const u8 = "";
    {
        var st = try c.db.query("SELECT COALESCE(p.callsign, '[deleted]'), m.text FROM clan_chat m LEFT JOIN players p ON p.id = m.player_id WHERE m.id = ?", .{id});
        defer st.finalize();
        if (!try st.step()) return fail(c, "No clan chat message with the number {d}. It may already be deleted.", .{id});
        who = try st.dupe(c.arena, 0);
        text = try clip(c.arena, st.text(1), 80);
    }
    try c.db.run("DELETE FROM clan_chat WHERE id = ?", .{id});
    try say(c, "Deleted message {d} from {s}: \"{s}\"", .{ id, who, text });
    try noteClosed(c, try closeReports(c, "message_id = ?", id));
}

// --- ban ----------------------------------------------------------------------------------------------

fn ban(c: Ctx, rest: []const []const u8) Error!void {
    var callsign: ?[]const u8 = null;
    var days: ?i64 = null;
    var reason: []const u8 = default_ban_reason;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eql(a, "--days")) {
            i += 1;
            if (i >= rest.len) return fail(c, "--days needs a number, for example --days 7.", .{});
            days = std.fmt.parseInt(i64, rest[i], 10) catch return fail(c, "--days needs a whole number, for example --days 7.", .{});
            if (days.? < 1 or days.? > 3650) return fail(c, "--days must be between 1 and 3650. Leave it out for a permanent ban.", .{});
        } else if (eql(a, "--reason")) {
            i += 1;
            if (i >= rest.len) return fail(c, "--reason needs text in quotes.", .{});
            // Words after it up to the next flag belong to it, so a forgotten quote still works.
            var parts: std.ArrayList(u8) = .empty;
            while (i < rest.len and !std.mem.startsWith(u8, rest[i], "--")) : (i += 1) {
                if (parts.items.len > 0) try parts.append(c.arena, ' ');
                try parts.appendSlice(c.arena, rest[i]);
            }
            i -= 1;
            reason = std.mem.trim(u8, parts.items, " ");
            if (reason.len == 0) reason = default_ban_reason;
            if (reason.len > 200) return fail(c, "Keep the reason under 200 characters; the player reads it.", .{});
        } else if (callsign == null and !std.mem.startsWith(u8, a, "--")) {
            callsign = a;
        } else return fail(c, "Unexpected \"{s}\".\nUsage: outbreak-server admin ban <callsign> [--days N] [--reason \"text\"]", .{a});
    }
    const name = callsign orelse return fail(c, "Usage: outbreak-server admin ban <callsign> [--days N] [--reason \"text\"]", .{});
    const f = try findPlayer(c, name);
    const until: i64 = if (days) |d| c.now + d * std.time.ms_per_day else forever;
    try c.db.run("UPDATE players SET banned_until = ?, ban_reason = ? WHERE id = ?", .{ until, reason, f.id });
    if (days) |d| {
        try say(c, "{s} is banned until {s} UTC ({d} day{s}). Reason shown to them: {s}", .{ f.name, try stamp(c.arena, until), d, if (d == 1) "" else "s", reason });
    } else {
        try say(c, "{s} is banned for good. Reason shown to them: {s}", .{ f.name, reason });
    }
    try say(c, "Takes effect at once: every request from their phone is refused, and they are no longer offered as an Echo or listed on the boards.", .{});
    try noteClosed(c, try closeReports(c, "target_player_id = ?", f.id));
}

fn unban(c: Ctx, callsign: []const u8) Error!void {
    const f = try findPlayer(c, callsign);
    const was = (try c.db.scalar("SELECT banned_until FROM players WHERE id = ?", .{f.id})) orelse 0;
    try c.db.run("UPDATE players SET banned_until = 0, ban_reason = '' WHERE id = ?", .{f.id});
    if (was > c.now) try say(c, "{s} is no longer banned.", .{f.name}) else try say(c, "{s} was not banned.", .{f.name});
}

// --- Tests ----------------------------------------------------------------------------------------------

const testing = std.testing;
const now_ms: i64 = 1_793_188_800_000; // 2026-10-28 12:00 UTC

const Fix = struct {
    db: Db,
    rng: game.rng.Rng,

    fn init() !Fix {
        var db = try Db.open(":memory:");
        errdefer db.close();
        try db.run("INSERT INTO players(callsign, callsign_lc, token_hash, recovery_hash, faction, created_at, last_seen) VALUES('Alice','alice','t1','r1',0,?,?)", .{ now_ms, now_ms });
        try db.run("INSERT INTO players(callsign, callsign_lc, token_hash, recovery_hash, faction, created_at, last_seen) VALUES('Bob_9','bob_9','t2','r2',1,?,?)", .{ now_ms, now_ms });
        try db.run("INSERT INTO players(callsign, callsign_lc, token_hash, recovery_hash, faction, created_at, last_seen) VALUES('Cara','cara',  't3','r3',0,?,?)", .{ now_ms, now_ms });
        try db.run("INSERT INTO clans(name, name_lc, tag, tag_lc, code, faction, created_at) VALUES('Bad Clan','bad clan','BAD','bad','AAAAAAAA',0,?)", .{now_ms});
        try db.run("UPDATE players SET clan_id = 1, clan_role = 'leader' WHERE id = 1", .{});
        try db.run("INSERT INTO clan_chat(clan_id, player_id, text, at) VALUES(1, 1, 'hello there', ?)", .{now_ms});
        return .{ .db = db, .rng = game.rng.Rng.init(7) };
    }

    fn deinit(f: *Fix) void {
        f.db.close();
    }

    /// Run a command line; returns what it printed (caller frees) and whether it succeeded.
    fn cmd(f: *Fix, line: []const []const u8) !struct { text: []u8, ok: bool } {
        var aw: Writer.Allocating = .init(testing.allocator);
        errdefer aw.deinit();
        var ok = true;
        run(testing.allocator, &f.db, now_ms, &f.rng, line, &aw.writer) catch |e| switch (e) {
            error.Failed => ok = false,
            else => return e,
        };
        return .{ .text = try aw.toOwnedSlice(), .ok = ok };
    }

    fn report(f: *Fix, reporter: i64, key: []const u8, kind: []const u8, label: []const u8, player_id: ?i64, clan_id: ?i64, message_id: ?i64, reason: []const u8) !void {
        try f.db.run(
            "INSERT INTO reports(reporter_id, kind, target_key, target_player_id, target_clan_id, message_id, label, excerpt, reason, note, created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            .{ reporter, kind, key, player_id, clan_id, message_id, label, "hello there", reason, "he said a bad thing", now_ms },
        );
    }
};

test "reports are listed grouped by target and can be resolved" {
    var f = try Fix.init();
    defer f.deinit();
    const empty = try f.cmd(&.{"reports"});
    defer testing.allocator.free(empty.text);
    try testing.expect(std.mem.indexOf(u8, empty.text, "No open reports") != null);

    try f.report(2, "p:3", "player", "Cara", 3, null, null, "cheating");
    try f.report(1, "p:3", "player", "Cara", 3, null, null, "harassment");
    try f.report(2, "c:1", "clan", "[BAD] Bad Clan", null, 1, null, "name");
    const r = try f.cmd(&.{"reports"});
    defer testing.allocator.free(r.text);
    try testing.expect(r.ok);
    try testing.expect(std.mem.indexOf(u8, r.text, "3 open reports on 2 targets") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "player Cara") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "clan [BAD] Bad Clan") != null);
    // Cara has two reports and is listed before the clan.
    try testing.expect(std.mem.indexOf(u8, r.text, "player Cara").? < std.mem.indexOf(u8, r.text, "clan [BAD]").?);

    const done = try f.cmd(&.{ "resolve", "1" });
    defer testing.allocator.free(done.text);
    try testing.expect(done.ok);
    const again = try f.cmd(&.{ "resolve", "1" });
    defer testing.allocator.free(again.text);
    try testing.expect(!again.ok);
    try testing.expectEqual(@as(?i64, 2), try f.db.scalar("SELECT COUNT(*) FROM reports WHERE status = 'open'", .{}));
}

test "ban sets the suspension, closes reports, and unban lifts it" {
    var f = try Fix.init();
    defer f.deinit();
    try f.report(1, "p:3", "player", "Cara", 3, null, null, "cheating");

    const b = try f.cmd(&.{ "ban", "CARA", "--days", "7", "--reason", "Using", "a", "bot" });
    defer testing.allocator.free(b.text);
    try testing.expect(b.ok);
    try testing.expect(std.mem.indexOf(u8, b.text, "Closed 1 open report") != null);
    try testing.expectEqual(@as(?i64, now_ms + 7 * std.time.ms_per_day), try f.db.scalar("SELECT banned_until FROM players WHERE id = 3", .{}));
    var st = try f.db.query("SELECT ban_reason FROM players WHERE id = 3", .{});
    defer st.finalize();
    _ = try st.step();
    try testing.expectEqualStrings("Using a bot", st.text(0));

    const info = try f.cmd(&.{ "player", "cara" });
    defer testing.allocator.free(info.text);
    try testing.expect(std.mem.indexOf(u8, info.text, "banned until 2026-11-04") != null);

    const forever_ban = try f.cmd(&.{ "ban", "alice" });
    defer testing.allocator.free(forever_ban.text);
    try testing.expectEqual(@as(?i64, std.math.maxInt(i64)), try f.db.scalar("SELECT banned_until FROM players WHERE id = 1", .{}));

    const u = try f.cmd(&.{ "unban", "cara" });
    defer testing.allocator.free(u.text);
    try testing.expect(std.mem.indexOf(u8, u.text, "no longer banned") != null);
    try testing.expectEqual(@as(?i64, 0), try f.db.scalar("SELECT banned_until FROM players WHERE id = 3", .{}));

    const bad = try f.cmd(&.{ "ban", "nobody" });
    defer testing.allocator.free(bad.text);
    try testing.expect(!bad.ok);
    const bad_days = try f.cmd(&.{ "ban", "cara", "--days", "soon" });
    defer testing.allocator.free(bad_days.text);
    try testing.expect(!bad_days.ok);
}

test "rename, clan-rename and delete-message" {
    var f = try Fix.init();
    defer f.deinit();
    try f.report(2, "p:1", "player", "Alice", 1, null, null, "name");
    try f.report(2, "c:1", "clan", "[BAD] Bad Clan", null, 1, null, "name");
    try f.report(3, "m:1", "message", "Alice", 1, null, 1, "harassment");

    const r = try f.cmd(&.{ "rename", "alice" });
    defer testing.allocator.free(r.text);
    try testing.expect(r.ok);
    var st = try f.db.query("SELECT callsign, callsign_lc, must_rename FROM players WHERE id = 1", .{});
    defer st.finalize();
    _ = try st.step();
    try testing.expect(std.mem.startsWith(u8, st.text(0), "Survivor"));
    try testing.expectEqualStrings("survivor", st.text(1)[0..8]);
    try testing.expectEqual(@as(i64, 1), st.int(2));

    const c = try f.cmd(&.{ "clan-rename", "[bad]" });
    defer testing.allocator.free(c.text);
    try testing.expect(c.ok);
    try testing.expectEqual(@as(?i64, 0), try f.db.scalar("SELECT COUNT(*) FROM clans WHERE tag = 'BAD'", .{}));
    try testing.expectEqual(@as(?i64, 1), try f.db.scalar("SELECT COUNT(*) FROM clans WHERE name LIKE 'Clan %'", .{}));

    const d = try f.cmd(&.{ "delete-message", "1" });
    defer testing.allocator.free(d.text);
    try testing.expect(d.ok);
    try testing.expectEqual(@as(?i64, 0), try f.db.scalar("SELECT COUNT(*) FROM clan_chat", .{}));
    try testing.expectEqual(@as(?i64, 0), try f.db.scalar("SELECT COUNT(*) FROM reports WHERE status = 'open'", .{}));
    const gone = try f.cmd(&.{ "delete-message", "1" });
    defer testing.allocator.free(gone.text);
    try testing.expect(!gone.ok);
}

test "player summary shows no location, fight history or email" {
    var f = try Fix.init();
    defer f.deinit();
    try f.db.run("INSERT INTO identities(provider, subject, player_id, email, created_at) VALUES('google','sub',1,'alice@example.com',?)", .{now_ms});
    const r = try f.cmd(&.{ "player", "Alice" });
    defer testing.allocator.free(r.text);
    try testing.expect(r.ok);
    try testing.expect(std.mem.indexOf(u8, r.text, "signed in with google") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "[BAD] Bad Clan (leader)") != null);
    try testing.expect(std.mem.indexOf(u8, r.text, "alice@example.com") == null);
    try testing.expect(std.mem.indexOf(u8, r.text, "lat") == null);
}

test "unknown commands and missing arguments print usage" {
    var f = try Fix.init();
    defer f.deinit();
    const a = try f.cmd(&.{"frobnicate"});
    defer testing.allocator.free(a.text);
    try testing.expect(!a.ok);
    try testing.expect(std.mem.indexOf(u8, a.text, "usage: outbreak-server admin") != null);
    const b = try f.cmd(&.{"rename"});
    defer testing.allocator.free(b.text);
    try testing.expect(!b.ok);
    const c = try f.cmd(&.{});
    defer testing.allocator.free(c.text);
    try testing.expect(!c.ok);
}

test "player shows how many sessions reported a fake GPS, and no position" {
    var f = try Fix.init();
    defer f.deinit();
    const none = try f.cmd(&.{ "player", "Alice" });
    defer testing.allocator.free(none.text);
    try testing.expect(std.mem.indexOf(u8, none.text, "Fake GPS") != null and std.mem.indexOf(u8, none.text, "never reported") != null);

    try f.db.run("UPDATE players SET mock_sessions = 3, mock_at = ? WHERE id = 1", .{now_ms});
    const some = try f.cmd(&.{ "player", "Alice" });
    defer testing.allocator.free(some.text);
    try testing.expect(std.mem.indexOf(u8, some.text, "3 sessions, last 2026-10-28 12:00 UTC") != null);
}

fn addError(f: *Fix, at: i64, hash: []const u8, message: []const u8, version: []const u8, platform: []const u8) !void {
    try f.db.run(
        "INSERT INTO client_errors(at, hash, message, stack, frame, version, platform, screen) VALUES(?,?,?,'','at f (a.js:1:2)',?,?,'map')",
        .{ at, hash, message, version, platform },
    );
}

test "errors: groups with counts, versions and last seen; --since; clear" {
    var f = try Fix.init();
    defer f.deinit();
    const empty = try f.cmd(&.{"errors"});
    defer testing.allocator.free(empty.text);
    try testing.expect(empty.ok and std.mem.indexOf(u8, empty.text, "No error reports.") != null);

    const day = std.time.ms_per_day;
    try addError(&f, now_ms - 9 * day, "aaaa", "Old trouble", "0.0.9", "android");
    try addError(&f, now_ms - 2 * day, "bbbb", "Map would not load", "0.1.0", "android");
    try addError(&f, now_ms - 1 * day, "bbbb", "Map would not load", "0.1.1", "ios");
    try addError(&f, now_ms - 3600_000, "bbbb", "Map would not load", "0.1.1", "android");
    try addError(&f, now_ms - 3600_000, "cccc", "Undefined is not a function", "0.1.1", "web");

    const all = try f.cmd(&.{"errors"});
    defer testing.allocator.free(all.text);
    try testing.expect(all.ok);
    try testing.expect(std.mem.indexOf(u8, all.text, "5 reports in 3 groups") != null);
    try testing.expect(std.mem.indexOf(u8, all.text, "Old trouble") != null);
    // The biggest group comes first, with its versions and the time of its newest report.
    const map_at = std.mem.indexOf(u8, all.text, "Map would not load").?;
    try testing.expect(map_at < std.mem.indexOf(u8, all.text, "Undefined is not a function").?);
    try testing.expect(std.mem.indexOf(u8, all.text, "0.1.0,0.1.1") != null or std.mem.indexOf(u8, all.text, "0.1.1,0.1.0") != null);
    try testing.expect(std.mem.indexOf(u8, all.text, "2026-10-28 11:00") != null);

    const week = try f.cmd(&.{ "errors", "--since", "7d" });
    defer testing.allocator.free(week.text);
    try testing.expect(week.ok);
    try testing.expect(std.mem.indexOf(u8, week.text, "4 reports in 2 groups in that time") != null);
    try testing.expect(std.mem.indexOf(u8, week.text, "Old trouble") == null);
    const hours = try f.cmd(&.{ "errors", "--since", "2h" });
    defer testing.allocator.free(hours.text);
    try testing.expect(std.mem.indexOf(u8, hours.text, "2 reports in 2 groups") != null);

    const bad = try f.cmd(&.{ "errors", "--since", "soon" });
    defer testing.allocator.free(bad.text);
    try testing.expect(!bad.ok and std.mem.indexOf(u8, bad.text, "not a span") != null);
    const usage_err = try f.cmd(&.{ "errors", "--wat" });
    defer testing.allocator.free(usage_err.text);
    try testing.expect(!usage_err.ok);

    const cleared = try f.cmd(&.{ "errors", "clear" });
    defer testing.allocator.free(cleared.text);
    try testing.expect(cleared.ok and std.mem.indexOf(u8, cleared.text, "Deleted 5 error reports.") != null);
    try testing.expectEqual(@as(?i64, 0), try f.db.scalar("SELECT COUNT(*) FROM client_errors", .{}));
}
