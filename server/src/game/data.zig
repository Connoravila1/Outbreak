//! The catalogue: every item, rarity, perk, ability, consumable, enemy and title, as comptime
//! tables. docs/DESIGN.md is the source of truth for the numbers; keep them in step.
//! Text in here ships to players.

const std = @import("std");

pub const Faction = enum {
    human,
    zombie,

    pub fn opposite(self: Faction) Faction {
        return if (self == .human) .zombie else .human;
    }
};

pub const Slot = enum { weapon, armor, utility };
pub const Rarity = enum { common, uncommon, rare, legendary };
pub const Perk = enum { keen, swift, brutal, sturdy, vital, leech, thorns, lucky };

/// All 14 abilities. The tag name is the wire id.
pub const Ability = enum {
    second_wind,
    devour,
    aimed_shot,
    pounce,
    barricade,
    calcify,
    adrenaline,
    bloodlust,
    molotov,
    infectious_bite,
    overwatch,
    swarm,
    last_stand,
    undying,
};

pub const Consumable = enum { heal_s, heal_m, revive, buff_atk, buff_def, buff_spd, buff_xp, buff_loot, flag };

pub const Archetype = enum { shambler, runner, bloater, brute, horde, screamer, abomination };

/// How a fight is approached; chosen before engaging (DESIGN.md section 4, Stance).
pub const Stance = enum { aggressive, careful, evasive };

pub const max_level: u8 = 50;

/// A pair of strings, one per faction.
pub const Pair = struct {
    human: []const u8,
    zombie: []const u8,

    pub fn get(self: Pair, faction: Faction) []const u8 {
        return switch (faction) {
            .human => self.human,
            .zombie => self.zombie,
        };
    }
};

fn pair(human: []const u8, zombie: []const u8) Pair {
    return .{ .human = human, .zombie = zombie };
}

/// Integer stats; what players see. Item stats may be negative (SPD penalties).
pub const Stats = struct {
    hp: i32 = 0,
    atk: i32 = 0,
    def: i32 = 0,
    spd: i32 = 0,
};

// --- Faction traits ------------------------------------------------------------------------

pub const Trait = struct {
    faction: Faction,
    name: []const u8,
    text: []const u8,
};

/// The numbers live in stats.zig (`resolve_*`, `hunger_*`).
pub const traits = [_]Trait{
    .{ .faction = .human, .name = "Resolve", .text = "+10% Defense and +5% max HP. Healing items are 25% stronger." },
    .{ .faction = .zombie, .name = "Hunger", .text = "+5% Attack. Heal 5% of the damage you deal. Regenerate 25% faster." },
};

pub fn trait(f: Faction) Trait {
    return traits[@intFromEnum(f)];
}

// --- Rarities ------------------------------------------------------------------------------

pub const RarityRow = struct {
    id: Rarity,
    name: []const u8,
    /// Stat multiplier.
    mult: f32,
    perks: u8,
    /// Drop weight.
    weight: f32,
    /// Scrap salvage before the (1 + req/10) factor.
    salvage: u16,
    /// Upgrade cost factor.
    rarity_cost: f32,
};

pub const rarities = [_]RarityRow{
    .{ .id = .common, .name = "Common", .mult = 1.00, .perks = 0, .weight = 64, .salvage = 3, .rarity_cost = 1.0 },
    .{ .id = .uncommon, .name = "Uncommon", .mult = 1.20, .perks = 0, .weight = 26, .salvage = 8, .rarity_cost = 1.3 },
    .{ .id = .rare, .name = "Rare", .mult = 1.45, .perks = 1, .weight = 8.5, .salvage = 20, .rarity_cost = 1.7 },
    .{ .id = .legendary, .name = "Legendary", .mult = 1.80, .perks = 2, .weight = 1.5, .salvage = 50, .rarity_cost = 2.2 },
};

pub fn rarity(r: Rarity) RarityRow {
    return rarities[@intFromEnum(r)];
}

// --- Perks ---------------------------------------------------------------------------------

pub const PerkRow = struct { id: Perk, name: []const u8, text: []const u8 };

pub const perks = [_]PerkRow{
    .{ .id = .keen, .name = "Keen", .text = "+6% critical chance." },
    .{ .id = .swift, .name = "Swift", .text = "+8% Speed." },
    .{ .id = .brutal, .name = "Brutal", .text = "+8% Attack." },
    .{ .id = .sturdy, .name = "Sturdy", .text = "+8% Defense." },
    .{ .id = .vital, .name = "Vital", .text = "+10% max HP." },
    .{ .id = .leech, .name = "Leech", .text = "Heal 5% of the damage you deal." },
    .{ .id = .thorns, .name = "Thorns", .text = "Reflect 8% of the damage you take." },
    .{ .id = .lucky, .name = "Lucky", .text = "+15% loot chance." },
};

pub fn perk(p: Perk) PerkRow {
    return perks[@intFromEnum(p)];
}

