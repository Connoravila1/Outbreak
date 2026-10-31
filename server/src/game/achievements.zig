//! Achievements (DESIGN.md section 17): milestones over counters the server already keeps. Pure: the
//! caller gathers a `Metrics` snapshot and gets back which achievements it satisfies. Each pays a
//! little salvage once; some also grant a title or unlock a cosmetic (cosmetics.zig).

const std = @import("std");
const data = @import("data.zig");

const Pair = data.Pair;

/// What an achievement counts. Most come straight from the player row; the ones in `Counter` are
/// kept in their own table; the rest are counted from what the player holds.
pub const Metric = enum {
    distance_m,
    pve_wins,
    elites,
    raid_hits,
    raid_kills,
    contacts_won,
    echoes_won,
    caches,
    airdrops,
    landmarks,
    notes_found,
    sets_claimed,
    level,
    /// The best rarity the player has ever held: 1 common .. 4 legendary (0: nothing yet).
    best_rarity,
    uniques_found,
    bases_found,
    best_upgrade,
    missions,
    best_streak,
    war_points,
    days,
};

/// The metrics stored as running counters, one row each (key: the tag name).
pub const Counter = enum {
    pve_wins,
    elites,
    raid_hits,
    raid_kills,
    airdrops,
    landmarks,
    missions,
    war_points,
    /// The two below keep the highest value seen instead of a sum.
    best_upgrade,
    best_streak,

    pub fn isMax(self: Counter) bool {
        return self == .best_upgrade or self == .best_streak;
    }

    pub fn metric(self: Counter) Metric {
        return std.meta.stringToEnum(Metric, @tagName(self)).?;
    }
};

pub const Metrics = std.EnumArray(Metric, u64);

pub const Achievement = struct {
    id: []const u8,
    /// Heading in the list (consecutive rows with the same group sit together).
    group: []const u8,
    name: Pair,
    text: []const u8,
    metric: Metric,
    need: u64,
    salvage: u32,
    /// A cosmetic title, shown with the ones from note sets.
    title: ?Pair = null,
    /// A cosmetic (cosmetics.zig id) that this achievement unlocks.
    cosmetic: ?[]const u8 = null,
};

const km = 1000;

fn pair(human: []const u8, zombie: []const u8) Pair {
    return .{ .human = human, .zombie = zombie };
}

