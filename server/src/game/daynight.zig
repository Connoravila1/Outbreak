//! Day and night (DESIGN.md section 7): local solar time from longitude, and what the phase
//! changes. Pure functions of (unix ms, longitude); nothing is stored.

const std = @import("std");
const data = @import("data.zig");

pub const night_start_hour = 20.0;
pub const night_end_hour = 6.0;
const hour_ms = 60 * 60 * 1000;
const day_ms = 24 * hour_ms;

/// Night: Zombies hit harder, enemies facing Humans are tougher and more numerous, and the
/// risk pays Humans more XP. Day mirrors it.
pub const night_zombie_atk = 0.10;
pub const day_human_def = 0.10;
pub const night_enemy_stats = 0.10;
pub const night_enemy_spawns = 0.25;
pub const night_human_pve_xp = 0.15;
pub const day_zombie_pve_xp = 0.15;

pub const Phase = enum { day, night };

/// Local mean solar time as milliseconds into the day, in [0, 86 400 000). Integer arithmetic, so
/// phase boundaries are exact.
fn solarMs(now_ms: i64, lon: f64) i64 {
    const offset_ms: i64 = @intFromFloat(@round(lon / 15.0 * hour_ms));
    return @mod(now_ms + offset_ms, day_ms);
}

/// Local mean solar hour in [0, 24): `(utc_hour + lon / 15) mod 24`.
pub fn solarHour(now_ms: i64, lon: f64) f64 {
    return @as(f64, @floatFromInt(solarMs(now_ms, lon))) / hour_ms;
}

pub fn isNightHour(hour: f64) bool {
    return hour >= night_start_hour or hour < night_end_hour;
}

pub fn phaseAt(now_ms: i64, lon: f64) Phase {
    const m = solarMs(now_ms, lon);
    return if (m >= night_start_hour * hour_ms or m < night_end_hour * hour_ms) .night else .day;
}

pub fn isNight(now_ms: i64, lon: f64) bool {
    return phaseAt(now_ms, lon) == .night;
}

/// Unix ms of the next phase change at this longitude (06:00 or 20:00 solar).
pub fn changesAt(now_ms: i64, lon: f64) i64 {
    const m = solarMs(now_ms, lon);
    const dawn: i64 = night_end_hour * hour_ms;
    const dusk: i64 = night_start_hour * hour_ms;
    const target: i64 = if (m < dawn) dawn else if (m < dusk) dusk else dawn + day_ms;
    return now_ms + (target - m);
}

/// Extra fraction on a player's ATK and DEF from the phase.
pub const PlayerEffect = struct { atk: f32 = 0, def: f32 = 0 };

pub fn playerEffect(faction: data.Faction, night: bool) PlayerEffect {
    return switch (faction) {
        .zombie => if (night) .{ .atk = night_zombie_atk } else .{},
        .human => if (night) .{} else .{ .def = day_human_def },
    };
}

/// Multiplier on the HP, ATK and DEF of PvE enemies a `viewer` meets.
pub fn enemyMult(viewer: data.Faction, night: bool) f32 {
    return if (viewer == .human and night) 1.0 + night_enemy_stats else 1.0;
}

/// Multiplier on PvE XP.
pub fn pveXpMult(faction: data.Faction, night: bool) f32 {
    return switch (faction) {
        .human => if (night) 1.0 + night_human_pve_xp else 1.0,
        .zombie => if (night) 1.0 else 1.0 + day_zombie_pve_xp,
    };
}

/// Chance of one extra enemy in a cell at night for Humans: 25% of the cell's mean count.
pub fn extraSpawnChance(mean_per_cell: f64) f64 {
    return night_enemy_spawns * mean_per_cell;
}

// --- Tests ---------------------------------------------------------------------------------------

const testing = std.testing;

fn at(utc_hour: f64) i64 {
    return @intFromFloat(utc_hour * hour_ms);
}