// --- Base items ----------------------------------------------------------------------------

pub const BaseItem = struct {
    id: []const u8,
    slot: Slot,
    /// Required level.
    req: u8,
    name: Pair,
    /// Common +0 stats.
    stats: Stats,
    flavour: Pair,
};

fn weapon(id: []const u8, req: u8, h: []const u8, z: []const u8, atk: i32, spd: i32, def: i32, fh: []const u8, fz: []const u8) BaseItem {
    return .{ .id = id, .slot = .weapon, .req = req, .name = pair(h, z), .stats = .{ .atk = atk, .spd = spd, .def = def }, .flavour = pair(fh, fz) };
}

fn armor(id: []const u8, req: u8, h: []const u8, z: []const u8, def: i32, hp: i32, spd: i32, fh: []const u8, fz: []const u8) BaseItem {
    return .{ .id = id, .slot = .armor, .req = req, .name = pair(h, z), .stats = .{ .def = def, .hp = hp, .spd = spd }, .flavour = pair(fh, fz) };
}

fn gear(id: []const u8, req: u8, h: []const u8, z: []const u8, atk: i32, def: i32, spd: i32, hp: i32, fh: []const u8, fz: []const u8) BaseItem {
    return .{ .id = id, .slot = .utility, .req = req, .name = pair(h, z), .stats = .{ .atk = atk, .def = def, .spd = spd, .hp = hp }, .flavour = pair(fh, fz) };
}

const weapon_rows = [_]BaseItem{
    weapon("kitchen_knife", 1, "Kitchen Knife", "Broken Nails", 5, 3, 0, "Dull on one side, honest on the other.", "Torn to the quick. They still find the soft places."),
    weapon("baseball_bat", 1, "Baseball Bat", "Rotten Teeth", 7, 0, 0, "Somebody's trophy once. Now it just works.", "Loose, black and hungry. They hold."),
    weapon("crowbar", 3, "Crowbar", "Bone Spur", 8, 0, 2, "Opens crates, doors and skulls.", "A splinter of yourself, sharpened by rot."),
    weapon("machete", 5, "Machete", "Jagged Claws", 10, 3, 0, "Long, light and forgiving of bad aim.", "Keratin gone to hooks. They catch and they tear."),
    weapon("fire_axe", 8, "Fire Axe", "Crushing Fist", 14, -1, 0, "It was behind glass. In case of emergency.", "The hand swelled and hardened. It remembers how to close."),
    weapon("revolver", 11, "Revolver", "Spitter Gland", 15, 4, 0, "Six shots. Count them.", "A swollen sac under the jaw. It spits something that eats."),
    weapon("compound_bow", 14, "Compound Bow", "Lashing Tendril", 17, 6, 0, "Quiet, patient, and good in tall grass.", "It unspools from the wrist and finds you at range."),
    weapon("pump_shotgun", 17, "Pump Shotgun", "Gaping Maw", 22, -2, 0, "Racking it is half the argument.", "The jaw unhinges. There is a lot of throat in there."),
    weapon("katana", 21, "Katana", "Razor Talons", 22, 7, 0, "Someone's pride, someone's grief. Still sharp.", "Bone filed to a hair's edge. Silent through cloth and meat."),
    weapon("hunting_rifle", 25, "Hunting Rifle", "Barbed Tongue", 27, 3, 0, "One shot from the tree line. Make it count.", "Whip-quick, hooked, a metre longer than it should be."),
    weapon("assault_rifle", 29, "Assault Rifle", "Acid Glands", 30, 5, 0, "Military issue. The last of its kind in town.", "Weeping sacs along the arms. What they touch dissolves."),
    weapon("chainsaw", 34, "Chainsaw", "Bone Saw Arm", 37, -3, 3, "Loud enough to ring the dinner bell. Worth it.", "Serrated bone, grown where a forearm used to be."),
    weapon("flamethrower", 39, "Flamethrower", "Bile Cannon", 40, 0, 0, "Burn the nests. Burn everything.", "A throat full of something that boils."),
    weapon("prototype_railgun", 44, "Prototype Railgun", "Hivemind Lance", 46, 4, 0, "Never meant to leave the lab. It was not asked.", "A spear of shared thought, thrown by a thousand minds."),
};