/// Order is display order. At most 64 (the server keeps the earned ones in a bit set).
pub const list = [_]Achievement{
    // On foot
    .{ .id = "walk_1", .group = "On foot", .name = pair("First Steps", "First Shamble"), .text = "Walk 1 km.", .metric = .distance_m, .need = 1 * km, .salvage = 20 },
    .{ .id = "walk_10", .group = "On foot", .name = pair("Footslogger", "Restless Legs"), .text = "Walk 10 km.", .metric = .distance_m, .need = 10 * km, .salvage = 60 },
    .{ .id = "walk_100", .group = "On foot", .name = pair("Long Haul", "No Rest"), .text = "Walk 100 km.", .metric = .distance_m, .need = 100 * km, .salvage = 250, .title = pair("Wayfarer", "Drifter") },
    // The fight
    .{ .id = "wins_1", .group = "The fight", .name = pair("First Kill", "First Taste"), .text = "Win a fight against an enemy.", .metric = .pve_wins, .need = 1, .salvage = 10 },
    .{ .id = "wins_25", .group = "The fight", .name = pair("Getting Good", "Fed"), .text = "Win 25 fights against enemies.", .metric = .pve_wins, .need = 25, .salvage = 40 },
    .{ .id = "wins_250", .group = "The fight", .name = pair("Clearing the Block", "Full Belly"), .text = "Win 250 fights against enemies.", .metric = .pve_wins, .need = 250, .salvage = 200 },
    .{ .id = "elite_1", .group = "The fight", .name = pair("Gold Ring", "Marked Prey"), .text = "Defeat an elite.", .metric = .elites, .need = 1, .salvage = 30 },
    .{ .id = "elite_25", .group = "The fight", .name = pair("Giant-Killer", "Marrow Cracker"), .text = "Defeat 25 elites.", .metric = .elites, .need = 25, .salvage = 150, .title = pair("Giant-Killer", "Marrow Cracker") },
    .{ .id = "raid_1", .group = "The fight", .name = pair("Into the Teeth", "Into the Light"), .text = "Strike a raid boss.", .metric = .raid_hits, .need = 1, .salvage = 40 },
    .{ .id = "raid_kill", .group = "The fight", .name = pair("Abomination Down", "The Warlord Falls"), .text = "Help bring down a raid boss.", .metric = .raid_kills, .need = 1, .salvage = 150, .title = pair("Horde-Breaker", "Warlord's End") },
    // Contact
    .{ .id = "contact_1", .group = "Contact", .name = pair("Blooded", "First Blood Drawn"), .text = "Win a Contact.", .metric = .contacts_won, .need = 1, .salvage = 40 },
    .{ .id = "contact_10", .group = "Contact", .name = pair("Known Quantity", "A Name They Fear"), .text = "Win 10 Contacts.", .metric = .contacts_won, .need = 10, .salvage = 120 },
    .{ .id = "contact_50", .group = "Contact", .name = pair("Close Quarters", "Close Hunt"), .text = "Win 50 Contacts.", .metric = .contacts_won, .need = 50, .salvage = 300, .title = pair("Close Quarters", "Close Hunt") },
    .{ .id = "echo_1", .group = "Contact", .name = pair("Hearing Voices", "Old Footsteps"), .text = "Beat an Echo.", .metric = .echoes_won, .need = 1, .salvage = 25 },
    .{ .id = "echo_25", .group = "Contact", .name = pair("Ghost Hunter", "Ghost Eater"), .text = "Beat 25 Echoes.", .metric = .echoes_won, .need = 25, .salvage = 100 },
    // Out in the world
    .{ .id = "cache_25", .group = "Out in the world", .name = pair("Scavenger", "Nose Down"), .text = "Open 25 caches, airdrops or places.", .metric = .caches, .need = 25, .salvage = 50 },
    .{ .id = "cache_150", .group = "Out in the world", .name = pair("Picked Clean", "Nothing Left"), .text = "Open 150 caches, airdrops or places.", .metric = .caches, .need = 150, .salvage = 200 },
    .{ .id = "airdrop_1", .group = "Out in the world", .name = pair("Special Delivery", "Dropped In"), .text = "Open an airdrop.", .metric = .airdrops, .need = 1, .salvage = 30 },
    .{ .id = "place_1", .group = "Out in the world", .name = pair("Turn It Over", "Ransacked"), .text = "Search a real place on the map.", .metric = .landmarks, .need = 1, .salvage = 30 },
    .{ .id = "place_25", .group = "Out in the world", .name = pair("Local Knowledge", "Every Door"), .text = "Search 25 real places.", .metric = .landmarks, .need = 25, .salvage = 120 },
    // Found notes
    .{ .id = "notes_10", .group = "What was left", .name = pair("Reader", "Page Chewer"), .text = "Find 10 notes.", .metric = .notes_found, .need = 10, .salvage = 50 },
    .{ .id = "set_1", .group = "What was left", .name = pair("Complete Set", "Whole Story"), .text = "Claim a finished set of notes.", .metric = .sets_claimed, .need = 1, .salvage = 100 },
    .{ .id = "set_4", .group = "What was left", .name = pair("Archivist", "Page-Eater"), .text = "Claim four finished sets of notes.", .metric = .sets_claimed, .need = 4, .salvage = 300, .title = pair("Archivist", "Page-Eater"), .cosmetic = "frame_bloom" },
    // Standing
    .{ .id = "level_5", .group = "Standing", .name = pair("Out of the Shelter", "Out of the Dark"), .text = "Reach level 5.", .metric = .level, .need = 5, .salvage = 20 },
    .{ .id = "level_10", .group = "Standing", .name = pair("Somebody", "Somebody Hungry"), .text = "Reach level 10.", .metric = .level, .need = 10, .salvage = 50 },
    .{ .id = "level_25", .group = "Standing", .name = pair("Seasoned", "Ancient Appetite"), .text = "Reach level 25.", .metric = .level, .need = 25, .salvage = 200 },
    .{ .id = "level_50", .group = "Standing", .name = pair("Still Standing", "Everlasting"), .text = "Reach level 50.", .metric = .level, .need = 50, .salvage = 800, .cosmetic = "frame_wreath" },
    // Gear
    .{ .id = "rare_1", .group = "Gear", .name = pair("Something Good", "Something Rich"), .text = "Find a Rare item.", .metric = .best_rarity, .need = 3, .salvage = 30 },
    .{ .id = "legendary_1", .group = "Gear", .name = pair("Legend in the Pack", "Legend in the Gut"), .text = "Find a Legendary item.", .metric = .best_rarity, .need = 4, .salvage = 100 },
    .{ .id = "unique_1", .group = "Gear", .name = pair("A Name on It", "A Name in It"), .text = "Find a named Legendary.", .metric = .uniques_found, .need = 1, .salvage = 200, .title = pair("Heirloom Bearer", "Trophy Taker"), .cosmetic = "color_gold" },
    .{ .id = "bases_20", .group = "Gear", .name = pair("Collector", "Hoarder"), .text = "Find 20 different kinds of gear.", .metric = .bases_found, .need = 20, .salvage = 120 },
    .{ .id = "upgrade_5", .group = "Gear", .name = pair("Tuned Up", "Hardened"), .text = "Upgrade an item to +5.", .metric = .best_upgrade, .need = 5, .salvage = 50 },
    .{ .id = "upgrade_10", .group = "Gear", .name = pair("Masterwork", "Perfected"), .text = "Upgrade an item to +10.", .metric = .best_upgrade, .need = 10, .salvage = 200, .title = pair("Tinkerer", "Stitcher") },
    // Duty
    .{ .id = "missions_25", .group = "Duty", .name = pair("Reliable", "Obedient"), .text = "Claim 25 missions.", .metric = .missions, .need = 25, .salvage = 100 },
    .{ .id = "streak_7", .group = "Duty", .name = pair("A Week Running", "Seven Hungers"), .text = "Claim a daily mission seven days in a row.", .metric = .best_streak, .need = 7, .salvage = 100 },
    .{ .id = "war_100", .group = "Duty", .name = pair("Pulling Weight", "Spreading It"), .text = "Earn 100 war points.", .metric = .war_points, .need = 100, .salvage = 40 },
    .{ .id = "war_2000", .group = "Duty", .name = pair("Frontliner", "Spearhead"), .text = "Earn 2,000 war points.", .metric = .war_points, .need = 2000, .salvage = 250, .title = pair("Frontliner", "Spearhead") },
    // Time
    .{ .id = "days_7", .group = "Time", .name = pair("One Week", "One Week Cold"), .text = "Survive seven days.", .metric = .days, .need = 7, .salvage = 30 },
    .{ .id = "days_30", .group = "Time", .name = pair("A Month In", "A Month Rotting"), .text = "Survive thirty days.", .metric = .days, .need = 30, .salvage = 100 },
    .{ .id = "days_100", .group = "Time", .name = pair("Old Hand", "Old Bones"), .text = "Survive a hundred days.", .metric = .days, .need = 100, .salvage = 300, .title = pair("Old Hand", "Old Bones") },
};

