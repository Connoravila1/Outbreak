//! Limited-time events on the server (DESIGN.md section 18): which event is live, progress and
//! contributions, per-district targets, the payout when one ends, and the yearly title. What an
//! event changes in play is in game/events.zig; the Exchange and the endpoints are in
//! api/events.zig. The first half works on a bare `Db`, so the admin CLI can use it too.
//!
//! Events are rows. The calendar makes its row the first time anything looks during the event;
//! an admin's one-off event is a row from the start. A row never changes its start, so a stopped
//! calendar event is not made again.

const std = @import("std");
const game = @import("game");
const db_mod = @import("db.zig");
const ctx_mod = @import("ctx.zig");
const model = @import("model.zig");
const rewards = @import("rewards.zig");
const views = @import("views.zig");
const fight = @import("fight.zig");
const ach_db = @import("achievements.zig");

const data = game.data;
const gev = game.events;
const Db = db_mod.Db;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Player = model.Player;

const hour_ms: i64 = 60 * 60 * 1000;

pub const Row = struct {
    id: i64,
    type: data.EventType,
    admin: bool,
    starts_at: i64,
    ends_at: i64,
    param: u8,
    active_players: u32,
    target: u32,
    progress: u32,

    pub fn active(self: Row) gev.Active {
        return .{ .type = self.type, .param = self.param };
    }

    pub fn def(self: Row) data.EventDef {
        return data.eventDef(self.type);
    }

    pub fn done(self: Row) bool {
        return self.progress >= self.target;
    }
};

const row_cols = "id, type, source, starts_at, ends_at, param, active_players, target, progress";

fn readRow(st: *db_mod.Stmt) ?Row {
    const t = std.meta.stringToEnum(data.EventType, st.text(1)) orelse return null;
    return .{
        .id = st.int(0),
        .type = t,
        .admin = std.mem.eql(u8, st.text(2), "admin"),
        .starts_at = st.int(3),
        .ends_at = st.int(4),
        .param = @intCast(st.int(5)),
        .active_players = @intCast(st.int(6)),
        .target = @intCast(st.int(7)),
        .progress = @intCast(st.int(8)),
    };
}

// --- On a bare database ----------------------------------------------------------------------------

/// Players seen in the last 7 days who have chosen a side and are not suspended: the count the
/// global goal scales with.
pub fn activePlayers(db: *Db, now: i64) db_mod.Error!u32 {
    const n = try db.scalar(
        "SELECT COUNT(*) FROM players WHERE faction IS NOT NULL AND last_seen > ? AND banned_until <= ?",
        .{ now - game.war.week_ms, now },
    );
    return @intCast(n orelse 0);
}

/// Make the row for the scheduled event running now, if there is one and it has no row yet.
pub fn materialize(db: *Db, now: i64) db_mod.Error!void {
    const occ = gev.occurrenceAt(now) orelse return;
    if ((try db.scalar("SELECT 1 FROM world_events WHERE source = 'calendar' AND starts_at = ?", .{occ.starts_at})) != null) return;
    const players = try activePlayers(db, now);
    const def = data.eventDef(occ.type);
    try db.run(
        "INSERT OR IGNORE INTO world_events(type, source, starts_at, ends_at, param, active_players, target) VALUES(?,?,?,?,?,?,?)",
        .{ @tagName(occ.type), "calendar", occ.starts_at, occ.ends_at, occ.param, players, gev.target(def, players) },
    );
}

/// The event live at `at` (an admin's wins over the calendar's). Does not make rows.
pub fn rowAt(db: *Db, at: i64) db_mod.Error!?Row {
    var st = try db.query(
        "SELECT " ++ row_cols ++ " FROM world_events WHERE starts_at <= ? AND ends_at > ? ORDER BY (source = 'admin') DESC, id DESC LIMIT 1",
        .{ at, at },
    );
    defer st.finalize();
    if (!try st.step()) return null;
    return readRow(&st);
}