const armor_rows = [_]BaseItem{
    armor("hoodie", 1, "Hoodie", "Torn Skin", 3, 5, 1, "Grey cotton. Better than nothing, barely.", "Hanging in flaps. It hurts less than it should."),
    armor("leather_jacket", 1, "Leather Jacket", "Thick Hide", 4, 8, 0, "Thick enough to turn a bite, if you're lucky.", "Skin that learned to harden."),
    armor("hockey_pads", 4, "Hockey Pads", "Calloused Flesh", 6, 12, 0, "Built for slapshots. Teeth are nearly the same.", "Scar over scar over scar."),
    armor("motorcycle_leathers", 7, "Motorcycle Leathers", "Gristle Plates", 8, 18, 0, "Made to be dragged down asphalt.", "Cartilage in layers, tough as a tyre wall."),
    armor("riot_vest", 10, "Riot Vest", "Bone Plating", 11, 22, -1, "Police issue. It remembers worse nights than this.", "Ribs grown outward into a shell."),
    armor("kevlar_vest", 14, "Kevlar Vest", "Chitin Shell", 13, 30, 0, "Stops bullets, mostly. Teeth, definitely.", "Something insectile crawled in and stayed."),
    armor("hazmat_suit", 18, "Hazmat Suit", "Fungal Carapace", 15, 40, 0, "Sealed and ugly. The yellow is a promise.", "A crust of spores that hardens in the cold."),
    armor("swat_armor", 23, "SWAT Armor", "Necrotic Mass", 19, 50, -1, "Full kit from the armoury van. Heavy, worth it.", "Dead tissue that refuses to stop working."),
    armor("ghillie_rig", 28, "Ghillie Rig", "Shadow Skin", 18, 45, 5, "Burlap and branches. Be part of the hedge.", "Pale, mottled, strangely hard to see."),
    armor("military_plate", 33, "Military Plate", "Ironbone Hulk", 25, 70, -2, "Ceramic plates, a name stitched on the chest.", "The skeleton thickened to iron."),
    armor("exo_frame", 38, "Exo-Frame", "Abomination Shell", 29, 85, 0, "Powered joints, humming. It still holds a charge.", "Too many ribs. Too many layers."),
    armor("juggernaut_suit", 44, "Juggernaut Suit", "Titan Carapace", 34, 110, -2, "Bomb-squad plate. Walks toward the problem.", "A wall that breathes."),
};

const gear_rows = [_]BaseItem{
    gear("flashlight", 1, "Flashlight", "Night Eyes", 0, 1, 3, 0, "Four batteries and a weak beam. Enough.", "Pupils wide and wet. The dark has depth."),
    gear("backpack", 1, "Backpack", "Scavenger Gut", 0, 2, 0, 10, "Broken zip, stitched pockets, room for one more can.", "A second stomach that never stops digesting."),
    gear("walkie_talkie", 4, "Walkie-Talkie", "Hive Whisper", 2, 0, 4, 0, "Static, then a voice. Sometimes.", "A hum behind the eyes. The others are near."),
    gear("binoculars", 7, "Binoculars", "Keen Scent", 3, 0, 5, 0, "See them before they see you.", "Nostrils flared wide. Fear has a smell."),
    gear("gas_mask", 10, "Gas Mask", "Spore Lungs", 0, 5, 2, 15, "Filters the air. Mostly the smell.", "Breathes what would kill you, and thrives."),
    gear("night_vision", 14, "Night Vision", "Pale Sight", 3, 2, 7, 0, "A green world with no place to hide.", "White eyes that see heat and heartbeat."),
    gear("combat_stims", 19, "Combat Stims", "Fever Strain", 6, 0, 6, 0, "Unlabelled. Stay awake. Don't ask.", "A burning in the blood. The body hurries."),
    gear("drone_scout", 24, "Drone Scout", "Carrion Swarm", 5, 3, 8, 10, "A little eye in the sky, one rotor squealing.", "Flies obey. They go where the meat is."),
    gear("tactical_exo_brace", 30, "Tactical Exo-Brace", "Adrenal Gland", 8, 5, 6, 20, "Carbon struts and servo knees. It takes the weight.", "Overgrown, pulsing, always ready."),
    gear("field_medic_kit", 37, "Field Medic Kit", "Regenerative Strain", 4, 8, 4, 45, "Staples, clamps, morphine. Keep one patient alive.", "Wounds close as soon as they open."),
    gear("signal_jammer", 43, "Signal Jammer", "Mind Blight", 10, 6, 10, 25, "Silence the radios. Silence the dead.", "A thought that spreads. It speaks in your voice."),
};

/// All base items: weapons, then armor, then gear/strain, each ordered by required level.
pub const bases = weapon_rows ++ armor_rows ++ gear_rows;

pub fn findBase(id: []const u8) ?u8 {
    for (bases, 0..) |b, i| {
        if (std.mem.eql(u8, b.id, id)) return @intCast(i);
    }
    return null;
}

// --- Legendary uniques ---------------------------------------------------------------------

pub const Unique = struct {
    id: []const u8,
    /// Id of the base item this unique replaces.
    base: []const u8,
    name: Pair,
    lore: Pair,
    perks: [2]Perk,
};

