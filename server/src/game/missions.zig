//! Daily and weekly missions: the pool, deterministic selection, progress events, rewards.

const std = @import("std");
const data = @import("data.zig");
const progression = @import("progression.zig");
const rng_mod = @import("rng.zig");
const war = @import("war.zig");

pub const daily_count = 3;
pub const weekly_min_level = 5;
pub const streak_cap_days = 5;

pub const Kind = enum {
    defeat,
    defeat_elite,
    open_cache,
    walk,
    win_contact,
    use_consumable,
    upgrade_item,
    scrap_items,
    defeat_archetype,
};

pub const Template = struct {
    kind: Kind,
    min_target: u32,
    max_target: u32,
    /// Targets are rounded to a multiple of this (walks use 250 m).
    step: u32 = 1,
    min_level: u8,
    /// XP as ten times the number of standard wins at the player's level it is worth: 20 to 30
    /// for dailies by difficulty, 100 for weeklies.
    xp_k10: u8,
};

/// Gates keep every offered daily doable: Elites do not appear below level 5, Contacts and
/// Echoes begin at 5, and scrapping or upgrading needs spare gear, which takes until level 4.
pub const dailies = [_]Template{
    .{ .kind = .defeat, .min_target = 5, .max_target = 8, .min_level = 1, .xp_k10 = 25 },
    .{ .kind = .defeat_elite, .min_target = 1, .max_target = 1, .min_level = 5, .xp_k10 = 30 },
    .{ .kind = .open_cache, .min_target = 2, .max_target = 4, .min_level = 1, .xp_k10 = 20 },
    .{ .kind = .walk, .min_target = 1000, .max_target = 2000, .step = 250, .min_level = 1, .xp_k10 = 20 },
    .{ .kind = .win_contact, .min_target = 1, .max_target = 1, .min_level = 5, .xp_k10 = 30 },
    .{ .kind = .use_consumable, .min_target = 1, .max_target = 2, .min_level = 1, .xp_k10 = 20 },
    .{ .kind = .upgrade_item, .min_target = 1, .max_target = 1, .min_level = 4, .xp_k10 = 20 },
    .{ .kind = .scrap_items, .min_target = 3, .max_target = 5, .min_level = 4, .xp_k10 = 20 },
    .{ .kind = .defeat_archetype, .min_target = 3, .max_target = 5, .min_level = 1, .xp_k10 = 25 },
};

pub const weeklies = [_]Template{
    .{ .kind = .defeat, .min_target = 40, .max_target = 60, .step = 5, .min_level = 5, .xp_k10 = 100 },
    .{ .kind = .open_cache, .min_target = 12, .max_target = 20, .step = 2, .min_level = 5, .xp_k10 = 100 },
    .{ .kind = .walk, .min_target = 8000, .max_target = 12000, .step = 1000, .min_level = 5, .xp_k10 = 100 },
    .{ .kind = .win_contact, .min_target = 3, .max_target = 5, .min_level = 5, .xp_k10 = 100 },
    .{ .kind = .defeat_elite, .min_target = 3, .max_target = 5, .min_level = 5, .xp_k10 = 100 },
};

/// Archetypes a "defeat N of a kind" mission may ask for (the ones you meet often).
const target_archetypes = [_]data.Archetype{ .shambler, .runner, .bloater, .brute };
const target_archetype_weights = [_]f64{ 40, 20, 15, 12 };