/// End whatever is running now (the calendar's event included) and return how many ended.
pub fn stopAll(db: *Db, now: i64, calendar: bool) db_mod.Error!i64 {
    if (calendar) try materialize(db, now);
    try db.run("UPDATE world_events SET ends_at = ? WHERE starts_at <= ? AND ends_at > ?", .{ now, now, now });
    return db.changes();
}

/// Start a one-off event now for `hours`, ending any that is running. For the Horde event `kind`
/// is the swarm's archetype. Returns the new row's id.
pub fn startAdmin(db: *Db, now: i64, t: data.EventType, hours: i64, kind: data.Archetype, calendar: bool) db_mod.Error!i64 {
    _ = try stopAll(db, now, calendar);
    const players = try activePlayers(db, now);
    const def = data.eventDef(t);
    try db.run(
        "INSERT INTO world_events(type, source, starts_at, ends_at, param, active_players, target) VALUES(?,?,?,?,?,?,?)",
        .{ @tagName(t), "admin", now, now + hours * hour_ms, if (t == .horde) @intFromEnum(kind) else 0, players, gev.target(def, players) },
    );
    return db.lastInsertId();
}

// --- Per request ---------------------------------------------------------------------------------------

/// The event live now, making its row if the calendar says one has started.
pub fn live(req: *Req) HandlerError!?Row {
    if (req.ctx.opts.events) try materialize(&req.ctx.db, req.now);
    return rowAt(&req.ctx.db, req.now);
}

/// The event that was live at `at`, as the world's rules see it (spawns follow the event live when
/// their window began).
pub fn activeAt(req: *Req, at: i64) HandlerError!?gev.Active {
    if (req.ctx.opts.events) try materialize(&req.ctx.db, req.now);
    const row = (try rowAt(&req.ctx.db, at)) orelse return null;
    return row.active();
}

/// The multipliers in force for `p` doing something now. A night-only event counts where they are.
pub fn rewardMods(req: *Req, p: *const Player) HandlerError!data.EventMods {
    const ev = (try activeAt(req, req.now)) orelse return .{};
    const night = if (req.ctx.live.position(p.id, req.now)) |pos| game.daynight.isNight(req.now, pos.lon) else false;
    return gev.rewardMods(ev, night);
}

fn districtActive(req: *Req, district: []const u8) HandlerError!u32 {
    const n = try req.ctx.db.scalar(
        "SELECT COUNT(DISTINCT player_id) FROM war_player WHERE district = ? AND week >= ?",
        .{ district, game.war.weekIndex(req.now) - 1 },
    );
    return @intCast(n orelse 0);
}

/// Count something a player did towards the live event's goal, in `district`.
pub fn credit(req: *Req, pid: i64, district: []const u8, c: gev.Credit) HandlerError!void {
    const row = (try live(req)) orelse return;
    const amount = gev.credit(row.active(), c);
    if (amount == 0) return;
    const db = &req.ctx.db;
    try db.run("UPDATE world_events SET progress = progress + ? WHERE id = ?", .{ amount, row.id });
    if ((try db.scalar("SELECT 1 FROM world_event_district WHERE event_id = ? AND district = ?", .{ row.id, district })) == null) {
        const players = @max(1, try districtActive(req, district));
        try db.run(
            "INSERT INTO world_event_district(event_id, district, active_players, target) VALUES(?,?,?,?)",
            .{ row.id, district, players, gev.districtTarget(row.def(), players) },
        );
    }
    try db.run("UPDATE world_event_district SET progress = progress + ? WHERE event_id = ? AND district = ?", .{ amount, row.id, district });
    try db.run(
        "INSERT INTO world_event_player(event_id, player_id, district, n) VALUES(?,?,?,?) ON CONFLICT(event_id, player_id, district) DO UPDATE SET n = n + excluded.n",
        .{ row.id, pid, district, amount },
    );
}