pub const uniques = [_]Unique{
    .{ .id = "old_faithful", .base = "baseball_bat", .name = pair("Old Faithful", "The First Bite"), .perks = .{ .brutal, .lucky }, .lore = pair(
        "Dad swore it never missed.",
        "The first of them to bite the neighbourhood. These are the teeth.",
    ) },
    .{ .id = "the_last_word", .base = "pump_shotgun", .name = pair("The Last Word", "Hungry Hungry"), .perks = .{ .brutal, .keen }, .lore = pair(
        "Scratched into the stock: no second opinions.",
        "It never stops asking for more.",
    ) },
    .{ .id = "moonlight", .base = "katana", .name = pair("Moonlight", "Nightreaper"), .perks = .{ .swift, .keen }, .lore = pair(
        "It only comes out after dark. So do they.",
        "Nobody sees it swing. Nobody sees it at all.",
    ) },
    .{ .id = "the_wall", .base = "riot_vest", .name = pair("The Wall", "Ossuary"), .perks = .{ .sturdy, .thorns }, .lore = pair(
        "Worn on the line for three nights. It held.",
        "A cage of old bones, and every one remembers.",
    ) },
    .{ .id = "clean_room", .base = "hazmat_suit", .name = pair("Clean Room", "The Bloom"), .perks = .{ .vital, .sturdy }, .lore = pair(
        "The seals are perfect. The one inside is not.",
        "Where the spores bloom, nothing else survives.",
    ) },
    .{ .id = "dead_air", .base = "signal_jammer", .name = pair("Dead Air", "The Choir"), .perks = .{ .swift, .leech }, .lore = pair(
        "One quiet channel in a whole noisy world.",
        "Ten thousand voices, one song. You hear it too.",
    ) },
};

pub fn findUnique(id: []const u8) ?u8 {
    for (uniques, 0..) |u, i| {
        if (std.mem.eql(u8, u.id, id)) return @intCast(i);
    }
    return null;
}

// --- Consumables ---------------------------------------------------------------------------

pub const ConsumableRow = struct {
    id: Consumable,
    name: Pair,
    /// Effect, in plain words.
    text: []const u8,
    flavour: Pair,
    /// Store price in salvage.
    price: u32,
};

pub const consumables = [_]ConsumableRow{
    .{ .id = .heal_s, .name = pair("Bandage", "Raw Meat"), .text = "Heal 25% of max HP.", .price = 20, .flavour = pair("Clean gauze. It stops the worst.", "Still warm.") },
    .{ .id = .heal_m, .name = pair("First Aid Kit", "Fresh Kill"), .text = "Heal 60% of max HP.", .price = 50, .flavour = pair("Red cross, half the contents missing.", "A proper meal. The wounds knit.") },
    .{ .id = .revive, .name = pair("Trauma Kit", "Mutagen Vial"), .text = "Get up at once from Downed with full HP, or fully heal.", .price = 120, .flavour = pair("Adrenaline, a defib pad and a prayer.", "Something glowing. Drink, and rise.") },
    .{ .id = .buff_atk, .name = pair("Adrenaline Shot", "Rage Gland"), .text = "+15% Attack for 30 minutes.", .price = 60, .flavour = pair("Straight to the heart. Don't look at the needle.", "Bitter, swollen, furious.") },
    .{ .id = .buff_def, .name = pair("Painkillers", "Bone Marrow"), .text = "+15% Defense for 30 minutes.", .price = 60, .flavour = pair("Hurt later.", "Cracked open. Dense, rich, fortifying.") },
    .{ .id = .buff_spd, .name = pair("Energy Drink", "Fever Gland"), .text = "+15% Speed for 30 minutes.", .price = 60, .flavour = pair("Neon, sugary, wired.", "Hot to the touch. The legs go faster.") },
    .{ .id = .buff_xp, .name = pair("Field Manual", "Hive Memory"), .text = "+25% XP for 30 minutes.", .price = 60, .flavour = pair("Dog-eared. Someone wrote down what worked.", "A borrowed past. The hive remembers how.") },
    .{ .id = .buff_loot, .name = pair("Lucky Coin", "Carrion Scent"), .text = "+50% cache and loot chance for 30 minutes.", .price = 60, .flavour = pair("Heads, you eat tonight.", "Rub it on. The good meat finds you.") },
    .{ .id = .flag, .name = pair("Territory Flag", "Infestation Marker"), .text = "Claim a Stronghold for your clan.", .price = 300, .flavour = pair("Plant it. Say this ground is ours.", "A pulsing growth. This ground is ours.") },
};

pub fn consumable(c: Consumable) ConsumableRow {
    return consumables[@intFromEnum(c)];
}

// --- Landmarks (real places) ---------------------------------------------------------------

/// The kinds of real place that hold a supply cache. Wire names are the tag names.
pub const PlaceKind = enum { pharmacy, grocery, hardware, fuel, police, outfitter, diner };

