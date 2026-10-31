//! Drops: PvE wins, caches, airdrops, PvP; item, rarity and perk rolls; salvage and upgrade costs.

const std = @import("std");
const data = @import("data.zig");
const stats = @import("stats.zig");
const Rng = @import("rng.zig").Rng;

const Item = stats.Item;
const Rarity = data.Rarity;
const Perk = data.Perk;
const Consumable = data.Consumable;

// --- Tuning (DESIGN.md sections 6 and 7) ----------------------------------------------------

/// Weight of a base far below the player's level. Bases within 8 levels get up to +3.
pub const base_floor_weight = 1.0;
pub const base_near_bonus = 3.0;
pub const base_near_range = 8.0;

pub const legendary_l30_mult = 1.5;
pub const airdrop_legendary_mult = 3.0;
pub const unique_chance = 1.0 / 6.0;

pub const pve_item_chance = 0.35;
pub const pve_consumable_chance = 0.50;
pub const cache_item_chance = 0.55;
pub const pvp_item_chance = 0.25;

pub const max_rolls = 4;

// --- Items ------------------------------------------------------------------------------------

pub const ItemRoll = struct {
    /// Player level.
    level: u32,
    min_rarity: Rarity = .common,
    /// Extra multiplier on the Legendary weight (airdrops: 3).
    legendary_mult: f32 = 1.0,
    /// Relative weight of a weapon / armor / utility base (landmarks lean towards some slots).
    slot_weights: [3]f32 = .{ 1, 1, 1 },
};

pub fn rollRarity(rng: *Rng, level: u32, legendary_mult: f32, min_rarity: Rarity) Rarity {
    var w: [data.rarities.len]f64 = undefined;
    for (data.rarities, 0..) |r, i| {
        w[i] = if (i < @intFromEnum(min_rarity)) 0 else r.weight;
    }
    w[@intFromEnum(Rarity.legendary)] *= legendary_mult;
    if (level >= 30) w[@intFromEnum(Rarity.legendary)] *= legendary_l30_mult;
    return @enumFromInt(rng.weighted(&w));
}

/// Base weights for a player of `level`: zero above the level, heavier near it.
pub fn baseWeight(req: u8, level: u32) f64 {
    if (req > level) return 0;
    const gap: f64 = @floatFromInt(level - req);
    return base_floor_weight + base_near_bonus * @max(0.0, 1.0 - gap / base_near_range);
}

pub fn rollBase(rng: *Rng, level: u32) u8 {
    return rollBaseSlots(rng, level, .{ 1, 1, 1 });
}

pub fn rollBaseSlots(rng: *Rng, level: u32, slot_weights: [3]f32) u8 {
    var w: [data.bases.len]f64 = undefined;
    for (data.bases, 0..) |b, i| w[i] = baseWeight(b.req, level) * slot_weights[@intFromEnum(b.slot)];
    return @intCast(rng.weighted(&w));
}

/// Pick `count` distinct perks from the pool into `out`.
fn rollPerks(rng: *Rng, count: u8, out: *[2]Perk) void {
    var pool: [data.perks.len]Perk = undefined;
    for (&pool, 0..) |*p, i| p.* = @enumFromInt(i);
    var left: u32 = pool.len;
    for (0..count) |k| {
        const pick = rng.below(left);
        out[k] = pool[pick];
        left -= 1;
        pool[pick] = pool[left];
    }
}

pub fn rollItem(rng: *Rng, roll: ItemRoll) Item {
    var item = Item{ .base = rollBaseSlots(rng, roll.level, roll.slot_weights) };
    item.rarity = rollRarity(rng, roll.level, roll.legendary_mult, roll.min_rarity);
    item.perk_count = data.rarity(item.rarity).perks;
    rollPerks(rng, item.perk_count, &item.perk_ids);
    if (item.rarity == .legendary) {
        const base_id = item.row().id;
        for (data.uniques, 0..) |u, i| {
            if (std.mem.eql(u8, u.base, base_id) and rng.chance(unique_chance)) {
                item.unique = @intCast(i);
                item.perk_ids = u.perks;
                item.perk_count = 2;
            }
        }
    }
    return item;
}

// --- Consumables ------------------------------------------------------------------------------

/// Drop weights by consumable. Flags are bought, never dropped.
const consumable_weights = [_]f64{ 38, 20, 4, 6, 6, 6, 6, 6, 0 };

pub fn rollConsumable(rng: *Rng) Consumable {
    return @enumFromInt(rng.weighted(&consumable_weights));
}

