//! The note archive (docs/LORE.md): GET /api/notes and POST /api/notes/claim.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("../ctx.zig");
const model = @import("../model.zig");
const views = @import("../views.zig");
const rewards = @import("../rewards.zig");
const notes_db = @import("../notes.zig");

const gn = game.notes;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Stringify = std.json.Stringify;

const SetView = struct {
    id: []const u8,
    name: []const u8,
    title: []const u8,
    blurb: []const u8,
    total: u32,
    found: u32,
    reward: u32,
    claimed: bool,
};

/// A note in the archive. Unfound ones carry only what the shelf needs: set and rarity.
const NoteView = struct {
    id: []const u8,
    set: []const u8,
    rarity: game.data.Rarity,
    locked: bool,
    title: ?[]const u8 = null,
    author: ?[]const u8 = null,
    date: ?[]const u8 = null,
    form: ?gn.Form = null,
    body: ?[]const u8 = null,
    found_at: ?i64 = null,
};

pub fn list(req: *Req, jw: *Stringify) HandlerError!void {
    const p = (try model.load(req, req.pid)).?;
    const f = p.fac();
    const found = try notes_db.foundSet(req, p.id);
    const claimed = try notes_db.claimedSets(req, p.id);

    var set_views: std.ArrayList(SetView) = .empty;
    for (gn.sets) |s| {
        if (!gn.setVisibleTo(s.id, f)) continue;
        const have = gn.setFound(s.id, found);
        // Patient Zero stays a sealed envelope until the first piece turns up.
        const sealed = s.id == .zero and have == 0;
        const done = std.mem.indexOfScalar(gn.SetId, claimed, s.id) != null;
        try set_views.append(req.arena, .{
            .id = @tagName(s.id),
            .name = if (sealed) "???" else s.name,
            .title = if (sealed) "???" else s.title,
            .blurb = if (sealed) "" else s.blurb,
            .total = gn.setTotal(s.id),
            .found = have,
            .reward = gn.setReward(s.id),
            .claimed = done,
        });
    }

    // found_at for the notes held.
    var at = std.StringHashMap(i64).init(req.arena);
    {
        var st = try req.ctx.db.query("SELECT note_id, found_at FROM player_notes WHERE player_id = ?", .{p.id});
        defer st.finalize();
        while (try st.step()) try at.put(try st.dupe(req.arena, 0), st.int(1));
    }

    var note_views: std.ArrayList(NoteView) = .empty;
    for (gn.notes, 0..) |n, i| {
        if (!gn.visibleTo(n, f)) continue;
        if (found.isSet(i)) {
            try note_views.append(req.arena, .{
                .id = n.id,
                .set = @tagName(n.set),
                .rarity = n.rarity,
                .locked = false,
                .title = n.title,
                .author = n.author,
                .date = n.date,
                .form = n.form,
                .body = n.body,
                .found_at = at.get(n.id) orelse 0,
            });
        } else {
            try note_views.append(req.arena, .{ .id = n.id, .set = @tagName(n.set), .rarity = n.rarity, .locked = true });
        }
    }
    try jw.write(.{ .sets = set_views.items, .notes = note_views.items });
}

/// Claiming a completed set pays salvage (the sum of its notes' rarity values) and its title.
pub fn claim(req: *Req, jw: *Stringify) HandlerError!void {
    const body = try req.json(struct { set: []const u8 });
    var p = (try model.load(req, req.pid)).?;
    const id = gn.setIndexOf(body.set) orelse return req.fail(404, "not_found", "No such set.");
    if (!gn.setVisibleTo(id, p.fac())) return req.fail(404, "not_found", "No such set.");
    const found = try notes_db.foundSet(req, p.id);
    if (!gn.setComplete(id, found)) return req.fail(409, "set_incomplete", "That set is not complete yet.");
    if (try notes_db.claimed(req, p.id, id)) return req.fail(409, "already_claimed", "You already claimed that set.");

    try req.ctx.db.run("INSERT INTO note_claims(player_id, set_id, claimed_at) VALUES(?,?,?)", .{ p.id, @tagName(id), req.now });
    var acc = rewards.Acc{ .salvage = gn.setReward(id) };
    const rw = try rewards.apply(req, &p, &acc, null);
    try jw.write(.{ .rewards = rw, .title = gn.set(id).title, .me = try views.meFresh(req, p.id) });
}