pub const PlaceRow = struct {
    id: PlaceKind,
    name: Pair,
    /// What it tends to hold, in each faction's voice.
    text: Pair,
    /// Chance that a roll is an item (otherwise a consumable).
    item_chance: f32,
    /// Relative weight of a weapon / armor / utility base when an item drops.
    slot_weights: [3]f32 = .{ 1, 1, 1 },
    /// Relative weights of consumables, in `Consumable` order (flags never drop).
    consumable_weights: [9]f64,
    min_rarity: Rarity = .common,
    legendary_mult: f32 = 1.0,
    /// Extra salvage on top of the +25% every landmark cache pays.
    salvage_extra: f32 = 0,
};

pub const place_kinds = [_]PlaceRow{
    .{ .id = .pharmacy, .name = pair("Pharmacy", "Sick Ward"), .item_chance = 0.15, .consumable_weights = .{ 28, 30, 14, 2, 4, 2, 2, 2, 0 }, .text = pair(
        "Bandages, kits and the odd trauma kit.",
        "the sick are fed here. fresh kills, and a vial that raises the dead.",
    ) },
    .{ .id = .grocery, .name = pair("Grocery", "Larder"), .item_chance = 0.20, .consumable_weights = .{ 50, 24, 2, 3, 3, 3, 4, 4, 0 }, .salvage_extra = 0.25, .text = pair(
        "Food and first aid, and plenty to scrap.",
        "meat on the hook. scraps worth chewing.",
    ) },
    .{ .id = .hardware, .name = pair("Hardware Store", "Scrap Heap"), .item_chance = 0.60, .slot_weights = .{ 4, 1, 1 }, .consumable_weights = .{ 30, 15, 2, 8, 8, 6, 3, 6, 0 }, .salvage_extra = 0.25, .text = pair(
        "Weapons off the rack and salvage for upgrades.",
        "claws and bone, heaped high. good for sharpening.",
    ) },
    .{ .id = .fuel, .name = pair("Gas Station", "Fume Pit"), .item_chance = 0.25, .consumable_weights = .{ 14, 6, 1, 18, 18, 18, 4, 14, 0 }, .salvage_extra = 0.25, .text = pair(
        "Energy drinks, painkillers and whatever was left in the trunks.",
        "the fumes sharpen everything. glands, still twitching.",
    ) },
    .{ .id = .police, .name = pair("Police Station", "Barracks"), .item_chance = 0.70, .slot_weights = .{ 1, 4, 1 }, .consumable_weights = .{ 20, 20, 6, 8, 10, 6, 4, 4, 0 }, .min_rarity = .uncommon, .legendary_mult = 2.0, .text = pair(
        "Riot gear and better. The lockers are rarely empty.",
        "hardened hides on racks. the best are kept back.",
    ) },
    .{ .id = .outfitter, .name = pair("Outfitter", "Shed Skins"), .item_chance = 0.65, .slot_weights = .{ 0.5, 3, 3 }, .consumable_weights = .{ 30, 16, 2, 4, 8, 8, 3, 4, 0 }, .text = pair(
        "Jackets, packs and the gear that goes with them.",
        "cast-off hides and strains, still warm.",
    ) },
    .{ .id = .diner, .name = pair("Diner", "Feeding Ground"), .item_chance = 0.20, .consumable_weights = .{ 36, 26, 2, 3, 3, 3, 16, 3, 0 }, .text = pair(
        "A hot meal and a map on the wall: food, and a field manual or two.",
        "the table is still set. a meal, and a memory.",
    ) },
};

pub fn placeKind(k: PlaceKind) PlaceRow {
    return place_kinds[@intFromEnum(k)];
}

// --- Abilities -----------------------------------------------------------------------------

pub const AbilityRow = struct {
    id: Ability,
    faction: Faction,
    level: u8,
    name: []const u8,
    text: []const u8,
    /// The other faction's version of the same ability.
    mirror: Ability,
};

