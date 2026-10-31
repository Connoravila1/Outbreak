//! The event feed: contact results, echo reports, level-ups, raid results. Events are stored with
//! their Battle/Rewards JSON and delivered once through the next /api/location.

const std = @import("std");
const ctx_mod = @import("ctx.zig");
const views = @import("views.zig");

const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;

pub const EventView = struct {
    id: []const u8,
    at: i64,
    type: []const u8,
    text: []const u8,
    battle: ?views.Raw,
    rewards: ?views.Raw,

    /// `battle` and `rewards` are left out when absent, rather than sent as null.
    pub fn jsonStringify(self: EventView, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("at");
        try jw.write(self.at);
        try jw.objectField("type");
        try jw.write(self.type);
        try jw.objectField("text");
        try jw.write(self.text);
        if (self.battle) |b| {
            try jw.objectField("battle");
            try jw.write(b);
        }
        if (self.rewards) |r| {
            try jw.objectField("rewards");
            try jw.write(r);
        }
        try jw.endObject();
    }
};

/// What a notification needs: no Battle, no Rewards.
pub const NoticeView = struct { id: []const u8, type: []const u8, text: []const u8, at: i64 };

/// Events not yet notified (a Patrol check-in), oldest first, marked notified but not delivered:
/// the app still receives them, with the full Battle, when it opens.
pub fn takeUnnotified(req: *Req, pid: i64) HandlerError![]const NoticeView {
    const a = req.arena;
    var list: std.ArrayList(NoticeView) = .empty;
    var last: i64 = 0;
    {
        var st = try req.ctx.db.query(
            "SELECT id, at, type, text FROM events WHERE player_id = ? AND notified = 0 ORDER BY id LIMIT 20",
            .{pid},
        );
        defer st.finalize();
        while (try st.step()) {
            last = st.int(0);
            try list.append(a, .{
                .id = try std.fmt.allocPrint(a, "{d}", .{last}),
                .at = st.int(1),
                .type = try st.dupe(a, 2),
                .text = try st.dupe(a, 3),
            });
        }
    }
    if (list.items.len > 0) {
        try req.ctx.db.run("UPDATE events SET notified = 1 WHERE player_id = ? AND notified = 0 AND id <= ?", .{ pid, last });
    }
    return list.items;
}

/// Undelivered events, oldest first, marked delivered (and notified: the player has seen them).
pub fn takeUndelivered(req: *Req, pid: i64) HandlerError![]const EventView {
    const a = req.arena;
    var list: std.ArrayList(EventView) = .empty;
    {
        var st = try req.ctx.db.query(
            "SELECT id, at, type, text, battle, rewards FROM events WHERE player_id = ? AND delivered = 0 ORDER BY id LIMIT 20",
            .{pid},
        );
        defer st.finalize();
        while (try st.step()) {
            try list.append(a, .{
                .id = try std.fmt.allocPrint(a, "{d}", .{st.int(0)}),
                .at = st.int(1),
                .type = try st.dupe(a, 2),
                .text = try st.dupe(a, 3),
                .battle = if (st.optText(4)) |t| .{ .text = try a.dupe(u8, t) } else null,
                .rewards = if (st.optText(5)) |t| .{ .text = try a.dupe(u8, t) } else null,
            });
        }
    }
    if (list.items.len > 0) {
        try req.ctx.db.run("UPDATE events SET delivered = 1, notified = 1 WHERE player_id = ? AND delivered = 0 AND id <= ?", .{ pid, lastId(list.items) });
    }
    return list.items;
}

fn lastId(events: []const EventView) i64 {
    return std.fmt.parseInt(i64, events[events.len - 1].id, 10) catch 0;
}

/// The last 50 events, newest first, without the heavy bodies.
pub fn recent(req: *Req, pid: i64) HandlerError![]const EventView {
    const a = req.arena;
    var list: std.ArrayList(EventView) = .empty;
    var st = try req.ctx.db.query("SELECT id, at, type, text FROM events WHERE player_id = ? ORDER BY id DESC LIMIT 50", .{pid});
    defer st.finalize();
    while (try st.step()) {
        try list.append(a, .{
            .id = try std.fmt.allocPrint(a, "{d}", .{st.int(0)}),
            .at = st.int(1),
            .type = try st.dupe(a, 2),
            .text = try st.dupe(a, 3),
            .battle = null,
            .rewards = null,
        });
    }
    return list.items;
}
