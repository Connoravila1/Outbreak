//! Levels, XP, titles, unlocks, and the XP formulas for every source.

const std = @import("std");
const data = @import("data.zig");

const Faction = data.Faction;
pub const max_level = data.max_level;

// --- The XP curve (tuned with the simulator; DESIGN.md section 5) -----------------------------

pub const curve_scale = 5.1;
pub const curve_power = 2.65;
pub const curve_offset = 440.0;

/// XP needed to go from level `level` to `level + 1`.
/// The first four levels come quickly so a new player levels within a few fights; their sum
/// matches what the curve alone would ask, so later pacing is unchanged.
const early_xp = [_]u32{ 100, 430, 700, 780 };

pub fn xpToNext(level: u32) u32 {
    if (level >= 1 and level <= early_xp.len) return early_xp[level - 1];
    const l: f64 = @floatFromInt(level);
    const raw = curve_scale * std.math.pow(f64, l, curve_power) + curve_offset;
    return @intFromFloat(@round(raw / 10.0) * 10.0);
}

pub const LevelResult = struct {
    level: u8,
    /// XP into the new level. Zero at the level cap.
    xp: u32,
    levels_gained: u8,
};

/// Add `gained` XP, levelling up as many times as it pays for. At the cap, XP is discarded.
pub fn applyXp(level: u8, xp: u32, gained: u32) LevelResult {
    var l: u8 = level;
    var have: u64 = @as(u64, xp) + gained;
    while (l < max_level and have >= xpToNext(l)) {
        have -= xpToNext(l);
        l += 1;
    }
    if (l >= max_level) have = 0;
    return .{ .level = l, .xp = @intCast(have), .levels_gained = l - level };
}

// --- Titles, unlocks, slots --------------------------------------------------------------------

pub fn title(faction: Faction, level: u32) []const u8 {
    const i = @min(level / 5, data.titles.human.len - 1);
    return switch (faction) {
        .human => data.titles.human[i],
        .zombie => data.titles.zombie[i],
    };
}

/// Unlock texts for levels `from + 1 ..= to`, written to `out`; returns how many.
pub fn unlockTexts(from: u32, to: u32, out: [][]const u8) usize {
    var n: usize = 0;
    for (data.unlocks) |u| {
        if (u.level > from and u.level <= to and n < out.len) {
            out[n] = u.text;
            n += 1;
        }
    }
    return n;
}

pub fn abilitySlots(level: u32) u8 {
    if (level >= 25) return 3;
    if (level >= 12) return 2;
    if (level >= 3) return 1;
    return 0;
}

/// Abilities a player of this faction has unlocked at `level`, in unlock order.
pub fn unlockedAbilities(faction: Faction, level: u32, out: *[7]data.Ability) []const data.Ability {
    var n: usize = 0;
    for (data.abilities) |a| {
        if (a.faction == faction and a.level <= level) {
            out[n] = a.id;
            n += 1;
        }
    }
    return out[0..n];
}

pub const base_inventory: u32 = 30;
pub const inventory_per_level: u32 = 2;
pub const inventory_level_cap: u32 = 130;
pub const expansion_slots: u32 = 10;

/// 30 slots at level 1, +2 per level (capped at 130), +10 per store expansion bought.
pub fn inventoryCap(level: u32, expansions: u32) u32 {
    const from_levels = @min(inventory_level_cap, base_inventory + inventory_per_level * (level - 1));
    return from_levels + expansion_slots * expansions;
}

pub const pvp_min_level: u32 = 5;
pub const pvp_level_band: u32 = 12;
pub const pvp_band_exempt_level: u32 = 30;

/// New players cannot be matched for real-world fights until level 5.
pub fn pvpProtected(level: u32) bool {
    return level < pvp_min_level;
}

/// Level conditions for a Contact: both past protection, within +-12, or the lower one is 30+.
pub fn pvpLevelsMatch(a: u32, b: u32) bool {
    if (pvpProtected(a) or pvpProtected(b)) return false;
    const lo = @min(a, b);
    const hi = @max(a, b);
    return hi - lo <= pvp_level_band or lo >= pvp_band_exempt_level;
}

// --- XP sources ---------------------------------------------------------------------------------

pub const EnemyClass = enum { normal, elite, boss };

/// XP for beating an enemy of level `e`: 20 + 6E, x1.5 elite, x4 boss, x the archetype's
/// reward multiplier (Horde 1.5).
pub fn pveWinXp(e: u32, class: EnemyClass, reward_mult: f32) u32 {
    const base: f32 = @floatFromInt(20 + 6 * e);
    const cls: f32 = switch (class) {
        .normal => 1.0,
        .elite => 1.5,
        .boss => 4.0,
    };
    return @intFromFloat(@round(base * cls * reward_mult));
}

pub fn lossXp(win_xp: u32, fraction: f32) u32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(win_xp)) * fraction));
}