pub const abilities = [_]AbilityRow{
    .{ .id = .second_wind, .faction = .human, .level = 3, .name = "Second Wind", .mirror = .devour, .text = "Once per fight, when your HP drops below 35%, heal 30% of your max HP." },
    .{ .id = .devour, .faction = .zombie, .level = 3, .name = "Devour", .mirror = .second_wind, .text = "Once per fight, when your HP drops below 35%, feed and heal 30% of your max HP." },
    .{ .id = .aimed_shot, .faction = .human, .level = 7, .name = "Aimed Shot", .mirror = .pounce, .text = "Your first attack is a guaranteed critical hit." },
    .{ .id = .pounce, .faction = .zombie, .level = 7, .name = "Pounce", .mirror = .aimed_shot, .text = "You always act first on turn 1, and your first attack is a guaranteed critical hit." },
    .{ .id = .barricade, .faction = .human, .level = 12, .name = "Barricade", .mirror = .calcify, .text = "Take 35% less damage for the first 3 turns." },
    .{ .id = .calcify, .faction = .zombie, .level = 12, .name = "Calcify", .mirror = .barricade, .text = "Your skin hardens: take 35% less damage for the first 3 turns." },
    .{ .id = .adrenaline, .faction = .human, .level = 18, .name = "Adrenaline", .mirror = .bloodlust, .text = "While your HP is below 50%: +25% Speed and +15% Attack." },
    .{ .id = .bloodlust, .faction = .zombie, .level = 18, .name = "Bloodlust", .mirror = .adrenaline, .text = "Each hit you land gives +6% Attack, up to 5 stacks." },
    .{ .id = .molotov, .faction = .human, .level = 25, .name = "Molotov", .mirror = .infectious_bite, .text = "Your first hit sets the target ablaze: 5% of its max HP per turn for 4 turns." },
    .{ .id = .infectious_bite, .faction = .zombie, .level = 25, .name = "Infectious Bite", .mirror = .molotov, .text = "Your first hit infects the target: 5% of its max HP per turn for 4 turns." },
    .{ .id = .overwatch, .faction = .human, .level = 33, .name = "Overwatch", .mirror = .swarm, .text = "20% chance each turn to make an extra attack." },
    .{ .id = .swarm, .faction = .zombie, .level = 33, .name = "Swarm", .mirror = .overwatch, .text = "20% chance each turn to make an extra attack." },
    .{ .id = .last_stand, .faction = .human, .level = 42, .name = "Last Stand", .mirror = .undying, .text = "Once per fight, a lethal hit leaves you at 1 HP, and you gain +30% Attack." },
    .{ .id = .undying, .faction = .zombie, .level = 42, .name = "Undying", .mirror = .last_stand, .text = "Once per fight, a lethal hit raises you again at 25% HP, and you gain +30% Attack." },
};

pub fn ability(a: Ability) AbilityRow {
    return abilities[@intFromEnum(a)];
}

// --- Enemy archetypes ----------------------------------------------------------------------

pub const ArchetypeRow = struct {
    id: Archetype,
    name: Pair,
    /// Multiples of a same-level player's base stats.
    hp: f32,
    atk: f32,
    def: f32,
    spd: f32,
    /// Spawn weight (percent). Zero: never spawns on the map.
    weight: f32,
    /// Extra multiplier on XP and loot chance.
    reward_mult: f32 = 1.0,
    /// Always drops a consumable.
    guaranteed_consumable: bool = false,
    note: []const u8,
    flavour: Pair,
    /// The stance that beats this enemy (+10% damage dealt, -10% taken), and the one it punishes
    /// (the reverse). Null: no relationship.
    counter: ?Stance = null,
    punished: ?Stance = null,
    /// What a player learns after fighting it a few times, in each faction's voice.
    hint: Pair = pair("", ""),
};

pub const archetypes = [_]ArchetypeRow{
    .{ .id = .shambler, .name = pair("Shambler", "Scavenger"), .hp = 0.8, .atk = 0.8, .def = 0.8, .spd = 0.7, .weight = 40, .note = "Common", .flavour = pair(
        "Slow, stupid, relentless. It falls apart and keeps coming.",
        "Picks through the ruins for tins and boots. Wary, thin, armed with a pipe.",
    ), .hint = pair("Shamblers are slow and dull. Any footing will do.", "scavengers are slow and wary. any hunt works.") },
    .{ .id = .runner, .name = pair("Runner", "Scout"), .hp = 0.6, .atk = 0.8, .def = 0.6, .spd = 1.5, .weight = 20, .note = "Fast", .flavour = pair(
        "Fast, loud and starving. You hear it before you see it.",
        "Moves ahead of the group, watching the rooftops. Quick on its feet.",
    ), .counter = .careful, .punished = .evasive, .hint = pair("Runners are fast — careful footing beats them.", "scouts dart. stalk them.") },
    .{ .id = .bloater, .name = pair("Bloater", "Barricader"), .hp = 1.6, .atk = 0.7, .def = 1.2, .spd = 0.6, .weight = 15, .note = "Tanky", .flavour = pair(
        "Swollen and slow, a wall of rotten meat. Do not pop it.",
        "Hides behind doors and bedsprings lashed to a shopping trolley.",
    ), .counter = .aggressive, .punished = .careful, .hint = pair("Bloaters soak up hits. Go in hard and break them.", "barricaders are walls. frenzy through them.") },
    .{ .id = .brute, .name = pair("Brute", "Soldier"), .hp = 1.3, .atk = 1.15, .def = 1.1, .spd = 0.8, .weight = 12, .note = "Strong", .flavour = pair(
        "Muscle that outlived the man.",
        "Kept his rifle and his discipline. He still counts you as a threat.",
    ), .counter = .evasive, .punished = .aggressive, .hint = pair("Brutes hit like trucks. Stay light and slip them.", "soldiers hit hard. slink around them.") },
    .{ .id = .horde, .name = pair("Horde", "Raider Gang"), .hp = 2.2, .atk = 0.9, .def = 0.8, .spd = 0.9, .weight = 8, .reward_mult = 1.5, .note = "Group, +50% XP and loot", .flavour = pair(
        "Two dozen, shoulder to shoulder. The street goes quiet.",
        "Five of them, a van and a grudge.",
    ), .counter = .careful, .punished = .aggressive, .hint = pair("A Horde swarms. Hold your ground and don't overreach.", "gangs swarm. stalk them, don't rush.") },
    .{ .id = .screamer, .name = pair("Screamer", "Medic"), .hp = 0.7, .atk = 0.6, .def = 0.7, .spd = 1.1, .weight = 5, .guaranteed_consumable = true, .note = "Rare, always drops a consumable", .flavour = pair(
        "Its cry draws every head on the street. Its pockets are full.",
        "A pale cross on the armband. Carries medicine, fights dirty.",
    ), .counter = .aggressive, .punished = .evasive, .hint = pair("Screamers are fragile. Hit them before they cry out.", "medics are soft. frenzy before they patch up.") },
    .{ .id = .abomination, .name = pair("Abomination", "Warlord"), .hp = 10.0, .atk = 1.6, .def = 1.3, .spd = 0.9, .weight = 0, .note = "Raid boss only", .flavour = pair(
        "Too big, too many arms. The district holds its breath.",
        "Crowned in scrap, owed a debt by everyone. It comes for you.",
    ) },
};