/// What `pid` has contributed to event `id` in all.
pub fn contribution(req: *Req, id: i64, pid: i64) HandlerError!u32 {
    const n = try req.ctx.db.scalar("SELECT COALESCE(SUM(n), 0) FROM world_event_player WHERE event_id = ? AND player_id = ?", .{ id, pid });
    return @intCast(n orelse 0);
}

/// Did the global goal, or the goal of a district `pid` contributed in, get reached?
pub fn goalMet(req: *Req, row: Row, pid: i64) HandlerError!bool {
    if (row.done()) return true;
    const hit = try req.ctx.db.scalar(
        \\SELECT 1 FROM world_event_player p JOIN world_event_district d ON d.event_id = p.event_id AND d.district = p.district
        \\WHERE p.event_id = ? AND p.player_id = ? AND p.n > 0 AND d.progress >= d.target LIMIT 1
    , .{ row.id, pid });
    return hit != null;
}

// --- The end ---------------------------------------------------------------------------------------------

/// Pay every ended event that has not been paid yet (called from the minute tick and when the
/// events endpoint is read). Each event is paid once: the flag is set before the payouts, inside
/// the same transaction.
pub fn upkeep(req: *Req) HandlerError!void {
    const db = &req.ctx.db;
    if (req.ctx.opts.events) try materialize(db, req.now);
    var due: std.ArrayList(Row) = .empty;
    {
        var st = try db.query("SELECT " ++ row_cols ++ " FROM world_events WHERE ends_at <= ? AND settled = 0 ORDER BY id", .{req.now});
        defer st.finalize();
        while (try st.step()) {
            if (readRow(&st)) |r| try due.append(req.arena, r);
        }
    }
    for (due.items) |row| try settle(req, row);
    try db.run("DELETE FROM world_events WHERE settled = 1 AND ends_at < ?", .{req.now - 60 * game.war.day_ms});
}

const Participant = struct { pid: i64, n: u32 };

fn settle(req: *Req, row: Row) HandlerError!void {
    const db = &req.ctx.db;
    try db.run("UPDATE world_events SET settled = 1 WHERE id = ?", .{row.id});
    var list: std.ArrayList(Participant) = .empty;
    {
        var st = try db.query("SELECT player_id, SUM(n) FROM world_event_player WHERE event_id = ? GROUP BY player_id ORDER BY player_id", .{row.id});
        defer st.finalize();
        while (try st.step()) try list.append(req.arena, .{ .pid = st.int(0), .n = @intCast(st.int(1)) });
    }
    const def = row.def();
    for (list.items) |part| {
        const met = try goalMet(req, row, part.pid);
        const pay = gev.payout(def, part.n, met);
        if (pay.tier == 0) continue;
        var pl = (try model.load(req, part.pid)) orelse continue;
        var acc = rewards.Acc{ .flat_xp = true, .salvage = pay.salvage, .deliver_level_up = true };
        if (pay.item) {
            var rng = game.rng.Rng.init(game.rng.hash(req.ctx.seed, .{ "evitem", row.id, part.pid }));
            try acc.items.append(req.arena, game.loot.rollItem(&rng, .{ .level = pl.level, .min_rarity = .rare, .legendary_mult = 2.0 }));
        }
        var rw = try rewards.apply(req, &pl, &acc, null);
        var unlocks: std.ArrayList(views.UnlockRef) = .empty;
        const f = pl.fac();
        if (pay.cosmetic) {
            if (!try ach_db.owns(req, pl.id, def.cosmetic)) {
                try ach_db.grantCosmetic(req, pl.id, def.cosmetic);
                const c = game.cosmetics.list[game.cosmetics.find(def.cosmetic).?];
                try unlocks.append(req.arena, .{ .kind = @tagName(c.kind), .id = c.id, .name = c.name.get(f) });
            }
        }
        if (pay.title) {
            const year = gev.yearOf(row.starts_at);
            try db.run("INSERT OR IGNORE INTO event_titles(player_id, year, earned_at) VALUES(?,?,?)", .{ pl.id, year, req.now });
            if (db.changes() > 0) {
                const name = try titleText(req, f, year);
                try unlocks.append(req.arena, .{ .kind = "title", .id = "event_title", .name = name });
            }
        }
        rw.unlocks = unlocks.items;
        const text = try std.fmt.allocPrint(req.arena, "{s} is over. You gave {d}: tier {d} of 3{s} (+{d} salvage).", .{
            def.name.get(f), part.n, pay.tier, if (met) "" else ", goal missed", pay.salvage,
        });
        try model.pushEvent(req, pl.id, "event_reward", text, null, try fight.toJson(req.arena, rw), false);
    }
}

