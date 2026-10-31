//! Stats: base stats by level, item stats, power scores, and player totals.
//!
//! Order of operations for a player's total stats, as in DESIGN.md:
//!   base(level) + sum(item stats)         flat
//!   x (1 + trait + buff + perks)          percentages are added together, then applied once
//! HP, ATK, DEF and SPD are rounded to integers at the end; displayed numbers are the real ones.

const std = @import("std");
const data = @import("data.zig");

pub const Stats = data.Stats;
const Faction = data.Faction;
const Rarity = data.Rarity;
const Perk = data.Perk;

// --- Constants (DESIGN.md sections 3, 4, 6) -----------------------------------------------

pub const resolve_def = 0.10; // Human trait: +DEF ...
pub const resolve_hp = 0.05; // ... and +max HP.
pub const hunger_atk = 0.05; // Zombie trait: +ATK ...
pub const buff_percent = 0.15;
pub const upgrade_step = 0.04;
pub const max_upgrade: u8 = 10;
pub const unique_bonus = 1.10;
pub const perk_keen = 0.06;
pub const perk_swift = 0.08;
pub const perk_brutal = 0.08;
pub const perk_sturdy = 0.08;
pub const perk_vital = 0.10;
pub const perk_leech = 0.05;
pub const perk_thorns = 0.08;
pub const perk_lucky = 0.15;
pub const hunger_leech = 0.05; // ... and heal this share of damage dealt.
pub const resolve_heal_bonus = 0.25;

pub const downed_ms_grace: i64 = 5 * 60 * 1000;
pub const downed_ms_full: i64 = 10 * 60 * 1000;
pub const revive_fraction = 0.30;
/// Levels below this are "new": gentler Downed time, weaker enemies, no elites.
pub const grace_levels: u32 = 5;

/// How long Downed lasts: 5 minutes below level 5, 10 from level 5.
pub fn downedMs(level: u32) i64 {
    return if (level < grace_levels) downed_ms_grace else downed_ms_full;
}

/// Multiplier on enemy HP, ATK and DEF for a viewer below level 5: 0.75 at L1 up to 1.0 at L5.
pub fn graceFactor(viewer_level: u32) f32 {
    return switch (viewer_level) {
        0, 1 => 0.75,
        2 => 0.80,
        3 => 0.87,
        4 => 0.94,
        else => 1.0,
    };
}

/// The First Blood enemy's strength against the stats it would have at the player's level.
pub const tutorial_factor: f32 = 0.6;

pub fn baseStats(level: u32) Stats {
    const l: f64 = @floatFromInt(level - 1);
    return .{
        .hp = @intFromFloat(@round(100 + 14 * l)),
        .atk = @intFromFloat(@round(10 + 2.0 * l)),
        .def = @intFromFloat(@round(6 + 1.5 * l)),
        .spd = @intFromFloat(@round(10 + 0.6 * l)),
    };
}

// --- Items ---------------------------------------------------------------------------------

/// One owned item (without a uid; the server assigns that).
pub const Item = struct {
    base: u8,
    rarity: Rarity = .common,
    upgrade: u8 = 0,
    /// Index into `data.uniques`.
    unique: ?u8 = null,
    perk_count: u8 = 0,
    perk_ids: [2]Perk = .{ .keen, .keen },

    pub fn row(self: *const Item) data.BaseItem {
        return data.bases[self.base];
    }

    pub fn slot(self: *const Item) data.Slot {
        return self.row().slot;
    }

    pub fn req(self: *const Item) u8 {
        return self.row().req;
    }

    pub fn perks(self: *const Item) []const Perk {
        return self.perk_ids[0..self.perk_count];
    }

    pub fn name(self: *const Item, faction: Faction) []const u8 {
        if (self.unique) |u| return data.uniques[u].name.get(faction);
        return self.row().name.get(faction);
    }

    pub fn hasPerk(self: *const Item, p: Perk) bool {
        return std.mem.indexOfScalar(Perk, self.perks(), p) != null;
    }
};