fn rollConsumableWeighted(rng: *Rng, weights: *const [9]f64) Consumable {
    return @enumFromInt(rng.weighted(weights));
}

// --- Drops -------------------------------------------------------------------------------------

pub const Drop = struct {
    salvage: u32 = 0,
    item_count: u8 = 0,
    items: [max_rolls]Item = undefined,
    consumable_count: u8 = 0,
    consumables: [max_rolls]Consumable = undefined,

    pub fn itemSlice(self: *const Drop) []const Item {
        return self.items[0..self.item_count];
    }

    pub fn consumableSlice(self: *const Drop) []const Consumable {
        return self.consumables[0..self.consumable_count];
    }

    fn addItem(self: *Drop, item: Item) void {
        self.items[self.item_count] = item;
        self.item_count += 1;
    }

    fn addConsumable(self: *Drop, c: Consumable) void {
        self.consumables[self.consumable_count] = c;
        self.consumable_count += 1;
    }
};

pub fn pveSalvage(enemy_level: u32) u32 {
    return 3 + enemy_level / 2;
}

pub const PveDrop = struct {
    player_level: u32,
    enemy_level: u32,
    archetype: data.Archetype,
    /// 1 + Lucky perks + loot buff.
    loot_mult: f32 = 1.0,
};

/// What a won PvE fight drops: 35% item, 50% consumable, salvage always. Horde-type enemies
/// multiply chances and salvage; Screamers always drop a consumable.
pub fn rollPve(rng: *Rng, p: PveDrop) Drop {
    const arch = data.archetype(p.archetype);
    const mult = p.loot_mult * arch.reward_mult;
    var d = Drop{};
    d.salvage = @intFromFloat(@round(@as(f32, @floatFromInt(pveSalvage(p.enemy_level))) * arch.reward_mult));
    if (rng.chance(pve_item_chance * mult)) {
        d.addItem(rollItem(rng, .{ .level = p.player_level }));
    }
    if (arch.guaranteed_consumable or rng.chance(pve_consumable_chance * mult)) {
        d.addConsumable(rollConsumable(rng));
    }
    return d;
}

pub fn pvpSalvage(opp_level: u32) u32 {
    return 10 + opp_level;
}

/// Contact and Echo wins: salvage and a 25% item roll (generated, never taken from the loser).
pub fn rollPvp(rng: *Rng, player_level: u32, opp_level: u32, loot_mult: f32) Drop {
    var d = Drop{ .salvage = pvpSalvage(opp_level) };
    if (rng.chance(pvp_item_chance * loot_mult)) d.addItem(rollItem(rng, .{ .level = player_level }));
    return d;
}

/// A cache: 1 to 3 rolls, each 55% item and otherwise a consumable, plus salvage per roll.
pub fn rollCache(rng: *Rng, level: u32, loot_mult: f32) Drop {
    var d = Drop{};
    const rolls = rng.intRange(1, 3);
    for (0..@intCast(rolls)) |_| {
        d.salvage += pveSalvage(level);
        if (rng.chance(cache_item_chance * loot_mult)) {
            d.addItem(rollItem(rng, .{ .level = level }));
        } else {
            d.addConsumable(rollConsumable(rng));
        }
    }
    return d;
}

/// An airdrop: 3 to 4 rolls, each 75% item (Uncommon or better, Legendary x3), double salvage.
pub fn rollAirdrop(rng: *Rng, level: u32, loot_mult: f32) Drop {
    var d = Drop{};
    const rolls = rng.intRange(3, 4);
    for (0..@intCast(rolls)) |_| {
        d.salvage += 2 * pveSalvage(level);
        if (rng.chance(0.75 * loot_mult)) {
            d.addItem(rollItem(rng, .{ .level = level, .min_rarity = .uncommon, .legendary_mult = airdrop_legendary_mult }));
        } else {
            d.addConsumable(rollConsumable(rng));
        }
    }
    return d;
}

/// Rolls in a landmark cache and its base salvage bonus.
pub const landmark_rolls = 2;
pub const landmark_salvage_mult = 1.25;

