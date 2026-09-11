//! CORE. The smallest complete equipment decision in Outbreak.
//!
//! The first playable slice has three authored field kits. They are not client-computed stats:
//! the phone sends a bounded selection intent, the server stores the selected kit, and combat reads
//! the authoritative value from the world. A modified client may ask for one of these three kits;
//! it cannot invent a fourth, invent stats, or claim a reward.

const std = @import("std");
const rand = @import("rand.zig");

const assert = std.debug.assert;

pub const Kit = enum(u8) {
    field,
    raider,
    bulwark,
};

/// The real MVP equipment model. `Kit` above survives only as a deterministic training preset;
/// production players own and equip individual authored discoveries.
pub const Slot = enum(u8) { weapon, armor, utility, evidence };
pub const Rarity = enum(u8) { common, uncommon, rare, legendary };

pub const ItemId = enum(u8) {
    salvaged_pipe,
    splitting_axe,
    nail_driver,
    breach_shotgun,
    quarantine_carbine,
    last_argument,
    work_jacket,
    riot_vest,
    scavenger_rig,
    hazmat_shell,
    quarantine_plate,
    last_wall,
    field_radio,
    adrenaline_ampoule,
    trauma_pack,
    signal_scrambler,
    spore_lure,
    black_box,
    torn_evacuation_order,
    bent_quarantine_keycard,
    bloodless_sample_tube,
    burned_dispatch_tape,
    redacted_patient_zero_file,
    original_containment_seal,
};

pub const item_count: u8 = 24;
pub const no_item: u8 = 0xff;
pub const ItemMask = u32;

pub const Item = struct {
    id: ItemId,
    name: []const u8,
    description: []const u8,
    slot: Slot,
    rarity: Rarity,
    unlock_level: u8,
    attack: u8 = 0,
    defense: u8 = 0,
    initiative: u8 = 0,
};

pub const catalogue = [_]Item{
    .{ .id = .salvaged_pipe, .name = "Salvaged Pipe", .description = "Reliable blunt force. Ugly, balanced, available.", .slot = .weapon, .rarity = .common, .unlock_level = 1, .attack = 4 },
    .{ .id = .splitting_axe, .name = "Splitting Axe", .description = "Less force than the pipe. Faster back to guard.", .slot = .weapon, .rarity = .common, .unlock_level = 1, .attack = 3, .initiative = 1 },
    .{ .id = .nail_driver, .name = "Nail Driver", .description = "Built for pressure, not restraint.", .slot = .weapon, .rarity = .uncommon, .unlock_level = 2, .attack = 5, .initiative = 1 },
    .{ .id = .breach_shotgun, .name = "Breach Shotgun", .description = "Devastating at contact. Slow everywhere else.", .slot = .weapon, .rarity = .rare, .unlock_level = 5, .attack = 7 },
    .{ .id = .quarantine_carbine, .name = "Quarantine Carbine", .description = "Controlled force from a failed perimeter.", .slot = .weapon, .rarity = .rare, .unlock_level = 7, .attack = 6, .initiative = 3 },
    .{ .id = .last_argument, .name = "Last Argument", .description = "The weapon issued when negotiation had ended.", .slot = .weapon, .rarity = .legendary, .unlock_level = 10, .attack = 8, .defense = 1, .initiative = 2 },

    .{ .id = .work_jacket, .name = "Work Jacket", .description = "Canvas, old blood, enough padding to matter.", .slot = .armor, .rarity = .common, .unlock_level = 1, .defense = 2 },
    .{ .id = .riot_vest, .name = "Riot Vest", .description = "Heavy protection from before the line broke.", .slot = .armor, .rarity = .common, .unlock_level = 1, .defense = 4 },
    .{ .id = .scavenger_rig, .name = "Scavenger Rig", .description = "Protection that leaves both hands free.", .slot = .armor, .rarity = .uncommon, .unlock_level = 2, .defense = 3, .initiative = 1 },
    .{ .id = .hazmat_shell, .name = "Hazmat Shell", .description = "Sealed layers carrying a warning nobody obeyed.", .slot = .armor, .rarity = .uncommon, .unlock_level = 4, .defense = 5 },
    .{ .id = .quarantine_plate, .name = "Quarantine Plate", .description = "A section of the perimeter, cut down and worn.", .slot = .armor, .rarity = .rare, .unlock_level = 7, .defense = 6 },
    .{ .id = .last_wall, .name = "Last Wall", .description = "The final shield built by people who knew there was no rescue.", .slot = .armor, .rarity = .legendary, .unlock_level = 10, .attack = 1, .defense = 7 },

    .{ .id = .field_radio, .name = "Field Radio", .description = "Dead channels still teach you when to move.", .slot = .utility, .rarity = .common, .unlock_level = 1, .initiative = 4 },
    .{ .id = .adrenaline_ampoule, .name = "Adrenaline Ampoule", .description = "Pressure now. Consequences later.", .slot = .utility, .rarity = .common, .unlock_level = 1, .attack = 1, .initiative = 5 },
    .{ .id = .trauma_pack, .name = "Trauma Pack", .description = "Keep standing long enough for the fight to matter.", .slot = .utility, .rarity = .uncommon, .unlock_level = 2, .defense = 1, .initiative = 2 },
    .{ .id = .signal_scrambler, .name = "Signal Scrambler", .description = "A broken war machine that still muddies the air.", .slot = .utility, .rarity = .uncommon, .unlock_level = 4, .defense = 2, .initiative = 3 },
    .{ .id = .spore_lure, .name = "Spore Lure", .description = "The infected follow it. So does everyone hunting them.", .slot = .utility, .rarity = .rare, .unlock_level = 7, .attack = 2, .initiative = 4 },
    .{ .id = .black_box, .name = "Black Box", .description = "It recorded the end. It may have learned from it.", .slot = .utility, .rarity = .legendary, .unlock_level = 10, .attack = 2, .defense = 2, .initiative = 4 },

    .{ .id = .torn_evacuation_order, .name = "Torn Evacuation Order", .description = "Half a route. No destination.", .slot = .evidence, .rarity = .common, .unlock_level = 1 },
    .{ .id = .bent_quarantine_keycard, .name = "Bent Quarantine Keycard", .description = "Clearance for a perimeter that no longer exists.", .slot = .evidence, .rarity = .common, .unlock_level = 1 },
    .{ .id = .bloodless_sample_tube, .name = "Bloodless Sample Tube", .description = "Labelled, sealed, and empty when recovered.", .slot = .evidence, .rarity = .uncommon, .unlock_level = 3 },
    .{ .id = .burned_dispatch_tape, .name = "Burned Dispatch Tape", .description = "The final call repeats beneath the static.", .slot = .evidence, .rarity = .uncommon, .unlock_level = 4 },
    .{ .id = .redacted_patient_zero_file, .name = "Redacted Patient Zero File", .description = "Every useful name was removed before the archive burned.", .slot = .evidence, .rarity = .rare, .unlock_level = 7 },
    .{ .id = .original_containment_seal, .name = "Original Containment Seal", .description = "The mark placed on the first locked door.", .slot = .evidence, .rarity = .legendary, .unlock_level = 10 },
};