/// Final stats shown on the item: base x rarity x (1 + 4% per upgrade), uniques x1.1.
/// Perks are not folded in here; they apply to the wearer (see `playerStats`).
pub fn itemStats(item: Item) Stats {
    const row = item.row();
    var f = data.rarity(item.rarity).mult * (1.0 + upgrade_step * @as(f32, @floatFromInt(item.upgrade)));
    if (item.unique != null) f *= unique_bonus;
    return .{
        .hp = scale(row.stats.hp, f),
        .atk = scale(row.stats.atk, f),
        .def = scale(row.stats.def, f),
        .spd = scale(row.stats.spd, f),
    };
}

fn scale(v: i32, f: f32) i32 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(v)) * f));
}

/// Relative weights of a point of each stat, for comparing items. One point of ATK is worth
/// about 4 points of DEF-equivalent HP at mid levels; the weights are rough on purpose.
pub const power_weight = .{ .hp = 0.3, .atk = 4.0, .def = 3.0, .spd = 2.0 };
pub const power_per_perk = 0.06;

/// A single number for sorting and comparing items of any slot.
pub fn itemPower(item: Item) i32 {
    const s = itemStats(item);
    const raw = power_weight.hp * @as(f32, @floatFromInt(s.hp)) +
        power_weight.atk * @as(f32, @floatFromInt(s.atk)) +
        power_weight.def * @as(f32, @floatFromInt(s.def)) +
        power_weight.spd * @as(f32, @floatFromInt(s.spd));
    const with_perks = raw * (1.0 + power_per_perk * @as(f32, @floatFromInt(item.perk_count)));
    return @intFromFloat(@round(with_perks));
}

// --- Player totals -------------------------------------------------------------------------

pub const Buffs = struct {
    atk: bool = false,
    def: bool = false,
    spd: bool = false,
};

/// Combat modifiers that are not plain stats.
pub const Mods = struct {
    /// Added to the crit chance.
    crit: f32 = 0,
    /// Fraction of damage dealt healed (Hunger trait + Leech perks).
    leech: f32 = 0,
    /// Fraction of damage taken reflected.
    thorns: f32 = 0,
    /// Added to loot chances.
    loot: f32 = 0,
};

pub const Computed = struct {
    stats: Stats,
    mods: Mods,
};

pub fn playerStats(level: u32, faction: Faction, gear: []const Item, buffs: Buffs) Computed {
    var flat = baseStats(level);
    var mods = Mods{};
    var atk_pct: f32 = 0;
    var def_pct: f32 = 0;
    var spd_pct: f32 = 0;
    var hp_pct: f32 = 0;

    for (gear) |item| {
        const s = itemStats(item);
        flat.hp += s.hp;
        flat.atk += s.atk;
        flat.def += s.def;
        flat.spd += s.spd;
        for (item.perks()) |p| switch (p) {
            .keen => mods.crit += perk_keen,
            .swift => spd_pct += perk_swift,
            .brutal => atk_pct += perk_brutal,
            .sturdy => def_pct += perk_sturdy,
            .vital => hp_pct += perk_vital,
            .leech => mods.leech += perk_leech,
            .thorns => mods.thorns += perk_thorns,
            .lucky => mods.loot += perk_lucky,
        };
    }

    switch (faction) {
        .human => {
            def_pct += resolve_def;
            hp_pct += resolve_hp;
        },
        .zombie => {
            atk_pct += hunger_atk;
            mods.leech += hunger_leech;
        },
    }
    if (buffs.atk) atk_pct += buff_percent;
    if (buffs.def) def_pct += buff_percent;
    if (buffs.spd) spd_pct += buff_percent;

    return .{
        .stats = .{
            .hp = @max(1, scale(flat.hp, 1 + hp_pct)),
            .atk = @max(1, scale(flat.atk, 1 + atk_pct)),
            .def = @max(0, scale(flat.def, 1 + def_pct)),
            .spd = @max(1, scale(flat.spd, 1 + spd_pct)),
        },
        .mods = mods,
    };
}