/// A landmark cache at a real place: two rolls leaning the way the place's kind does, +25%
/// salvage per roll (more at places that are about scrap).
pub fn rollLandmark(rng: *Rng, level: u32, loot_mult: f32, row: data.PlaceRow) Drop {
    var d = Drop{};
    const salvage_each: f32 = @as(f32, @floatFromInt(pveSalvage(level))) * (landmark_salvage_mult + row.salvage_extra);
    for (0..landmark_rolls) |_| {
        d.salvage += @intFromFloat(@round(salvage_each));
        if (rng.chance(row.item_chance * loot_mult)) {
            d.addItem(rollItem(rng, .{ .level = level, .min_rarity = row.min_rarity, .legendary_mult = row.legendary_mult, .slot_weights = row.slot_weights }));
        } else {
            d.addConsumable(rollConsumableWeighted(rng, &row.consumable_weights));
        }
    }
    return d;
}

// --- Salvage and upgrades ----------------------------------------------------------------------

/// Salvage gained by scrapping an item: rarity salvage x (1 + req/10).
pub fn scrapValue(item: Item) u32 {
    const r = data.rarity(item.rarity);
    const req: f32 = @floatFromInt(item.req());
    return @intFromFloat(@round(@as(f32, @floatFromInt(r.salvage)) * (1.0 + req / 10.0)));
}

pub const upgrade_cost_base = 12.0;
pub const upgrade_cost_power = 1.8;

/// Cost of the next upgrade step (n = upgrade + 1), or null at +10.
pub fn upgradeCost(item: Item) ?u32 {
    if (item.upgrade >= stats.max_upgrade) return null;
    const n: f64 = @floatFromInt(item.upgrade + 1);
    const req: f64 = @floatFromInt(item.req());
    const r = data.rarity(item.rarity);
    const cost = upgrade_cost_base * std.math.pow(f64, n, upgrade_cost_power) * (1.0 + req / 10.0) * r.rarity_cost;
    return @intFromFloat(@round(cost));
}

// --- Tests ---------------------------------------------------------------------------------------

const testing = std.testing;

test "rarity weights: 64 / 26 / 8.5 / 1.5 percent" {
    var rng = Rng.init(1);
    var counts = [_]f64{0} ** 4;
    const n = 200_000;
    for (0..n) |_| counts[@intFromEnum(rollRarity(&rng, 10, 1.0, .common))] += 1;
    try testing.expectApproxEqAbs(0.64, counts[0] / n, 0.01);
    try testing.expectApproxEqAbs(0.26, counts[1] / n, 0.01);
    try testing.expectApproxEqAbs(0.085, counts[2] / n, 0.005);
    try testing.expectApproxEqAbs(0.015, counts[3] / n, 0.003);
}

test "legendary is boosted x1.5 at level 30 and x3 for airdrops" {
    var rng = Rng.init(2);
    const n = 400_000;
    var l10: f64 = 0;
    var l30: f64 = 0;
    var air: f64 = 0;
    for (0..n) |_| {
        if (rollRarity(&rng, 10, 1.0, .common) == .legendary) l10 += 1;
        if (rollRarity(&rng, 30, 1.0, .common) == .legendary) l30 += 1;
        if (rollRarity(&rng, 10, 3.0, .common) == .legendary) air += 1;
    }
    try testing.expectApproxEqRel(1.5, l30 / l10, 0.15);
    // 4.5 / (64+26+8.5+4.5) vs 1.5 / 100
    try testing.expectApproxEqRel(4.5 / 103.0, air / n, 0.1);
}

test "min rarity is respected" {
    var rng = Rng.init(3);
    for (0..5000) |_| {
        try testing.expect(@intFromEnum(rollRarity(&rng, 5, 1.0, .uncommon)) >= 1);
        try testing.expect(@intFromEnum(rollRarity(&rng, 5, 1.0, .rare)) >= 2);
    }
}

test "base weights follow the formula" {
    try testing.expectEqual(@as(f64, 0), baseWeight(5, 4));
    try testing.expectEqual(@as(f64, 4), baseWeight(5, 5));
    try testing.expectApproxEqAbs(1 + 3 * (1 - 4.0 / 8.0), baseWeight(1, 5), 1e-9);
    try testing.expectEqual(@as(f64, 1), baseWeight(1, 9));
    try testing.expectEqual(@as(f64, 1), baseWeight(1, 50));
}

