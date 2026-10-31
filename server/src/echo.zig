//! Echoes (DESIGN.md section 8): a snapshot of a real opposing player of similar level offered
//! near you, or a labelled Rogue build when there is none. Deterministic per player and 30-minute
//! window; held in memory only, because an Echo's position is a point near the player.

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("ctx.zig");
const model = @import("model.zig");
const live = @import("live.zig");
const snapshot = @import("snapshot.zig");
const worldevents = @import("worldevents.zig");

const data = game.data;
const rng_mod = game.rng;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;

pub const window_ms: i64 = 30 * 60 * 1000;
pub const chance: f64 = 0.5;
pub const min_level: u8 = 5;
pub const quiet_after_contact_ms: i64 = 2 * 60 * 60 * 1000;
pub const level_band: i32 = 3;

pub fn windowOf(now: i64) i64 {
    return @divFloor(now, window_ms);
}

/// True when the Echo is a snapshot of a player suspended after it was rolled.
pub fn sourceSuspended(req: *Req, e: live.Echo) HandlerError!bool {
    const src = e.source orelse return false;
    const banned = try req.ctx.db.scalar("SELECT banned_until > ? FROM players WHERE id = ?", .{ req.now, src });
    return banned != null and banned.? != 0;
}

/// The echo to show this player now, rolling it the first time the window is seen.
pub fn current(req: *Req, p: *const model.Player, pos: live.Pos) HandlerError!?live.Echo {
    const ctx = req.ctx;
    const window = windowOf(req.now);
    if (ctx.live.echoFor(p.id, window)) |e| {
        if (e.none) return null;
        // An Echo already rolled from someone suspended since is withdrawn.
        if (try sourceSuspended(req, e)) return null;
        return e;
    }

    var echo = live.Echo{ .owner = p.id, .window = window, .none = true, .expires_at = (window + 1) * window_ms };
    defer ctx.live.putEcho(echo) catch {};

    // Echo Week: Echoes come sooner after a real fight and more often.
    const em = game.events.rewardMods(try worldevents.activeAt(req, req.now), false);
    const quiet_ms = if (em.echo_quiet_ms > 0) em.echo_quiet_ms else quiet_after_contact_ms;
    if (p.level < min_level or req.now - p.last_pvp_at < quiet_ms) return null;
    var rng = rng_mod.derive(ctx.seed, .{ "echo", p.id, window });
    if (!rng.chance(if (em.echo_chance > 0) em.echo_chance else chance)) return null;

    const foe = p.fac().opposite();
    if (try pickSnapshot(req, foe, p.id, p.level, &rng)) |picked| {
        echo.source = picked.player_id;
        echo.build = picked.build;
        echo.rogue = false;
    } else {
        const lvl: i32 = std.math.clamp(@as(i32, p.level) + rng.intRange(-2, 2), 1, data.max_level);
        const roll = rng.float();
        const rarity: data.Rarity = if (roll < 0.6) .common else if (roll < 0.9) .uncommon else .rare;
        echo.build = snapshot.kitBuild(foe, @intCast(lvl), rarity);
        echo.rogue = true;
    }

    // Somewhere 80 to 250 m away in a hashed direction.
    const bearing = rng.range(0, 2 * std.math.pi);
    const dist = rng.range(80, 250);
    const dlat = dist * @cos(bearing) / 111_320.0;
    const dlon = dist * @sin(bearing) / (111_320.0 * @max(0.01, @cos(pos.lat * std.math.pi / 180.0)));
    echo.lat = std.math.clamp(pos.lat + dlat, -89.9, 89.9);
    echo.lon = pos.lon + dlon;
    echo.none = false;
    return echo;
}

/// A suspended player's snapshot is never served (the extra parameter is the current time).
pub const not_banned = " AND NOT EXISTS (SELECT 1 FROM players b WHERE b.id = snapshots.player_id AND b.banned_until > ?)";

/// A player who sent a simulated fix this recently is not offered as someone's Echo (the extra
/// parameter is the earliest `mock_at` that still counts: now minus `mock_recent_ms`).
pub const not_mocking = " AND NOT EXISTS (SELECT 1 FROM players m WHERE m.id = snapshots.player_id AND m.mock_at > ?)";
pub const mock_recent_ms: i64 = 10 * 60 * 1000;

const Picked = struct { player_id: i64, build: snapshot.Build };

fn pickSnapshot(req: *Req, faction: data.Faction, not_pid: i64, level: u8, rng: *rng_mod.Rng) HandlerError!?Picked {
    const lo = @as(i64, level) - level_band;
    const hi = @as(i64, level) + level_band;
    const db = &req.ctx.db;
    const count = (try db.scalar(
        "SELECT COUNT(*) FROM snapshots WHERE faction = ? AND player_id != ? AND level BETWEEN ? AND ?" ++ not_banned ++ not_mocking,
        .{ faction, not_pid, lo, hi, req.now, req.now - mock_recent_ms },
    )) orelse 0;
    if (count == 0) return null;
    const skip: i64 = rng.below(@intCast(@min(count, 1000)));
    var st = try db.query(
        "SELECT player_id, level, items, abilities FROM snapshots WHERE faction = ? AND player_id != ? AND level BETWEEN ? AND ? " ++ not_banned ++ not_mocking ++ " ORDER BY player_id LIMIT 1 OFFSET ?",
        .{ faction, not_pid, lo, hi, req.now, req.now - mock_recent_ms, skip },
    );
    defer st.finalize();
    if (!try st.step()) return null;
    return .{
        .player_id = st.int(0),
        .build = snapshot.Build.decode(faction, @intCast(st.int(1)), st.text(2), st.text(3)),
    };
}
