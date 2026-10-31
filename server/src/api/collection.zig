//! Achievements, the collection log and cosmetics: GET /api/achievements, GET /api/collection and
//! POST /api/cosmetics/equip. Buying a cosmetic is a store purchase (api/gear.zig).

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("../ctx.zig");
const model = @import("../model.zig");
const views = @import("../views.zig");
const ach_db = @import("../achievements.zig");

const ga = game.achievements;
const gc = game.cosmetics;
const data = game.data;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Stringify = std.json.Stringify;

/// `Record<metric, number>`: where the player stands on everything an achievement counts.
const ProgressMap = struct {
    values: ga.Metrics,

    pub fn jsonStringify(self: ProgressMap, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(ga.Metric).@"enum".fields) |f| {
            try jw.objectField(f.name);
            try jw.write(self.values.get(@field(ga.Metric, f.name)));
        }
        try jw.endObject();
    }
};

const EarnedRow = struct { id: []const u8, at: i64 };

/// The earned list (oldest first) and current progress. Anything the player qualifies for but has
/// not been credited yet (a day count that rolled over, say) is credited now.
pub fn achievements(req: *Req, jw: *Stringify) HandlerError!void {
    var p = (try model.load(req, req.pid)).?;
    const fresh = try ach_db.check(req, &p, false);
    if (fresh.len > 0) try model.save(req, &p);

    var earned: std.ArrayList(EarnedRow) = .empty;
    {
        var st = try req.ctx.db.query("SELECT ach_id, earned_at FROM achievements WHERE player_id = ? ORDER BY earned_at, rowid", .{p.id});
        defer st.finalize();
        while (try st.step()) {
            if (ga.find(st.text(0)) == null) continue;
            try earned.append(req.arena, .{ .id = try st.dupe(req.arena, 0), .at = st.int(1) });
        }
    }
    try jw.write(.{ .earned = earned.items, .progress = ProgressMap{ .values = try ach_db.metrics(req, &p) }, .fresh = fresh });
}

fn ids(req: *Req, idxs: []const u8, comptime rows: anytype) HandlerError![]const []const u8 {
    const out = try req.arena.alloc([]const u8, idxs.len);
    for (idxs, out) |i, *o| o.* = rows[i].id;
    return out;
}

/// What the player has ever held: item bases, legendary uniques and rarities. Anything not listed
/// is still a silhouette. The bestiary is on `Me`.
pub fn collection(req: *Req, jw: *Stringify) HandlerError!void {
    const pid = req.pid;
    const bases = try ach_db.discovered(req, pid, .base);
    const uniques = try ach_db.discovered(req, pid, .unique);
    const rarity_idx = try ach_db.discovered(req, pid, .rarity);
    const rarities = try req.arena.alloc([]const u8, rarity_idx.len);
    for (rarity_idx, rarities) |i, *r| r.* = @tagName(@as(data.Rarity, @enumFromInt(i)));
    try jw.write(.{
        .bases = try ids(req, bases, data.bases),
        .uniques = try ids(req, uniques, data.uniques),
        .rarities = rarities,
    });
}

/// Wear an owned colour or frame, or take it off (`id` null or empty).
pub fn equipCosmetic(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { kind: []const u8, id: ?[]const u8 = null });
    const kind = std.meta.stringToEnum(gc.Kind, body.kind) orelse return req.fail(400, "bad_request", "Kind must be \"color\" or \"frame\".");
    const id = body.id orelse "";
    if (id.len > 0) {
        const ci = gc.find(id) orelse return req.fail(404, "not_found", "No such cosmetic.");
        if (gc.list[ci].kind != kind) return req.fail(400, "bad_request", "That is not a cosmetic of that kind.");
        if (!try ach_db.owns(req, req.pid, id)) return req.fail(409, "not_owned", "You do not own that.");
    }
    switch (kind) {
        .color => try req.ctx.db.run("UPDATE players SET callsign_color = ? WHERE id = ?", .{ id, req.pid }),
        .frame => try req.ctx.db.run("UPDATE players SET avatar_frame = ? WHERE id = ?", .{ id, req.pid }),
    }
    try jw.write(.{ .me = try views.meFresh(req, req.pid) });
}