pub const pve_loss_fraction = 0.25;
pub const pvp_loss_fraction = 0.30;

pub fn pveLossXp(win_xp: u32) u32 {
    return lossXp(win_xp, pve_loss_fraction);
}

pub fn cacheXp(level: u32) u32 {
    return 10 + 2 * level;
}

pub fn pvpWinXp(opp_level: u32) u32 {
    return 60 + 10 * opp_level;
}

pub fn pvpLossXp(opp_level: u32) u32 {
    return lossXp(pvpWinXp(opp_level), pvp_loss_fraction);
}

pub fn echoWinXp(echo_level: u32) u32 {
    return 40 + 7 * echo_level;
}

pub const walk_metres_per_xp: u32 = 20;
pub const walk_xp_daily_cap: u32 = 300;
pub const walk_max_speed_ms = 7.0;

/// Walking XP for `metres` covered, given what has already been earned today. Callers only
/// pass distance covered at <= 7 m/s.
pub fn walkXp(metres: u32, earned_today: u32) u32 {
    const room = walk_xp_daily_cap -| earned_today;
    return @min(room, metres / walk_metres_per_xp);
}

/// Weekly missions pay this many standard wins' worth of XP (dailies pay 2 to 3).
pub const weekly_xp_k10: u32 = 100;
pub const streak_step = 0.10;
pub const streak_cap = 0.50;

pub fn streakBonus(streak: u32) f32 {
    return @min(streak_cap, streak_step * @as(f32, @floatFromInt(streak)));
}

/// XP for a mission worth `k10 / 10` standard wins at the player's own level (k10 = 25 pays
/// 2.5 wins), with the streak bonus. Scales with level the way fights do, so a mission is never
/// worth a rounding error.
pub fn missionXp(level: u32, k10: u32, streak: u32) u32 {
    const win: f32 = @floatFromInt(pveWinXp(level, .normal, 1.0));
    const base = win * @as(f32, @floatFromInt(k10)) / 10.0;
    return @intFromFloat(@round(base * (1.0 + streakBonus(streak))));
}

pub const underdog_cap = 0.25;

/// Underdog XP bonus for the faction with share `own` of active players this week, against
/// `other`. min(25%, gap * 50%) for the smaller side, zero for the larger.
pub fn underdogBonus(own: f32, other: f32) f32 {
    if (own >= other) return 0;
    return @min(underdog_cap, (other - own) * 0.5);
}

pub const XpBonuses = struct {
    underdog: f32 = 0,
    buff_xp: bool = false,
    boost: bool = false,
    /// +10% in a district your faction won last week.
    district: bool = false,
    /// +5% (3+ adjacent strongholds) or +10% (6+); pass the fraction.
    adjacency: f32 = 0,
};

/// Total XP multiplier from all bonuses; they add rather than multiply.
pub fn xpMultiplier(b: XpBonuses) f32 {
    var m: f32 = 1.0 + b.underdog + b.adjacency;
    if (b.buff_xp) m += 0.25;
    if (b.boost) m += 0.50;
    if (b.district) m += 0.10;
    return m;
}

test "xp curve is monotonic, rounded to 10, and matches hand values" {
    var prev: u32 = 0;
    var l: u32 = 1;
    while (l <= 50) : (l += 1) {
        const x = xpToNext(l);
        try std.testing.expect(x > prev);
        try std.testing.expectEqual(@as(u32, 0), x % 10);
        prev = x;
    }
    try std.testing.expectEqual(@as(u32, 100), xpToNext(1));
}

test "multi-level xp and the cap" {
    const r = applyXp(1, 0, xpToNext(1) + xpToNext(2) + 5);
    try std.testing.expectEqual(@as(u8, 3), r.level);
    try std.testing.expectEqual(@as(u32, 5), r.xp);
    try std.testing.expectEqual(@as(u8, 2), r.levels_gained);
    const stay = applyXp(1, 0, xpToNext(1) - 1);
    try std.testing.expectEqual(@as(u8, 1), stay.level);
    try std.testing.expectEqual(xpToNext(1) - 1, stay.xp);
    const top = applyXp(49, 0, 10_000_000);
    try std.testing.expectEqual(@as(u8, 50), top.level);
    try std.testing.expectEqual(@as(u32, 0), top.xp);
    try std.testing.expectEqual(@as(u8, 0), applyXp(50, 0, 999).levels_gained);
}

test "titles every five levels" {
    try std.testing.expectEqualStrings("Survivor", title(.human, 1));
    try std.testing.expectEqualStrings("Survivor", title(.human, 4));
    try std.testing.expectEqualStrings("Scavenger", title(.human, 5));
    try std.testing.expectEqualStrings("Last Hope", title(.human, 50));
    try std.testing.expectEqualStrings("Turned", title(.zombie, 1));
    try std.testing.expectEqualStrings("Alpha", title(.zombie, 34));
    try std.testing.expectEqualStrings("Patient Zero", title(.zombie, 50));
}