/// Gear a "typical" player of each level carries: the best Common base in each slot. Enemies are
/// scaled against base stats plus this, so a player in level-appropriate gear meets them evenly.
pub const reference_gear = blk: {
    @setEvalBranchQuota(100_000);
    var table: [data.max_level + 1]Stats = undefined;
    for (&table, 0..) |*entry, level| {
        var sum = Stats{};
        for ([_]data.Slot{ .weapon, .armor, .utility }) |slot| {
            var best: ?u8 = null;
            for (data.bases, 0..) |b, i| {
                if (b.slot != slot or b.req > level) continue;
                if (best == null or b.req > data.bases[best.?].req or
                    (b.req == data.bases[best.?].req and itemPower(.{ .base = @intCast(i) }) > itemPower(.{ .base = best.? }))) best = @intCast(i);
            }
            if (best) |i| {
                const s = itemStats(.{ .base = i });
                sum.hp += s.hp;
                sum.atk += s.atk;
                sum.def += s.def;
                sum.spd += s.spd;
            }
        }
        entry.* = sum;
    }
    break :blk table;
};

/// Scale on enemy HP, ATK and DEF (tuned with the simulator): players out-grow the reference
/// gear with rarity and upgrades, so enemies get tougher with level to stay even.
pub const enemy_scale_base = 0.95;
pub const enemy_scale_slope = 0.85;

fn enemyScale(level: u32) f32 {
    const l: f32 = @floatFromInt(@min(level, data.max_level));
    return enemy_scale_base + enemy_scale_slope * l / @as(f32, data.max_level);
}

/// Stats of a PvE enemy: the archetype's multiples of a same-level player's base stats plus
/// reference gear (no trait, no perks).
pub fn enemyStats(arch: data.Archetype, level: u32) Stats {
    return enemyStatsScaled(arch, level, 1.0);
}

/// `enemyStats` with HP, ATK and DEF multiplied by `mult` (new-player grace, First Blood).
pub fn enemyStatsScaled(arch: data.Archetype, level: u32, mult: f32) Stats {
    const b = baseStats(level);
    const g = reference_gear[@min(level, data.max_level)];
    const a = data.archetype(arch);
    return .{
        .hp = @max(1, scale(b.hp + g.hp, a.hp * enemyScale(level) * mult)),
        .atk = @max(1, scale(b.atk + g.atk, a.atk * enemyScale(level) * mult)),
        .def = @max(0, scale(b.def + g.def, a.def * enemyScale(level) * mult)),
        .spd = @max(1, scale(b.spd + g.spd, a.spd)),
    };
}

// --- Health and healing ----------------------------------------------------------------------

/// Fraction of max HP regenerated per minute out of combat: 2%, Zombies 2.5%.
pub fn regenRate(faction: Faction) f64 {
    return if (faction == .zombie) 0.025 else 0.02;
}

/// HP regenerated out of combat over `minutes`.
pub fn regenHp(faction: Faction, max_hp: i32, minutes: f64) i32 {
    return @intFromFloat(@floor(regenRate(faction) * @as(f64, @floatFromInt(max_hp)) * minutes));
}

/// HP restored by a healing consumable (0 for anything that does not heal). Humans heal 25% more.
/// A revive heals fully.
pub fn healAmount(c: data.Consumable, faction: Faction, max_hp: i32) i32 {
    const frac: f32 = switch (c) {
        .heal_s => 0.25,
        .heal_m => 0.60,
        .revive => 1.0,
        else => return 0,
    };
    const bonus: f32 = if (faction == .human and c != .revive) 1.0 + resolve_heal_bonus else 1.0;
    return @intFromFloat(@round(@as(f32, @floatFromInt(max_hp)) * frac * bonus));
}

test "base stats by level" {
    try std.testing.expectEqual(Stats{ .hp = 100, .atk = 10, .def = 6, .spd = 10 }, baseStats(1));
    // L11: 100+140, 10+20, 6+15, 10+6
    try std.testing.expectEqual(Stats{ .hp = 240, .atk = 30, .def = 21, .spd = 16 }, baseStats(11));
    // L50: 100+686, 10+98, 6+73.5 -> 80 (round half away), 10+29.4 -> 39
    try std.testing.expectEqual(Stats{ .hp = 786, .atk = 108, .def = 80, .spd = 39 }, baseStats(50));
}