comptime {
    std.debug.assert(list.len <= 64);
}

/// Earned achievements as a bit set (bit i is `list[i]`).
pub const Earned = std.bit_set.IntegerBitSet(64);

pub fn find(id: []const u8) ?u8 {
    for (list, 0..) |a, i| {
        if (std.mem.eql(u8, a.id, id)) return @intCast(i);
    }
    return null;
}

/// The achievements `m` satisfies that are not in `have`.
pub fn newlyEarned(m: Metrics, have: Earned, out: *[list.len]u8) []const u8 {
    var n: usize = 0;
    for (list, 0..) |a, i| {
        if (have.isSet(i)) continue;
        if (m.get(a.metric) >= a.need) {
            out[n] = @intCast(i);
            n += 1;
        }
    }
    return out[0..n];
}

/// The `best_rarity` metric for a rarity.
pub fn rarityMetric(r: data.Rarity) u64 {
    return @as(u64, @intFromEnum(r)) + 1;
}

/// What every achievement pays together.
pub fn totalSalvage() u32 {
    var t: u32 = 0;
    for (list) |a| t += a.salvage;
    return t;
}

test "ids are unique and every row says something" {
    for (list, 0..) |a, i| {
        try std.testing.expectEqual(@as(?u8, @intCast(i)), find(a.id));
        try std.testing.expect(a.name.human.len > 0 and a.name.zombie.len > 0 and a.text.len > 0 and a.group.len > 0);
        try std.testing.expect(a.need > 0 and a.salvage > 0);
    }
    try std.testing.expect(list.len >= 30 and list.len <= 40);
}

test "tiers of one metric rise together in need and in pay" {
    for (list, 0..) |a, i| {
        if (i == 0) continue;
        const prev = list[i - 1];
        if (prev.metric == a.metric) {
            try std.testing.expect(a.need > prev.need);
            try std.testing.expect(a.salvage >= prev.salvage);
        }
    }
}

test "thresholds that count things stay reachable" {
    for (list) |a| switch (a.metric) {
        .level => try std.testing.expect(a.need <= data.max_level),
        .bases_found => try std.testing.expect(a.need <= data.bases.len),
        .uniques_found => try std.testing.expect(a.need <= data.uniques.len),
        .best_upgrade => try std.testing.expect(a.need <= 10),
        .best_rarity => try std.testing.expect(a.need <= data.rarities.len),
        else => {},
    };
}

test "counters line up with metrics" {
    inline for (@typeInfo(Counter).@"enum".fields) |f| {
        try std.testing.expect(std.meta.stringToEnum(Metric, f.name) != null);
    }
}

test "newlyEarned skips what is held and finds what is met" {
    var m = Metrics.initFill(0);
    m.set(.distance_m, 12 * km);
    var have = Earned.initEmpty();
    var buf: [list.len]u8 = undefined;
    const first = newlyEarned(m, have, &buf);
    try std.testing.expectEqual(@as(usize, 2), first.len);
    try std.testing.expectEqualStrings("walk_1", list[first[0]].id);
    have.set(first[0]);
    const second = newlyEarned(m, have, &buf);
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqualStrings("walk_10", list[second[0]].id);
}

test "total pay is modest" {
    try std.testing.expect(totalSalvage() < 6000);
}