pub fn archetype(a: Archetype) ArchetypeRow {
    return archetypes[@intFromEnum(a)];
}

pub fn findArchetype(id: []const u8) ?Archetype {
    return std.meta.stringToEnum(Archetype, id);
}

/// Spawn weights by archetype index, for `Rng.weighted`.
pub const archetype_weights = blk: {
    var w: [archetypes.len]f64 = undefined;
    for (archetypes, 0..) |a, i| w[i] = a.weight;
    break :blk w;
};

// --- Titles, unlocks, store ------------------------------------------------------------------

/// One title per five levels: index = level / 5.
pub const titles = struct {
    pub const human = [_][]const u8{ "Survivor", "Forager", "Defender", "Ranger", "Sentinel", "Warden", "Vanguard", "Commander", "Hero", "Legend", "Last Hope" };
    pub const zombie = [_][]const u8{ "Turned", "Lurcher", "Lurker", "Stalker", "Ravager", "Mauler", "Alpha", "Dread", "Blight", "Plaguebringer", "Patient Zero" };
};

/// `key` is the stable name of an unlock; the client keys its first-time explainers on it.
pub const Unlock = struct { level: u8, key: []const u8, text: []const u8 };

pub const unlocks = [_]Unlock{
    .{ .level = 1, .key = "start", .text = "Starter kit, map, PvE, caches" },
    .{ .level = 2, .key = "store", .text = "The Store" },
    .{ .level = 3, .key = "ability_slot_1", .text = "Ability slot 1 and your first ability" },
    .{ .level = 4, .key = "upgrading", .text = "Item upgrading" },
    .{ .level = 5, .key = "contact", .text = "PvP protection ends: real-world fights begin" },
    .{ .level = 5, .key = "missions", .text = "Weekly missions" },
    .{ .level = 5, .key = "echoes", .text = "Echoes" },
    .{ .level = 7, .key = "ability_7", .text = "New ability: Aimed Shot / Pounce" },
    .{ .level = 8, .key = "airdrops", .text = "Airdrops become visible" },
    .{ .level = 10, .key = "clans", .text = "Clans" },
    .{ .level = 12, .key = "ability_slot_2", .text = "Ability slot 2, and Barricade / Calcify" },
    .{ .level = 15, .key = "territory", .text = "Territory: plant flags at Strongholds" },
    .{ .level = 18, .key = "ability_18", .text = "New ability: Adrenaline / Bloodlust" },
    .{ .level = 20, .key = "raids", .text = "Raids" },
    .{ .level = 25, .key = "ability_slot_3", .text = "Ability slot 3, and Molotov / Infectious Bite" },
    .{ .level = 30, .key = "legendary", .text = "Legendary drop rate +50%" },
    .{ .level = 33, .key = "ability_33", .text = "New ability: Overwatch / Swarm" },
    .{ .level = 42, .key = "ability_42", .text = "New ability: Last Stand / Undying" },
};

pub const Sku = struct {
    sku: []const u8,
    name: []const u8,
    price: u32,
    text: []const u8,
};

