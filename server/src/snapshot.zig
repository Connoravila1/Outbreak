//! A player's build: level, faction, three equipped items and equipped abilities. Used for the
//! stored snapshots behind Echoes and garrisons, for live opponents, and for generated Rogue builds.

const std = @import("std");
const game = @import("game");

const data = game.data;
const stats = game.stats;
const combat = game.combat;
const progression = game.progression;

pub const Build = struct {
    faction: data.Faction,
    level: u8,
    /// Weapon, armor, utility.
    items: [3]?stats.Item = .{ null, null, null },
    abilities: std.EnumSet(data.Ability) = .initEmpty(),

    pub fn gear(self: *const Build, buf: *[3]stats.Item) []const stats.Item {
        var n: usize = 0;
        for (self.items) |it| {
            if (it) |i| {
                buf[n] = i;
                n += 1;
            }
        }
        return buf[0..n];
    }

    pub fn computed(self: *const Build) stats.Computed {
        var buf: [3]stats.Item = undefined;
        return stats.playerStats(self.level, self.faction, self.gear(&buf), .{});
    }

    /// A combatant at full health.
    pub fn combatant(self: *const Build) combat.Combatant {
        const c = self.computed();
        return .{ .faction = self.faction, .stats = c.stats, .hp = c.stats.hp, .abilities = self.abilities, .mods = c.mods };
    }

    /// Items as "base,rarity,upgrade,unique,perks,p0,p1" joined by '|'.
    pub fn encodeItems(self: *const Build, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var first = true;
        for (self.items) |maybe| {
            const it = maybe orelse continue;
            if (!first) try w.writeByte('|');
            first = false;
            try w.print("{d},{d},{d},{d},{d},{d},{d}", .{
                it.base,                                @intFromEnum(it.rarity), it.upgrade,
                if (it.unique) |u| @as(i32, u) else -1, it.perk_count,           @intFromEnum(it.perk_ids[0]),
                @intFromEnum(it.perk_ids[1]),
            });
        }
    }

    pub fn encodeAbilities(self: *const Build, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var first = true;
        var it = self.abilities.iterator();
        while (it.next()) |a| {
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll(@tagName(a));
        }
    }

    /// Inverse of the encoders. Malformed entries are skipped.
    pub fn decode(faction: data.Faction, level: u8, items_text: []const u8, abilities_text: []const u8) Build {
        var b = Build{ .faction = faction, .level = level };
        var parts = std.mem.splitScalar(u8, items_text, '|');
        while (parts.next()) |part| {
            const it = decodeItem(part) orelse continue;
            b.items[@intFromEnum(it.slot())] = it;
        }
        var names = std.mem.splitScalar(u8, abilities_text, ',');
        while (names.next()) |n| {
            if (std.meta.stringToEnum(data.Ability, n)) |a| b.abilities.insert(a);
        }
        return b;
    }
};

fn decodeItem(s: []const u8) ?stats.Item {
    var f = std.mem.splitScalar(u8, s, ',');
    var v: [7]i32 = undefined;
    for (&v) |*x| x.* = std.fmt.parseInt(i32, f.next() orelse return null, 10) catch return null;
    if (v[0] < 0 or v[0] >= data.bases.len or v[1] < 0 or v[1] >= data.rarities.len) return null;
    if (v[4] < 0 or v[4] > 2 or v[5] < 0 or v[5] >= data.perks.len or v[6] < 0 or v[6] >= data.perks.len) return null;
    return .{
        .base = @intCast(v[0]),
        .rarity = @enumFromInt(v[1]),
        .upgrade = @intCast(std.math.clamp(v[2], 0, stats.max_upgrade)),
        .unique = if (v[3] >= 0 and v[3] < data.uniques.len) @intCast(v[3]) else null,
        .perk_count = @intCast(v[4]),
        .perk_ids = .{ @enumFromInt(v[5]), @enumFromInt(v[6]) },
    };
}

/// Abilities for a build: fill the slots with the newest unlocked abilities.
pub fn defaultAbilities(faction: data.Faction, level: u32) std.EnumSet(data.Ability) {
    var set: std.EnumSet(data.Ability) = .initEmpty();
    var buf: [7]data.Ability = undefined;
    const unlocked = progression.unlockedAbilities(faction, level, &buf);
    const slots = progression.abilitySlots(level);
    var i = unlocked.len;
    var n: usize = 0;
    while (i > 0 and n < slots) {
        i -= 1;
        set.insert(unlocked[i]);
        n += 1;
    }
    return set;
}

/// The best base of each slot the level allows, at one rarity (a "Rogue" kit).
pub fn kitBuild(faction: data.Faction, level: u8, rarity: data.Rarity) Build {
    var b = Build{ .faction = faction, .level = level, .abilities = defaultAbilities(faction, level) };
    for ([_]data.Slot{ .weapon, .armor, .utility }, 0..) |slot, si| {
        var best: ?u8 = null;
        for (data.bases, 0..) |base, i| {
            if (base.slot != slot or base.req > level) continue;
            if (best == null or base.req > data.bases[best.?].req) best = @intCast(i);
        }
        if (best) |i| b.items[si] = .{ .base = i, .rarity = rarity, .perk_count = data.rarity(rarity).perks, .perk_ids = .{ .keen, .swift } };
    }
    return b;
}

test "builds survive the text round trip" {
    var b = kitBuild(.zombie, 30, .rare);
    b.items[0].?.upgrade = 4;
    b.items[1] = .{ .base = data.findBase("riot_vest").?, .rarity = .legendary, .unique = data.findUnique("the_wall").?, .perk_count = 2, .perk_ids = .{ .sturdy, .thorns } };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try b.encodeItems(&aw.writer);
    const items_text = try std.testing.allocator.dupe(u8, aw.written());
    defer std.testing.allocator.free(items_text);
    aw.clearRetainingCapacity();
    try b.encodeAbilities(&aw.writer);
    const back = Build.decode(.zombie, 30, items_text, aw.written());
    try std.testing.expectEqualDeep(b.items, back.items);
    try std.testing.expect(back.abilities.eql(b.abilities));
    try std.testing.expectEqual(b.computed().stats, back.computed().stats);
}

test "decode skips garbage and clamps" {
    const b = Build.decode(.human, 5, "x|1,9,0,-1,0,0,0|999,0,0,0,0,0,0|0,0,50,-1,0,0,0", "nope,second_wind");
    try std.testing.expect(b.items[0] != null);
    try std.testing.expectEqual(@as(u8, 10), b.items[0].?.upgrade);
    try std.testing.expect(b.items[1] == null);
    try std.testing.expect(b.abilities.contains(.second_wind) and b.abilities.count() == 1);
}

test "default abilities fill slots with the newest unlocks" {
    try std.testing.expectEqual(@as(usize, 0), defaultAbilities(.human, 2).count());
    try std.testing.expect(defaultAbilities(.human, 3).contains(.second_wind));
    const l12 = defaultAbilities(.zombie, 12);
    try std.testing.expect(l12.contains(.calcify) and l12.contains(.pounce) and l12.count() == 2);
}