test "item stats: rarity and upgrade multipliers, hand computed" {
    const bat = data.findBase("baseball_bat").?;
    try std.testing.expectEqual(Stats{ .atk = 7 }, itemStats(.{ .base = bat }));
    // 7 * 1.45 * 1.4 = 14.209 -> 14
    try std.testing.expectEqual(@as(i32, 14), itemStats(.{ .base = bat, .rarity = .rare, .upgrade = 10 }).atk);
    // Legendary Riot Vest +0: def 11*1.8=19.8->20, hp 22*1.8=39.6->40, spd -1*1.8 -> -2
    const vest = data.findBase("riot_vest").?;
    try std.testing.expectEqual(Stats{ .def = 20, .hp = 40, .spd = -2 }, itemStats(.{ .base = vest, .rarity = .legendary }));
    // The unique is that plus 10%: def 11*1.98=21.78->22, hp 43.56->44, spd -1.98->-2
    const the_wall = data.findUnique("the_wall").?;
    try std.testing.expectEqual(Stats{ .def = 22, .hp = 44, .spd = -2 }, itemStats(.{ .base = vest, .rarity = .legendary, .unique = the_wall }));
}

test "item power orders obvious upgrades" {
    const bat = data.findBase("baseball_bat").?;
    const axe = data.findBase("fire_axe").?;
    const a = itemPower(.{ .base = bat });
    try std.testing.expectEqual(@as(i32, 28), a);
    try std.testing.expect(itemPower(.{ .base = axe }) > a);
    try std.testing.expect(itemPower(.{ .base = bat, .rarity = .uncommon }) > a);
    try std.testing.expect(itemPower(.{ .base = bat, .upgrade = 1 }) >= a);
    try std.testing.expect(itemPower(.{ .base = bat, .rarity = .rare, .perk_count = 1, .perk_ids = .{ .keen, .keen } }) >
        itemPower(.{ .base = bat, .rarity = .rare }));
}

test "player totals: gear, trait, buffs, perks" {
    const bat = data.findBase("baseball_bat").?;
    const hoodie = data.findBase("hoodie").?;
    const light = data.findBase("flashlight").?;
    const kit = [_]Item{ .{ .base = bat }, .{ .base = hoodie }, .{ .base = light } };
    // L1 human: hp (100+5) * 1.05 = 110, atk 10+7, def (6+3+1) * 1.1 = 11, spd 10+1+3
    const h = playerStats(1, .human, &kit, .{});
    try std.testing.expectEqual(Stats{ .hp = 110, .atk = 17, .def = 11, .spd = 14 }, h.stats);
    try std.testing.expectEqual(@as(f32, 0), h.mods.leech);
    // L1 zombie: atk 17 * 1.05 = 17.85 -> 18, def 10, and Hunger heals 5% of damage dealt
    const z = playerStats(1, .zombie, &kit, .{});
    try std.testing.expectEqual(Stats{ .hp = 105, .atk = 18, .def = 10, .spd = 14 }, z.stats);
    try std.testing.expectApproxEqAbs(0.05, z.mods.leech, 1e-6);
    // Buffs and trait add: human DEF 10 * (1 + 0.10 + 0.15) = 12.5 -> 13
    try std.testing.expectEqual(@as(i32, 13), playerStats(1, .human, &kit, .{ .def = true }).stats.def);
    // Perks: Brutal + Vital + Keen + Leech + Thorns + Lucky on a legendary
    var perky = Item{ .base = bat, .rarity = .legendary, .perk_count = 2, .perk_ids = .{ .brutal, .vital } };
    var c = playerStats(1, .human, &[_]Item{perky}, .{});
    // atk (10 + 7*1.8=12.6->13) = 23 * 1.08 = 24.84 -> 25; hp 100 * (1 + 0.05 Resolve + 0.10 Vital) = 115
    try std.testing.expectEqual(@as(i32, 25), c.stats.atk);
    try std.testing.expectEqual(@as(i32, 115), c.stats.hp);
    perky.perk_ids = .{ .keen, .thorns };
    c = playerStats(1, .human, &[_]Item{perky}, .{});
    try std.testing.expectApproxEqAbs(0.06, c.mods.crit, 1e-6);
    try std.testing.expectApproxEqAbs(0.08, c.mods.thorns, 1e-6);
    perky.perk_ids = .{ .lucky, .leech };
    c = playerStats(1, .human, &[_]Item{perky}, .{});
    try std.testing.expectApproxEqAbs(0.15, c.mods.loot, 1e-6);
    try std.testing.expectApproxEqAbs(0.05, c.mods.leech, 1e-6);
}