pub const store = [_]Sku{
    .{ .sku = "heal_s", .name = "Small heal", .price = 20, .text = "One Bandage / Raw Meat." },
    .{ .sku = "heal_m", .name = "Large heal", .price = 50, .text = "One First Aid Kit / Fresh Kill." },
    .{ .sku = "revive", .name = "Revive", .price = 120, .text = "One Trauma Kit / Mutagen Vial." },
    .{ .sku = "buff_atk", .name = "Attack buff", .price = 60, .text = "+15% Attack for 30 minutes." },
    .{ .sku = "buff_def", .name = "Defense buff", .price = 60, .text = "+15% Defense for 30 minutes." },
    .{ .sku = "buff_spd", .name = "Speed buff", .price = 60, .text = "+15% Speed for 30 minutes." },
    .{ .sku = "buff_xp", .name = "XP buff", .price = 60, .text = "+25% XP for 30 minutes." },
    .{ .sku = "buff_loot", .name = "Loot buff", .price = 60, .text = "+50% cache and loot chance for 30 minutes." },
    .{ .sku = "flag", .name = "Territory Flag", .price = 300, .text = "Claim a Stronghold for your clan. Level 15 and a clan required." },
    .{ .sku = "requisition", .name = "Supply Requisition", .price = 150, .text = "A random item of your level, Uncommon or better." },
    .{ .sku = "inventory", .name = "Inventory +10", .price = 400, .text = "Ten more slots. Each expansion costs 200 more than the last." },
    .{ .sku = "xp_boost", .name = "XP Boost", .price = 200, .text = "+50% XP for 1 hour." },
};

pub fn findSku(sku: []const u8) ?u8 {
    for (store, 0..) |s, i| {
        if (std.mem.eql(u8, s.sku, sku)) return @intCast(i);
    }
    return null;
}

/// Price of the nth inventory expansion (0-based): 400, then +200 each.
pub fn inventoryExpansionPrice(n: u32) u32 {
    return 400 + 200 * n;
}

test "tables line up with their enums" {
    for (rarities, 0..) |r, i| try std.testing.expectEqual(i, @intFromEnum(r.id));
    for (perks, 0..) |r, i| try std.testing.expectEqual(i, @intFromEnum(r.id));
    for (consumables, 0..) |r, i| try std.testing.expectEqual(i, @intFromEnum(r.id));
    for (abilities, 0..) |r, i| try std.testing.expectEqual(i, @intFromEnum(r.id));
    for (archetypes, 0..) |r, i| try std.testing.expectEqual(i, @intFromEnum(r.id));
}

test "catalogue sizes match the design" {
    try std.testing.expectEqual(@as(usize, 14), weapon_rows.len);
    try std.testing.expectEqual(@as(usize, 12), armor_rows.len);
    try std.testing.expectEqual(@as(usize, 11), gear_rows.len);
    try std.testing.expectEqual(@as(usize, 14), abilities.len);
    try std.testing.expectEqual(@as(usize, 6), uniques.len);
    try std.testing.expectEqual(@as(usize, 11), titles.human.len);
    try std.testing.expectEqual(@as(usize, 11), titles.zombie.len);
}

test "ids are unique, text is present, slots and levels sane" {
    for (bases, 0..) |b, i| {
        try std.testing.expect(b.name.human.len > 0 and b.name.zombie.len > 0);
        try std.testing.expect(b.flavour.human.len > 0 and b.flavour.zombie.len > 0);
        try std.testing.expect(b.req >= 1 and b.req <= max_level);
        try std.testing.expectEqual(@as(?u8, @intCast(i)), findBase(b.id));
    }
    // Each slot is ordered by required level (drop weighting relies on nothing, but players read it).
    var last_req = [_]u8{ 0, 0, 0 };
    for (bases) |b| {
        const s = @intFromEnum(b.slot);
        try std.testing.expect(b.req >= last_req[s]);
        last_req[s] = b.req;
    }
    for (consumables) |c| try std.testing.expect(c.flavour.human.len > 0 and c.text.len > 0);
    for (archetypes) |a| try std.testing.expect(a.flavour.human.len > 0 and a.flavour.zombie.len > 0);
}

test "uniques point at real legendary-capable bases" {
    for (uniques) |u| {
        try std.testing.expect(findBase(u.base) != null);
        try std.testing.expect(u.perks[0] != u.perks[1]);
        try std.testing.expect(u.lore.human.len > 0 and u.lore.zombie.len > 0);
    }
    try std.testing.expect(findUnique("old_faithful") != null);
}

test "abilities pair up and unlock at the designed levels" {
    const levels = [_]u8{ 3, 7, 12, 18, 25, 33, 42 };
    for (abilities, 0..) |a, i| {
        try std.testing.expectEqual(levels[i / 2], a.level);
        const m = ability(a.mirror);
        try std.testing.expectEqual(a.id, m.mirror);
        try std.testing.expectEqual(a.level, m.level);
        try std.testing.expect(a.faction != m.faction);
    }
}

test "spawn weights add to 100 without the raid boss" {
    var total: f64 = 0;
    for (archetype_weights) |w| total += w;
    try std.testing.expectEqual(@as(f64, 100), total);
}

test "store prices agree with consumable prices" {
    for (consumables) |c| {
        const idx = findSku(@tagName(c.id)).?;
        try std.testing.expectEqual(c.price, store[idx].price);
    }
    try std.testing.expectEqual(@as(u32, 600), inventoryExpansionPrice(1));
}
