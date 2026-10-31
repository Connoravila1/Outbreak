//! Found notes on the server side: what a player holds, granting a note once, set claims and the
//! titles they earn. The rules (what drops, what a set pays) are in game/notes.zig.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("ctx.zig");

const gn = game.notes;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;

/// The notes `pid` holds.
pub fn foundSet(req: *Req, pid: i64) HandlerError!gn.Found {
    var found = gn.Found.initEmpty();
    var st = try req.ctx.db.query("SELECT note_id FROM player_notes WHERE player_id = ?", .{pid});
    defer st.finalize();
    while (try st.step()) {
        if (gn.indexOf(st.text(0))) |i| found.set(i);
    }
    return found;
}

/// Record note `idx` for `pid`. False when they already had it (never a duplicate).
pub fn grant(req: *Req, pid: i64, idx: u16) HandlerError!bool {
    const db = &req.ctx.db;
    try db.run("INSERT OR IGNORE INTO player_notes(player_id, note_id, found_at) VALUES(?,?,?)", .{ pid, gn.notes[idx].id, req.now });
    return db.changes() == 1;
}

pub fn claimed(req: *Req, pid: i64, id: gn.SetId) HandlerError!bool {
    return (try req.ctx.db.scalar("SELECT 1 FROM note_claims WHERE player_id = ? AND set_id = ?", .{ pid, @tagName(id) })) != null;
}

/// Set ids `pid` has claimed, oldest first.
pub fn claimedSets(req: *Req, pid: i64) HandlerError![]const gn.SetId {
    var out: std.ArrayList(gn.SetId) = .empty;
    var st = try req.ctx.db.query("SELECT set_id FROM note_claims WHERE player_id = ? ORDER BY claimed_at, set_id", .{pid});
    defer st.finalize();
    while (try st.step()) {
        if (gn.setIndexOf(st.text(0))) |s| try out.append(req.arena, s);
    }
    return out.items;
}

/// The cosmetic titles earned by completing sets.
pub fn titles(req: *Req, pid: i64) HandlerError![]const []const u8 {
    const ids = try claimedSets(req, pid);
    const out = try req.arena.alloc([]const u8, ids.len);
    for (ids, out) |id, *t| t.* = gn.set(id).title;
    return out;
}