test "items never exceed the player's level; bases near it dominate" {
    var rng = Rng.init(4);
    var near: f64 = 0;
    const n = 20_000;
    for (0..n) |_| {
        const it = rollItem(&rng, .{ .level = 14 });
        try testing.expect(it.req() <= 14);
        if (it.req() >= 7) near += 1;
    }
    // Weights: bases with req 7..14 vs the rest.
    var w_near: f64 = 0;
    var w_all: f64 = 0;
    for (data.bases) |b| {
        const w = baseWeight(b.req, 14);
        w_all += w;
        if (b.req >= 7) w_near += w;
    }
    try testing.expectApproxEqAbs(w_near / w_all, near / n, 0.02);
    // Level 1 only offers the six starter bases.
    for (0..500) |_| try testing.expectEqual(@as(u8, 1), rollItem(&rng, .{ .level = 1 }).req());
}

test "perks: 0 / 0 / 1 / 2, never duplicated" {
    var rng = Rng.init(5);
    var seen_unique = false;
    for (0..20_000) |_| {
        const it = rollItem(&rng, .{ .level = 30 });
        try testing.expectEqual(data.rarity(it.rarity).perks, it.perk_count);
        if (it.perk_count == 2) try testing.expect(it.perk_ids[0] != it.perk_ids[1]);
        if (it.unique != null) {
            seen_unique = true;
            try testing.expectEqual(Rarity.legendary, it.rarity);
        }
    }
    try testing.expect(seen_unique);
}

test "uniques appear on about 1 in 6 matching legendaries, with their fixed perks" {
    var rng = Rng.init(6);
    const bat = data.findBase("baseball_bat").?;
    var legendary_bats: f64 = 0;
    var uniques: f64 = 0;
    var n: usize = 0;
    while (legendary_bats < 3000 and n < 20_000_000) : (n += 1) {
        const it = rollItem(&rng, .{ .level = 1, .legendary_mult = 40 });
        if (it.base != bat or it.rarity != .legendary) continue;
        legendary_bats += 1;
        if (it.unique) |u| {
            uniques += 1;
            try testing.expectEqualStrings("old_faithful", data.uniques[u].id);
            try testing.expectEqual(Perk.brutal, it.perk_ids[0]);
            try testing.expectEqual(Perk.lucky, it.perk_ids[1]);
        }
    }
    try testing.expectApproxEqAbs(1.0 / 6.0, uniques / legendary_bats, 0.03);
}

test "PvE drops: 35% items, 50% consumables, salvage 3 + E/2" {
    var rng = Rng.init(7);
    var items: f64 = 0;
    var cons: f64 = 0;
    const n = 100_000;
    for (0..n) |_| {
        const d = rollPve(&rng, .{ .player_level = 10, .enemy_level = 11, .archetype = .shambler });
        try testing.expectEqual(@as(u32, 8), d.salvage);
        items += @floatFromInt(d.item_count);
        cons += @floatFromInt(d.consumable_count);
    }
    try testing.expectApproxEqAbs(0.35, items / n, 0.01);
    try testing.expectApproxEqAbs(0.50, cons / n, 0.01);
}

test "Screamers always drop a consumable; Hordes pay more" {
    var rng = Rng.init(8);
    for (0..500) |_| {
        const d = rollPve(&rng, .{ .player_level = 10, .enemy_level = 10, .archetype = .screamer });
        try testing.expect(d.consumable_count == 1);
    }
    const h = rollPve(&rng, .{ .player_level = 10, .enemy_level = 10, .archetype = .horde });
    try testing.expectEqual(@as(u32, 12), h.salvage); // 8 * 1.5
    var items: f64 = 0;
    for (0..50_000) |_| items += @floatFromInt(rollPve(&rng, .{ .player_level = 10, .enemy_level = 10, .archetype = .horde }).item_count);
    try testing.expectApproxEqAbs(0.525, items / 50_000, 0.01);
}

test "caches and airdrops" {
    var rng = Rng.init(9);
    var total_rolls: f64 = 0;
    var items: f64 = 0;
    const n = 50_000;
    for (0..n) |_| {
        const d = rollCache(&rng, 10, 1.0);
        const rolls = d.item_count + d.consumable_count;
        try testing.expect(rolls >= 1 and rolls <= 3);
        try testing.expectEqual(@as(u32, 8 * rolls), d.salvage);
        total_rolls += @floatFromInt(rolls);
        items += @floatFromInt(d.item_count);
    }
    try testing.expectApproxEqAbs(0.55, items / total_rolls, 0.01);
    try testing.expectApproxEqAbs(2.0, total_rolls / n, 0.03);
    for (0..2000) |_| {
        const d = rollAirdrop(&rng, 12, 1.0);
        const rolls = d.item_count + d.consumable_count;
        try testing.expect(rolls >= 3 and rolls <= 4);
        for (d.itemSlice()) |it| try testing.expect(it.rarity != .common);
    }
}