test "solar hour follows longitude and wraps" {
    // Greenwich: solar = UTC.
    try testing.expectApproxEqAbs(12.0, solarHour(at(12), 0), 1e-9);
    // 90 E is six hours ahead, 90 W six behind.
    try testing.expectApproxEqAbs(18.0, solarHour(at(12), 90), 1e-9);
    try testing.expectApproxEqAbs(6.0, solarHour(at(12), -90), 1e-9);
    // Wraps over midnight in both directions, and over whole days.
    try testing.expectApproxEqAbs(2.0, solarHour(at(22), 60), 1e-9);
    try testing.expectApproxEqAbs(22.0, solarHour(at(2), -60), 1e-9);
    try testing.expectApproxEqAbs(12.0, solarHour(at(12) + 40 * day_ms, 0), 1e-9);
    // The antimeridian: 180 E and 180 W are twelve hours from Greenwich either way.
    try testing.expectApproxEqAbs(12.0, solarHour(at(0), 180), 1e-9);
    try testing.expectApproxEqAbs(12.0, solarHour(at(0), -180), 1e-9);
    // Before 1970 still lands in range.
    const h = solarHour(-1, -179.9);
    try testing.expect(h >= 0 and h < 24);
}

test "night runs 20:00 to 06:00, boundaries included on the right side" {
    try testing.expect(!isNightHour(6.0));
    try testing.expect(isNightHour(5.999));
    try testing.expect(!isNightHour(19.999));
    try testing.expect(isNightHour(20.0));
    try testing.expect(isNightHour(0.0));
    try testing.expect(isNightHour(23.999));
    try testing.expectEqual(Phase.day, phaseAt(at(12), 0));
    try testing.expectEqual(Phase.night, phaseAt(at(23), 0));
    // New York (74 W) is 5 h behind: 01:00 UTC is 20:04 local, night; 00:55 UTC is day.
    try testing.expectEqual(Phase.night, phaseAt(at(1), -74));
    try testing.expectEqual(Phase.day, phaseAt(at(0.9), -74));
    // The same instant is night in one place and day in another.
    try testing.expect(isNight(at(2), 0) and !isNight(at(2), 150));
}

test "the next change is at 06:00 or 20:00 local" {
    // 12:00 at Greenwich: night falls in 8 h.
    try testing.expectEqual(at(20), changesAt(at(12), 0));
    // 23:00: dawn in 7 h, across midnight.
    try testing.expectEqual(at(30), changesAt(at(23), 0));
    // 03:00: dawn in 3 h.
    try testing.expectEqual(at(6), changesAt(at(3), 0));
    // Exactly at a boundary the new phase is current and the next change is the other one.
    try testing.expectEqual(at(20) + 10 * hour_ms, changesAt(at(20), 0));
    try testing.expectEqual(at(6) + 14 * hour_ms, changesAt(at(6), 0));
    // Longitude shifts it: at 90 W it is 06:00 local at 12:00 UTC.
    try testing.expectEqual(at(12), changesAt(at(11), -90));
    // Whatever the instant, the change is in the future and flips the phase.
    var t: i64 = 0;
    while (t < 3 * day_ms) : (t += 37 * 60 * 1000 + 11) {
        for ([_]f64{ -179.5, -74, 0, 13.4, 151.2, 179.9 }) |lon| {
            const c = changesAt(t, lon);
            try testing.expect(c > t and c - t <= 14 * hour_ms + 1);
            try testing.expect(isNight(t, lon) != isNight(c, lon));
            try testing.expect(isNight(t, lon) == isNight(c - 1, lon));
        }
    }
}

test "phase effects" {
    try testing.expectEqual(PlayerEffect{ .atk = 0.10 }, playerEffect(.zombie, true));
    try testing.expectEqual(PlayerEffect{}, playerEffect(.zombie, false));
    try testing.expectEqual(PlayerEffect{ .def = 0.10 }, playerEffect(.human, false));
    try testing.expectEqual(PlayerEffect{}, playerEffect(.human, true));
    try testing.expectApproxEqAbs(1.10, enemyMult(.human, true), 1e-6);
    try testing.expectEqual(@as(f32, 1.0), enemyMult(.human, false));
    try testing.expectEqual(@as(f32, 1.0), enemyMult(.zombie, true));
    try testing.expectApproxEqAbs(1.15, pveXpMult(.human, true), 1e-6);
    try testing.expectEqual(@as(f32, 1.0), pveXpMult(.human, false));
    try testing.expectApproxEqAbs(1.15, pveXpMult(.zombie, false), 1e-6);
    try testing.expectEqual(@as(f32, 1.0), pveXpMult(.zombie, true));
    try testing.expectApproxEqAbs(0.1375, extraSpawnChance(0.55), 1e-9);
}