pub const Id = struct {
    buf: [24]u8 = [_]u8{0} ** 24,
    len: u8 = 0,

    pub fn str(self: *const Id) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Mission = struct {
    weekly: bool,
    /// Day index (daily) or week index (weekly).
    period: i64,
    /// Position within the period's list.
    slot: u8,
    kind: Kind,
    target: u32,
    archetype: ?data.Archetype = null,
    xp_k10: u8,
    salvage: u32,
    /// Weekly missions guarantee an item of at least this rarity.
    item_min_rarity: ?data.Rarity = null,

    /// "d.20400.1" for the second daily of day 20400, "w.2870.0" for that week's mission.
    pub fn id(self: *const Mission) Id {
        var out = Id{};
        const s = std.fmt.bufPrint(&out.buf, "{c}.{d}.{d}", .{ @as(u8, if (self.weekly) 'w' else 'd'), self.period, self.slot }) catch unreachable;
        out.len = @intCast(s.len);
        return out;
    }

    pub fn text(self: *const Mission, faction: data.Faction, buf: []u8) []const u8 {
        const t = self.target;
        const s = switch (self.kind) {
            .defeat => std.fmt.bufPrint(buf, "Defeat {d} enemies", .{t}),
            .defeat_elite => if (t == 1)
                std.fmt.bufPrint(buf, "Defeat an elite enemy", .{})
            else
                std.fmt.bufPrint(buf, "Defeat {d} elite enemies", .{t}),
            .open_cache => std.fmt.bufPrint(buf, "Open {d} {s}", .{ t, if (faction == .human) "Supply Crates" else "Fresh Remains" }),
            .walk => std.fmt.bufPrint(buf, "Walk {d} metres", .{t}),
            .win_contact => if (t == 1)
                std.fmt.bufPrint(buf, "Win a Contact or an Echo", .{})
            else
                std.fmt.bufPrint(buf, "Win {d} Contacts or Echoes", .{t}),
            .use_consumable => std.fmt.bufPrint(buf, "Use {d} consumable{s}", .{ t, if (t == 1) "" else "s" }),
            .upgrade_item => std.fmt.bufPrint(buf, "Upgrade an item", .{}),
            .scrap_items => std.fmt.bufPrint(buf, "Scrap {d} items", .{t}),
            .defeat_archetype => std.fmt.bufPrint(buf, "Defeat {d} {s}s", .{ t, data.archetype(self.archetype.?).name.get(faction) }),
        } catch return "";
        return s;
    }
};

fn eligible(templates: []const Template, level: u32, out: []u8) usize {
    var n: usize = 0;
    for (templates, 0..) |t, i| {
        if (t.min_level <= level) {
            out[n] = @intCast(i);
            n += 1;
        }
    }
    return n;
}

fn instantiate(rng: *rng_mod.Rng, t: Template, weekly: bool, period: i64, slot: u8, level: u32) Mission {
    const span = (t.max_target - t.min_target) / t.step;
    const target = t.min_target + t.step * rng.below(span + 1);
    var m = Mission{
        .weekly = weekly,
        .period = period,
        .slot = slot,
        .kind = t.kind,
        .target = target,
        .xp_k10 = t.xp_k10,
        .salvage = if (weekly) 80 + 5 * level else 10 + level,
    };
    if (t.kind == .defeat_archetype) m.archetype = target_archetypes[rng.weighted(&target_archetype_weights)];
    if (weekly) m.item_min_rarity = .rare;
    return m;
}

/// The player's three daily missions for a UTC day: distinct kinds, gated by level, and the same
/// every time it is asked.
pub fn dailyMissions(player_id: u64, day: i64, level: u32) [daily_count]Mission {
    var rng = rng_mod.derive(player_id, .{ "dm", day });
    var pool: [dailies.len]u8 = undefined;
    var n = eligible(&dailies, level, &pool);
    var out: [daily_count]Mission = undefined;
    for (0..daily_count) |slot| {
        const pick = rng.below(@intCast(n));
        out[slot] = instantiate(&rng, dailies[pool[pick]], false, day, @intCast(slot), level);
        n -= 1;
        pool[pick] = pool[n];
    }
    return out;
}

/// The weekly mission, available from level 5.
pub fn weeklyMission(player_id: u64, week: i64, level: u32) ?Mission {
    if (level < weekly_min_level) return null;
    var rng = rng_mod.derive(player_id, .{ "wm", week });
    var pool: [weeklies.len]u8 = undefined;
    const n = eligible(&weeklies, level, &pool);
    return instantiate(&rng, weeklies[pool[rng.below(@intCast(n))]], true, week, 0, level);
}

/// The mission a stored id refers to, recomputed, or null if it is not one of the player's.
pub fn resolve(player_id: u64, id: []const u8, now_ms: i64, level: u32) ?Mission {
    var it = std.mem.splitScalar(u8, id, '.');
    const k = it.next() orelse return null;
    const period = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    const slot = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
    if (it.next() != null or k.len != 1) return null;
    if (k[0] == 'd') {
        if (slot >= daily_count or period != war.dayIndex(now_ms)) return null;
        return dailyMissions(player_id, period, level)[slot];
    }
    if (k[0] == 'w') {
        if (slot != 0 or period != war.weekIndex(now_ms)) return null;
        return weeklyMission(player_id, period, level);
    }
    return null;
}

pub fn dailyResetsAt(now_ms: i64) i64 {
    return (war.dayIndex(now_ms) + 1) * war.day_ms;
}

// --- Progress ---------------------------------------------------------------------------------------

pub const EventKind = enum { pve_win, cache_open, walk, contact_win, consumable_use, item_upgrade, item_scrap };

pub const Event = struct {
    kind: EventKind,
    /// Metres walked, items scrapped; 1 for everything else.
    amount: u32 = 1,
    archetype: ?data.Archetype = null,
    elite: bool = false,
};

/// How much a game event advances a mission.
pub fn progressDelta(m: Mission, ev: Event) u32 {
    return switch (m.kind) {
        .defeat => if (ev.kind == .pve_win) 1 else 0,
        .defeat_elite => if (ev.kind == .pve_win and ev.elite) 1 else 0,
        .open_cache => if (ev.kind == .cache_open) 1 else 0,
        .walk => if (ev.kind == .walk) ev.amount else 0,
        .win_contact => if (ev.kind == .contact_win) 1 else 0,
        .use_consumable => if (ev.kind == .consumable_use) 1 else 0,
        .upgrade_item => if (ev.kind == .item_upgrade) 1 else 0,
        .scrap_items => if (ev.kind == .item_scrap) ev.amount else 0,
        .defeat_archetype => if (ev.kind == .pve_win and ev.archetype == m.archetype) 1 else 0,
    };
}

// --- Rewards and streaks -------------------------------------------------------------------------------

pub const Reward = struct {
    xp: u32,
    salvage: u32,
    item_min_rarity: ?data.Rarity,
};

pub fn reward(m: Mission, level: u32, streak: u32) Reward {
    return .{
        .xp = progression.missionXp(level, m.xp_k10, if (m.weekly) 0 else streak),
        .salvage = m.salvage,
        .item_min_rarity = m.item_min_rarity,
    };
}

/// Finishing all three dailies in a day also grants this.
pub const all_dailies_bonus: data.Consumable = .heal_m;

/// Streak after claiming a daily on `today`, given the streak and the last day one was claimed.
/// Consecutive days extend it; a gap restarts it at 1; a second claim the same day changes nothing.
pub fn streakAfterClaim(streak: u32, last_claim_day: i64, today: i64) u32 {
    if (streak > 0 and last_claim_day == today) return streak;
    if (streak > 0 and last_claim_day == today - 1) return streak + 1;
    return 1;
}

/// The streak as shown today: it lapses to 0 once a full day has been missed.
pub fn streakShown(streak: u32, last_claim_day: i64, today: i64) u32 {
    return if (today - last_claim_day > 1) 0 else streak;
}

// --- Tests -------------------------------------------------------------------------------------------------

const testing = std.testing;

test "daily selection is deterministic, distinct and level gated" {
    for (0..200) |p| {
        const a = dailyMissions(p, 20400, 10);
        const b = dailyMissions(p, 20400, 10);
        try testing.expectEqualDeep(a, b);
        try testing.expect(a[0].kind != a[1].kind and a[1].kind != a[2].kind and a[0].kind != a[2].kind);
        for (a, 0..) |m, slot| {
            try testing.expectEqual(@as(u8, @intCast(slot)), m.slot);
            try testing.expect(!m.weekly and m.item_min_rarity == null);
        }
        // Level 1 to 3: nothing that needs spare gear, elites or other players.
        for (1..4) |lvl| {
            for (dailyMissions(p, 20400, @intCast(lvl))) |m| {
                try testing.expect(m.kind != .win_contact and m.kind != .upgrade_item and
                    m.kind != .scrap_items and m.kind != .defeat_elite);
            }
        }
        // Level 4: gear missions open, elites and Contacts still wait for 5.
        for (dailyMissions(p, 20400, 4)) |m| {
            try testing.expect(m.kind != .win_contact and m.kind != .defeat_elite);
        }
    }
    try testing.expect(!std.meta.eql(dailyMissions(1, 20400, 10)[0], dailyMissions(1, 20401, 10)[0]) or
        !std.meta.eql(dailyMissions(1, 20400, 10)[1], dailyMissions(1, 20401, 10)[1]));
}

test "targets stay in range and archetype missions name a real archetype" {
    var archetypes_seen = [_]bool{false} ** 7;
    for (0..500) |p| {
        for (dailyMissions(p, 1, 20)) |m| {
            const t = for (dailies) |t| {
                if (t.kind == m.kind) break t;
            } else unreachable;
            try testing.expect(m.target >= t.min_target and m.target <= t.max_target);
            try testing.expectEqual(@as(u32, 0), (m.target - t.min_target) % t.step);
            try testing.expect(m.xp_k10 >= 20 and m.xp_k10 <= 30);
            if (m.kind == .defeat_archetype) {
                archetypes_seen[@intFromEnum(m.archetype.?)] = true;
            } else try testing.expect(m.archetype == null);
        }
    }
    try testing.expect(archetypes_seen[0] and archetypes_seen[1] and archetypes_seen[2] and archetypes_seen[3]);
    try testing.expect(!archetypes_seen[4] and !archetypes_seen[5] and !archetypes_seen[6]);
}

test "weekly missions start at level 5 and promise a rare item" {
    try testing.expect(weeklyMission(1, 2870, 4) == null);
    const w = weeklyMission(1, 2870, 5).?;
    try testing.expect(w.weekly);
    try testing.expectEqual(@as(?data.Rarity, .rare), w.item_min_rarity);
    try testing.expectEqualDeep(w, weeklyMission(1, 2870, 5).?);
}

test "ids round trip through resolve; stale or foreign ids do not" {
    const now: i64 = 1_793_448_000_000;
    const day = war.dayIndex(now);
    const m = dailyMissions(77, day, 12)[2];
    const id = m.id();
    try testing.expectEqualStrings("d.20757.2", id.str()[0..9]);
    try testing.expectEqualDeep(m, resolve(77, id.str(), now, 12).?);
    try testing.expect(resolve(77, id.str(), now + war.day_ms, 12) == null);
    try testing.expect(resolve(77, "d.20757.3", now, 12) == null);
    try testing.expect(resolve(77, "x.1.1", now, 12) == null);
    try testing.expect(resolve(77, "junk", now, 12) == null);
    const w = weeklyMission(77, war.weekIndex(now), 12).?;
    const wid = w.id();
    try testing.expectEqualDeep(w, resolve(77, wid.str(), now, 12).?);
    try testing.expect(resolve(77, "w.1.0", now, 12) == null);
}

test "text mentions the target and uses faction names" {
    var buf: [96]u8 = undefined;
    var m = Mission{ .weekly = false, .period = 1, .slot = 0, .kind = .defeat_archetype, .target = 4, .archetype = .shambler, .xp_k10 = 20, .salvage = 5 };
    try testing.expectEqualStrings("Defeat 4 Shamblers", m.text(.human, &buf));
    try testing.expectEqualStrings("Defeat 4 Scavengers", m.text(.zombie, &buf));
    m.kind = .open_cache;
    try testing.expectEqualStrings("Open 4 Supply Crates", m.text(.human, &buf));
    try testing.expectEqualStrings("Open 4 Fresh Remains", m.text(.zombie, &buf));
    m.kind = .defeat_elite;
    m.target = 1;
    try testing.expectEqualStrings("Defeat an elite enemy", m.text(.human, &buf));
    m.kind = .walk;
    m.target = 1500;
    try testing.expectEqualStrings("Walk 1500 metres", m.text(.human, &buf));
    // Every template renders non-empty text.
    for (0..100) |p| {
        for (dailyMissions(p, 5, 30)) |mm| try testing.expect(mm.text(.zombie, &buf).len > 5);
    }
}

test "progress events advance the right missions" {
    const base = Mission{ .weekly = false, .period = 1, .slot = 0, .kind = .defeat, .target = 5, .xp_k10 = 20, .salvage = 5 };
    var m = base;
    try testing.expectEqual(@as(u32, 1), progressDelta(m, .{ .kind = .pve_win }));
    try testing.expectEqual(@as(u32, 0), progressDelta(m, .{ .kind = .cache_open }));
    m.kind = .defeat_elite;
    try testing.expectEqual(@as(u32, 0), progressDelta(m, .{ .kind = .pve_win }));
    try testing.expectEqual(@as(u32, 1), progressDelta(m, .{ .kind = .pve_win, .elite = true }));
    m.kind = .walk;
    try testing.expectEqual(@as(u32, 300), progressDelta(m, .{ .kind = .walk, .amount = 300 }));
    m.kind = .scrap_items;
    try testing.expectEqual(@as(u32, 3), progressDelta(m, .{ .kind = .item_scrap, .amount = 3 }));
    m.kind = .defeat_archetype;
    m.archetype = .brute;
    try testing.expectEqual(@as(u32, 1), progressDelta(m, .{ .kind = .pve_win, .archetype = .brute }));
    try testing.expectEqual(@as(u32, 0), progressDelta(m, .{ .kind = .pve_win, .archetype = .runner }));
    m.kind = .win_contact;
    try testing.expectEqual(@as(u32, 1), progressDelta(m, .{ .kind = .contact_win }));
    m.kind = .use_consumable;
    try testing.expectEqual(@as(u32, 1), progressDelta(m, .{ .kind = .consumable_use }));
    m.kind = .upgrade_item;
    try testing.expectEqual(@as(u32, 1), progressDelta(m, .{ .kind = .item_upgrade }));
    m.kind = .open_cache;
    try testing.expectEqual(@as(u32, 1), progressDelta(m, .{ .kind = .cache_open }));
}

test "rewards scale with level and streak" {
    const m = Mission{ .weekly = false, .period = 1, .slot = 0, .kind = .defeat, .target = 5, .xp_k10 = 20, .salvage = 20 };
    // L1 standard win = 26 XP; k 2.0 -> 52; streak 5 -> x1.5 = 78
    try testing.expectEqual(@as(u32, 52), reward(m, 1, 0).xp);
    try testing.expectEqual(@as(u32, 78), reward(m, 1, 5).xp);
    try testing.expectEqual(@as(u32, 78), reward(m, 1, 50).xp);
    var w = m;
    w.weekly = true;
    w.xp_k10 = 100;
    try testing.expectEqual(@as(u32, 260), reward(w, 1, 5).xp);
    // Never a token amount: every daily pays at least two standard wins at every level.
    for (1..51) |lvl| {
        for (0..40) |p| {
            for (dailyMissions(p, 3, @intCast(lvl))) |dm| {
                try testing.expect(reward(dm, @intCast(lvl), 0).xp >= 2 * progression.pveWinXp(@intCast(lvl), .normal, 1.0));
            }
        }
    }
}

test "streaks extend on consecutive days and lapse after a gap" {
    try testing.expectEqual(@as(u32, 1), streakAfterClaim(0, 0, 100));
    try testing.expectEqual(@as(u32, 4), streakAfterClaim(3, 99, 100));
    try testing.expectEqual(@as(u32, 3), streakAfterClaim(3, 100, 100));
    try testing.expectEqual(@as(u32, 1), streakAfterClaim(3, 97, 100));
    try testing.expectEqual(@as(u32, 3), streakShown(3, 99, 100));
    try testing.expectEqual(@as(u32, 0), streakShown(3, 98, 100));
    try testing.expectEqual(@as(i64, 20758 * war.day_ms), dailyResetsAt(1_793_448_000_000));
}