fn titleText(req: *Req, f: data.Faction, year: u16) HandlerError![]const u8 {
    const monthly = data.eventDef(.day_zero);
    return std.fmt.allocPrint(req.arena, "{s} {d}", .{ monthly.title.?.get(f), year });
}

/// The yearly titles a player holds, named for their side, oldest first.
pub fn titles(req: *Req, pid: i64, f: data.Faction) HandlerError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var years: std.ArrayList(u16) = .empty;
    {
        var st = try req.ctx.db.query("SELECT year FROM event_titles WHERE player_id = ? ORDER BY year", .{pid});
        defer st.finalize();
        while (try st.step()) try years.append(req.arena, @intCast(st.int(0)));
    }
    for (years.items) |y| try out.append(req.arena, try titleText(req, f, y));
    return out.items;
}

// --- Views -------------------------------------------------------------------------------------------------

pub const Brief = struct {
    id: i64,
    type: data.EventType,
    /// The swarm's archetype (Horde only).
    kind: ?[]const u8,
    starts_at: i64,
    ends_at: i64,
    target: u32,
    progress: u32,
    mine: u32,
};

pub fn kindOf(row: Row) ?[]const u8 {
    const s = row.active().swarm() orelse return null;
    return @tagName(s);
}

/// The short form the map banner needs, sent with every location poll.
pub fn brief(req: *Req, pid: i64) HandlerError!?Brief {
    const row = (try live(req)) orelse return null;
    return .{
        .id = row.id,
        .type = row.type,
        .kind = kindOf(row),
        .starts_at = row.starts_at,
        .ends_at = row.ends_at,
        .target = row.target,
        .progress = row.progress,
        .mine = try contribution(req, row.id, pid),
    };
}

pub const DistrictGoal = struct { id: []const u8, target: u32, progress: u32 };

/// The goal of the district `pid` stands in; its target is the one it will have if nobody has
/// contributed there yet.
pub fn districtGoal(req: *Req, row: Row, pid: i64) HandlerError!?DistrictGoal {
    const pos = req.ctx.live.position(pid, req.now) orelse return null;
    const id = try req.arena.dupe(u8, game.war.districtId(pos.lat, pos.lon).str());
    var st = try req.ctx.db.query("SELECT target, progress FROM world_event_district WHERE event_id = ? AND district = ?", .{ row.id, id });
    defer st.finalize();
    if (try st.step()) return .{ .id = id, .target = @intCast(st.int(0)), .progress = @intCast(st.int(1)) };
    const players = @max(1, try districtActive(req, id));
    return .{ .id = id, .target = gev.districtTarget(row.def(), players), .progress = 0 };
}

// --- Exchange purchases -------------------------------------------------------------------------------------

pub fn bought(req: *Req, event_id: i64, pid: i64, sku: []const u8) HandlerError!u32 {
    const n = try req.ctx.db.scalar("SELECT n FROM world_event_buys WHERE event_id = ? AND player_id = ? AND sku = ?", .{ event_id, pid, sku });
    return @intCast(n orelse 0);
}

pub fn recordBuy(req: *Req, event_id: i64, pid: i64, sku: []const u8) HandlerError!void {
    try req.ctx.db.run(
        "INSERT INTO world_event_buys(event_id, player_id, sku, n) VALUES(?,?,?,1) ON CONFLICT(event_id, player_id, sku) DO UPDATE SET n = n + 1",
        .{ event_id, pid, sku },
    );
}
