//! Missions on the server: which daily/weekly missions a player has, progress from game events,
//! and the preview of rewards. Definitions come from the game core; the level they were generated
//! at is frozen per day (daily) and per week so the list does not change while a player levels.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("ctx.zig");
const model = @import("model.zig");

const gm = game.missions;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Player = model.Player;

pub const Entry = struct {
    m: gm.Mission,
    progress: u32,
    claimed: bool,
    /// "d.20400.1" style id, owned by the request arena.
    id: []const u8,
};

pub const Today = struct {
    daily: []Entry,
    weekly: ?Entry,
};

/// Freeze the generation level at the start of each day/week (and when the weekly first unlocks).
pub fn ensurePeriod(req: *Req, p: *Player) HandlerError!void {
    const day = game.war.dayIndex(req.now);
    const wk = game.war.weekIndex(req.now);
    var changed = false;
    if (p.mday != day) {
        p.mday = day;
        p.mlevel = p.level;
        changed = true;
    }
    if (p.mweek != wk) {
        p.mweek = wk;
        p.wlevel = p.level;
        changed = true;
    } else if (p.wlevel < gm.weekly_min_level and p.level >= gm.weekly_min_level) {
        p.wlevel = p.level;
        changed = true;
    }
    if (changed) {
        try req.ctx.db.run("UPDATE players SET mday = ?, mlevel = ?, mweek = ?, wlevel = ? WHERE id = ?", .{ p.mday, p.mlevel, p.mweek, p.wlevel, p.id });
    }
}

fn entry(req: *Req, p: *const Player, m: gm.Mission) HandlerError!Entry {
    var idb = m.id();
    const id = try req.arena.dupe(u8, idb.str());
    var progress: u32 = 0;
    var claimed = false;
    var st = try req.ctx.db.query("SELECT progress, claimed FROM mission_progress WHERE player_id = ? AND mid = ?", .{ p.id, id });
    defer st.finalize();
    if (try st.step()) {
        progress = @intCast(st.int(0));
        claimed = st.int(1) != 0;
    }
    return .{ .m = m, .progress = progress, .claimed = claimed, .id = id };
}

pub fn today(req: *Req, p: *Player) HandlerError!Today {
    try ensurePeriod(req, p);
    const dm = gm.dailyMissions(@intCast(p.id), p.mday, p.mlevel);
    const list = try req.arena.alloc(Entry, dm.len);
    for (dm, 0..) |m, i| list[i] = try entry(req, p, m);
    var weekly: ?Entry = null;
    if (gm.weeklyMission(@intCast(p.id), p.mweek, p.wlevel)) |m| weekly = try entry(req, p, m);
    return .{ .daily = list, .weekly = weekly };
}

/// A mission by id, only if it is one of the player's current ones.
pub fn find(req: *Req, p: *Player, id: []const u8) HandlerError!?Entry {
    const t = try today(req, p);
    for (t.daily) |e| {
        if (std.mem.eql(u8, e.id, id)) return e;
    }
    if (t.weekly) |w| {
        if (std.mem.eql(u8, w.id, id)) return w;
    }
    return null;
}

/// Advance every matching mission for a game event.
pub fn event(req: *Req, p: *Player, ev: gm.Event) HandlerError!void {
    const t = try today(req, p);
    for (t.daily) |e| try bump(req, p.id, e, ev);
    if (t.weekly) |w| try bump(req, p.id, w, ev);
}

fn bump(req: *Req, pid: i64, e: Entry, ev: gm.Event) HandlerError!void {
    const delta = gm.progressDelta(e.m, ev);
    if (delta == 0) return;
    try req.ctx.db.run(
        "INSERT INTO mission_progress(player_id, mid, progress) VALUES(?,?,MIN(?,?)) ON CONFLICT(player_id, mid) DO UPDATE SET progress = MIN(?, progress + ?)",
        .{ pid, e.id, e.m.target, delta, e.m.target, delta },
    );
}

/// The streak a claim today would produce (what the preview and the payout both use).
pub fn streakIfClaimed(req: *Req, p: *const Player) u32 {
    const day = game.war.dayIndex(req.now);
    return gm.streakAfterClaim(gm.streakShown(p.streak, p.last_claim_day, day), p.last_claim_day, day);
}