pub const Loadout = struct {
    weapon: ItemId = .salvaged_pipe,
    armor: ItemId = .work_jacket,
    utility: ItemId = .field_radio,
};

pub const starter_loadout: Loadout = .{};
pub const starter_owned: ItemMask = bit(.salvaged_pipe) | bit(.work_jacket) | bit(.field_radio);

pub fn preset(kit: Kit) Loadout {
    return switch (kit) {
        .field => starter_loadout,
        .raider => .{ .weapon = .nail_driver, .armor = .work_jacket, .utility = .adrenaline_ampoule },
        .bulwark => .{ .weapon = .splitting_axe, .armor = .riot_vest, .utility = .trauma_pack },
    };
}

pub fn definition(id: ItemId) Item {
    return catalogue[@intFromEnum(id)];
}

pub fn itemFromByte(value: u8) ?ItemId {
    if (value >= item_count) return null;
    return @enumFromInt(value);
}

pub fn bit(id: ItemId) ItemMask {
    return @as(ItemMask, 1) << @as(u5, @intCast(@intFromEnum(id)));
}

pub fn same(a: Loadout, b: Loadout) bool {
    return a.weapon == b.weapon and a.armor == b.armor and a.utility == b.utility;
}

pub fn owns(mask: ItemMask, id: ItemId) bool {
    return mask & bit(id) != 0;
}

pub fn discover(mask: ItemMask, id: ItemId) ItemMask {
    return mask | bit(id);
}

pub fn equipmentCount(mask: ItemMask) u8 {
    const equipment_mask: ItemMask = (@as(ItemMask, 1) << 18) - 1;
    return @intCast(@popCount(mask & equipment_mask));
}

pub fn evidenceCount(mask: ItemMask) u8 {
    const evidence_mask: ItemMask = ((@as(ItemMask, 1) << item_count) - 1) & ~((@as(ItemMask, 1) << 18) - 1);
    return @intCast(@popCount(mask & evidence_mask));
}

/// Every early level produces a visible account change even before its new item tier drops.
pub fn capacityForLevel(level: u16) u8 {
    return @intCast(6 + @min(@as(u16, 9), level -| 1));
}