test "enemy stats are multiples of base stats" {
    // L11 reference gear: Revolver (atk 15, spd 4), Riot Vest (def 11, hp 22, spd -1) from L10,
    // Gas Mask (def 5, hp 15, spd 2) from L10.
    try std.testing.expectEqual(Stats{ .hp = 37, .atk = 15, .def = 16, .spd = 5 }, reference_gear[11]);
    // Shambler = 0.8 x (base + gear) x level scale (0.95 + 0.85 * 11/50 = 1.137); speed is unscaled x0.7:
    // hp 277*.8*1.137 = 252, atk 45*.8*1.137 = 41, def 37*.8*1.137 = 34, spd 21*.7 = 15
    try std.testing.expectEqual(Stats{ .hp = 252, .atk = 41, .def = 34, .spd = 15 }, enemyStats(.shambler, 11));
    try std.testing.expectEqual(@as(i32, 32), enemyStats(.runner, 11).spd);
}

test "regen and heals" {
    try std.testing.expectEqual(@as(i32, 20), regenHp(.human, 100, 10));
    try std.testing.expectEqual(@as(i32, 25), regenHp(.zombie, 100, 10));
    // A Human with 110 max HP is back from empty in 50 minutes.
    try std.testing.expectEqual(@as(i32, 110), @min(110, regenHp(.human, 110, 50)));
    try std.testing.expectEqual(@as(i32, 31), healAmount(.heal_s, .human, 100));
    try std.testing.expectEqual(@as(i32, 25), healAmount(.heal_s, .zombie, 100));
    try std.testing.expectEqual(@as(i32, 75), healAmount(.heal_m, .human, 100));
    try std.testing.expectEqual(@as(i32, 100), healAmount(.revive, .human, 100));
    try std.testing.expectEqual(@as(i32, 0), healAmount(.buff_atk, .human, 100));
}

test "new-player grace: factors, downed time, scaled enemies" {
    try std.testing.expectEqual(@as(f32, 0.75), graceFactor(1));
    try std.testing.expectEqual(@as(f32, 0.80), graceFactor(2));
    try std.testing.expectEqual(@as(f32, 0.87), graceFactor(3));
    try std.testing.expectEqual(@as(f32, 0.94), graceFactor(4));
    try std.testing.expectEqual(@as(f32, 1.0), graceFactor(5));
    try std.testing.expectEqual(@as(f32, 1.0), graceFactor(40));
    try std.testing.expectEqual(@as(i64, 5 * 60 * 1000), downedMs(4));
    try std.testing.expectEqual(@as(i64, 10 * 60 * 1000), downedMs(5));
    const full = enemyStats(.shambler, 1);
    const soft = enemyStatsScaled(.shambler, 1, graceFactor(1));
    const first = enemyStatsScaled(.shambler, 1, tutorial_factor);
    try std.testing.expect(first.hp < soft.hp and soft.hp < full.hp);
    try std.testing.expect(first.atk <= soft.atk and soft.atk <= full.atk);
    try std.testing.expectEqual(full.spd, first.spd);
    try std.testing.expectEqualDeep(full, enemyStatsScaled(.shambler, 1, 1.0));
}