test "landmark caches: two rolls, +25% salvage, biased by kind" {
    var rng = Rng.init(11);
    const n = 20_000;
    var pharm_heals: f64 = 0;
    var pharm_rolls: f64 = 0;
    var hw_weapons: f64 = 0;
    var hw_items: f64 = 0;
    var police_items: f64 = 0;
    for (0..n) |_| {
        const d = rollLandmark(&rng, 10, 1.0, data.placeKind(.pharmacy));
        try testing.expectEqual(@as(u32, 2), d.item_count + d.consumable_count);
        try testing.expectEqual(@as(u32, 20), d.salvage); // 2 x round(8 x 1.25)
        for (d.consumableSlice()) |c| {
            pharm_rolls += 1;
            if (c == .heal_s or c == .heal_m or c == .revive) pharm_heals += 1;
        }
        const h = rollLandmark(&rng, 10, 1.0, data.placeKind(.hardware));
        try testing.expectEqual(@as(u32, 24), h.salvage); // 2 x round(8 x 1.5)
        for (h.itemSlice()) |it| {
            hw_items += 1;
            if (it.slot() == .weapon) hw_weapons += 1;
        }
        const pd = rollLandmark(&rng, 10, 1.0, data.placeKind(.police));
        for (pd.itemSlice()) |it| {
            police_items += 1;
            try testing.expect(it.rarity != .common);
        }
    }
    // Pharmacies mostly hand out heals; hardware stores lean to weapons (4 : 1 : 1 vs 1 : 1 : 1).
    try testing.expect(pharm_heals / pharm_rolls > 0.85);
    try testing.expect(hw_weapons / hw_items > 0.5);
    try testing.expect(police_items / (2.0 * n) > 0.6);
    // Plain caches are 55% items; a pharmacy is far below that.
    var items: f64 = 0;
    for (0..n) |_| items += @floatFromInt(rollLandmark(&rng, 10, 1.0, data.placeKind(.pharmacy)).item_count);
    try testing.expectApproxEqAbs(0.15, items / (2.0 * n), 0.01);
    // Lucky perks and the loot buff scale the item chance, as for any cache.
    items = 0;
    for (0..n) |_| items += @floatFromInt(rollLandmark(&rng, 10, 2.0, data.placeKind(.pharmacy)).item_count);
    try testing.expectApproxEqAbs(0.30, items / (2.0 * n), 0.015);
}

test "consumable drops never include flags and favour small heals" {
    var rng = Rng.init(10);
    var counts = [_]u32{0} ** 9;
    for (0..50_000) |_| counts[@intFromEnum(rollConsumable(&rng))] += 1;
    try testing.expectEqual(@as(u32, 0), counts[@intFromEnum(Consumable.flag)]);
    try testing.expect(counts[0] > counts[1] and counts[1] > counts[2] and counts[2] > 0);
}

test "scrap value and upgrade cost, hand computed" {
    const bat = data.findBase("baseball_bat").?; // req 1
    const vest = data.findBase("riot_vest").?; // req 10
    // common bat: 3 * 1.1 = 3.3 -> 3
    try testing.expectEqual(@as(u32, 3), scrapValue(.{ .base = bat }));
    // rare vest: 20 * 2 = 40; legendary: 50 * 2 = 100
    try testing.expectEqual(@as(u32, 40), scrapValue(.{ .base = vest, .rarity = .rare }));
    try testing.expectEqual(@as(u32, 100), scrapValue(.{ .base = vest, .rarity = .legendary }));
    // step 1, common, req 1: 12 * 1 * 1.1 * 1 = 13.2 -> 13
    try testing.expectEqual(@as(?u32, 13), upgradeCost(.{ .base = bat }));
    // step 2, rare, req 10: 12 * 2^1.8 (3.482) * 2 * 1.7 = 142.1 -> 142
    try testing.expectEqual(@as(?u32, 142), upgradeCost(.{ .base = vest, .rarity = .rare, .upgrade = 1 }));
    // step 10, legendary, req 10: 12 * 10^1.8 (63.10) * 2 * 2.2 = 3331.3 -> 3331
    try testing.expectEqual(@as(?u32, 3331), upgradeCost(.{ .base = vest, .rarity = .legendary, .upgrade = 9 }));
    try testing.expectEqual(@as(?u32, null), upgradeCost(.{ .base = vest, .upgrade = 10 }));
}