pub fn validEquipped(equipped: Loadout, owned: ItemMask) bool {
    return definition(equipped.weapon).slot == .weapon and owns(owned, equipped.weapon) and
        definition(equipped.armor).slot == .armor and owns(owned, equipped.armor) and
        definition(equipped.utility).slot == .utility and owns(owned, equipped.utility);
}

/// The base two points keep an empty weapon contribution from making combat inert. Everything
/// above it is authored equipment, and only the server calls this for a real encounter.
pub fn equippedStats(equipped: Loadout) Stats {
    const weapon = definition(equipped.weapon);
    const armor = definition(equipped.armor);
    const utility = definition(equipped.utility);
    return .{
        .attack = 2 +| weapon.attack +| armor.attack +| utility.attack,
        .defense = weapon.defense +| armor.defense +| utility.defense,
        .initiative = weapon.initiative +| armor.initiative +| utility.initiative,
        .salvage_bias = 0,
    };
}

/// Deterministic encounter discovery. The player level bounds the authored pool; the location
/// does not participate, so there is never a valuable place to spoof or travel toward.
pub fn drop(seed: u64, tick_index: u64, player: u32, level: u16) ItemId {
    var eligible: u8 = 0;
    for (catalogue) |item| {
        if (item.unlock_level <= level) eligible += 1;
    }
    const roll = rand.draw(&.{ seed, tick_index, player, level, 0xC011_EC7 });
    var wanted: u8 = @intCast(roll % eligible);
    for (catalogue) |item| {
        if (item.unlock_level > level) continue;
        if (wanted == 0) return item.id;
        wanted -= 1;
    }
    unreachable;
}

/// Combat-facing values for one authored kit. Hot only while resolving a live run.
pub const Stats = struct {
    attack: u8,
    defense: u8,
    initiative: u8,
    salvage_bias: u8,

    comptime {
        assert(@sizeOf(Stats) == 4);
    }
};

pub fn stats(kit: Kit) Stats {
    return switch (kit) {
        .field => .{ .attack = 6, .defense = 2, .initiative = 4, .salvage_bias = 0 },
        .raider => .{ .attack = 8, .defense = 0, .initiative = 6, .salvage_bias = 1 },
        .bulwark => .{ .attack = 5, .defense = 4, .initiative = 2, .salvage_bias = 0 },
    };
}

/// What one engagement yielded. It is an authored category, never a client claim.
pub const Reward = enum(u8) {
    none,
    weapon_parts,
    armor_parts,
    field_supplies,
};

/// Deterministic, server-side salvage. One result at engagement start; replay gets the same one.
pub fn reward(seed: u64, tick_index: u64, player: u32, kit: Kit) Reward {
    const roll = rand.draw(&.{ seed, tick_index, player, @intFromEnum(kit), 0x5A1A_A6E });
    const shifted = (roll + stats(kit).salvage_bias) % 3;
    return switch (shifted) {
        0 => .weapon_parts,
        1 => .armor_parts,
        else => .field_supplies,
    };
}

test "the three kits have real trade-offs" {
    const field = stats(.field);
    const raider = stats(.raider);
    const bulwark = stats(.bulwark);

    try std.testing.expect(raider.attack > field.attack);
    try std.testing.expect(raider.initiative > bulwark.initiative);
    try std.testing.expect(bulwark.defense > field.defense);
}

test "salvage is deterministic and never empty at engagement start" {
    const a = reward(7, 12, 99, .field);
    const b = reward(7, 12, 99, .field);
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != .none);
}

test "the catalogue is contiguous, slotted, and level bounded" {
    try std.testing.expectEqual(@as(usize, item_count), catalogue.len);
    for (catalogue, 0..) |item, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i)), @intFromEnum(item.id));
        try std.testing.expect(item.unlock_level >= 1 and item.unlock_level <= 10);
        if (item.slot == .evidence) {
            try std.testing.expectEqual(@as(u8, 0), item.attack + item.defense + item.initiative);
        }
    }
}

test "starter ownership is a valid three-slot loadout" {
    try std.testing.expect(validEquipped(starter_loadout, starter_owned));
    try std.testing.expectEqual(@as(u8, 3), equipmentCount(starter_owned));
    try std.testing.expectEqual(@as(u8, 0), evidenceCount(starter_owned));
    try std.testing.expectEqual(Stats{ .attack = 6, .defense = 2, .initiative = 4, .salvage_bias = 0 }, equippedStats(starter_loadout));
}

test "levels expand capacity and gate the discovery pool" {
    try std.testing.expectEqual(@as(u8, 6), capacityForLevel(1));
    try std.testing.expectEqual(@as(u8, 15), capacityForLevel(10));
    try std.testing.expectEqual(@as(u8, 15), capacityForLevel(99));

    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expect(definition(drop(9, i, 4, 1)).unlock_level == 1);
    }
}