test "unlock tables" {
    var buf: [8][]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), unlockTexts(1, 2, &buf));
    try std.testing.expectEqualStrings("The Store", buf[0]);
    try std.testing.expectEqual(@as(usize, 0), unlockTexts(5, 6, &buf));
    try std.testing.expectEqual(@as(usize, 3), unlockTexts(2, 5, &buf));
    try std.testing.expectEqual(@as(usize, 0), abilitySlots(2));
    try std.testing.expectEqual(@as(usize, 1), abilitySlots(3));
    try std.testing.expectEqual(@as(usize, 1), abilitySlots(11));
    try std.testing.expectEqual(@as(usize, 2), abilitySlots(12));
    try std.testing.expectEqual(@as(usize, 2), abilitySlots(24));
    try std.testing.expectEqual(@as(usize, 3), abilitySlots(25));
    var ab: [7]data.Ability = undefined;
    try std.testing.expectEqual(@as(usize, 0), unlockedAbilities(.human, 2, &ab).len);
    try std.testing.expectEqual(@as(usize, 3), unlockedAbilities(.zombie, 17, &ab).len);
    try std.testing.expectEqual(data.Ability.pounce, unlockedAbilities(.zombie, 17, &ab)[1]);
    try std.testing.expectEqual(@as(usize, 7), unlockedAbilities(.human, 50, &ab).len);
}

test "inventory capacity" {
    try std.testing.expectEqual(@as(u32, 30), inventoryCap(1, 0));
    try std.testing.expectEqual(@as(u32, 32), inventoryCap(2, 0));
    try std.testing.expectEqual(@as(u32, 128), inventoryCap(50, 0));
    try std.testing.expectEqual(@as(u32, 148), inventoryCap(50, 2));
}

test "pvp protection and level bands" {
    try std.testing.expect(pvpProtected(4));
    try std.testing.expect(!pvpProtected(5));
    try std.testing.expect(!pvpLevelsMatch(4, 6));
    try std.testing.expect(pvpLevelsMatch(5, 17));
    try std.testing.expect(!pvpLevelsMatch(5, 18));
    try std.testing.expect(!pvpLevelsMatch(20, 33));
    try std.testing.expect(pvpLevelsMatch(30, 50));
}

test "xp sources" {
    try std.testing.expectEqual(@as(u32, 20 + 60), pveWinXp(10, .normal, 1.0));
    try std.testing.expectEqual(@as(u32, 120), pveWinXp(10, .elite, 1.0));
    try std.testing.expectEqual(@as(u32, 320), pveWinXp(10, .boss, 1.0));
    try std.testing.expectEqual(@as(u32, 120), pveWinXp(10, .normal, 1.5));
    try std.testing.expectEqual(@as(u32, 20), pveLossXp(80));
    try std.testing.expectEqual(@as(u32, 30), cacheXp(10));
    try std.testing.expectEqual(@as(u32, 160), pvpWinXp(10));
    try std.testing.expectEqual(@as(u32, 48), pvpLossXp(10));
    try std.testing.expectEqual(@as(u32, 110), echoWinXp(10));
    try std.testing.expectEqual(@as(u32, 5), walkXp(100, 0));
    try std.testing.expectEqual(@as(u32, 20), walkXp(1000, 280));
    try std.testing.expectEqual(@as(u32, 0), walkXp(1000, 300));
}

test "mission xp, streak, underdog, multipliers" {
    try std.testing.expectApproxEqAbs(0.3, streakBonus(3), 1e-6);
    try std.testing.expectApproxEqAbs(0.5, streakBonus(40), 1e-6);
    // L1 standard win = 26 XP; k 2.0 -> 52, streak 5 -> x1.5 = 78; k 2.5 -> 65
    try std.testing.expectEqual(@as(u32, 52), missionXp(1, 20, 0));
    try std.testing.expectEqual(@as(u32, 78), missionXp(1, 20, 5));
    try std.testing.expectEqual(@as(u32, 65), missionXp(1, 25, 0));
    // L10: win = 80; weekly k 10 -> 800
    try std.testing.expectEqual(@as(u32, 800), missionXp(10, weekly_xp_k10, 0));
    try std.testing.expectApproxEqAbs(0.05, underdogBonus(0.45, 0.55), 1e-5);
    try std.testing.expectApproxEqAbs(0.25, underdogBonus(0.1, 0.9), 1e-6);
    try std.testing.expectEqual(@as(f32, 0), underdogBonus(0.6, 0.4));
    try std.testing.expectApproxEqAbs(1.95, xpMultiplier(.{ .underdog = 0.1, .buff_xp = true, .boost = true, .district = true }), 1e-6);
}
