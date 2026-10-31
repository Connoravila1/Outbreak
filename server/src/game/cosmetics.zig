//! Cosmetics (DESIGN.md section 17): callsign colours and avatar frames. Bought with salvage in the
//! Store (price > 0), unlocked by an achievement (price 0; achievements.zig names the id) or found
//! in the field (price 0, `found`: a rare drop from airdrops, elites, raids and landmark caches).
//! Owned forever, no effect on play. Map themes are not offered (see DESIGN.md).

const std = @import("std");
const data = @import("data.zig");
const ach = @import("achievements.zig");
const Rng = @import("rng.zig").Rng;

const Pair = data.Pair;

pub const Kind = enum { color, frame };

pub const Cosmetic = struct {
    id: []const u8,
    kind: Kind,
    name: Pair,
    text: []const u8,
    /// Salvage price; 0 means it cannot be bought, only earned or found.
    price: u32,
    /// Drop-only: found in the field, never sold. A duplicate converts to salvage.
    found: bool = false,
    /// Callsign colours: the hex to draw it in on each lens (paper needs a dark one, thermal a bright one).
    survey: ?[]const u8 = null,
    heat: ?[]const u8 = null,
    /// Earned by finishing this event's goal at silver tier (data.events names the id back).
    event: ?data.EventType = null,
    /// Sold only at the Event Exchange, while an event is live (data.event_exchange has the price).
    exchange: bool = false,
};

fn pair(human: []const u8, zombie: []const u8) Pair {
    return .{ .human = human, .zombie = zombie };
}

pub const list = [_]Cosmetic{
    .{ .id = "color_amber", .kind = .color, .name = pair("Hazard Amber", "Fever Amber"), .text = "Your callsign in amber.", .price = 250, .survey = "#A5690B", .heat = "#FFB347" },
    .{ .id = "color_blue", .kind = .color, .name = pair("Survey Blue", "Cold Blue"), .text = "Your callsign in blue.", .price = 250, .survey = "#2F6EA3", .heat = "#8FB3E8" },
    .{ .id = "color_moss", .kind = .color, .name = pair("Moss", "Mould"), .text = "Your callsign in green.", .price = 300, .survey = "#3E6B36", .heat = "#9CCB7E" },
    .{ .id = "color_oxblood", .kind = .color, .name = pair("Oxblood", "Arterial"), .text = "Your callsign in dark red.", .price = 300, .survey = "#8E2424", .heat = "#FF7A7A" },
    .{ .id = "color_violet", .kind = .color, .name = pair("Violet Ink", "Bruise"), .text = "Your callsign in violet.", .price = 400, .survey = "#5B459A", .heat = "#BBA2F0" },
    .{ .id = "color_teal", .kind = .color, .name = pair("Verdigris", "Gill"), .text = "Your callsign in teal.", .price = 400, .survey = "#1D6E69", .heat = "#6FD6CB" },
    .{ .id = "color_gold", .kind = .color, .name = pair("Heirloom Gold", "Trophy Gold"), .text = "Your callsign in gold. Earned by finding a named Legendary.", .price = 0, .survey = "#8F6A00", .heat = "#FFD36B" },
    .{ .id = "frame_grease", .kind = .frame, .name = pair("Grease Pencil", "Scorch Ring"), .text = "A hand-drawn loop around your portrait.", .price = 400 },
    .{ .id = "frame_tape", .kind = .frame, .name = pair("Hazard Tape", "Bandage Wrap"), .text = "Striped tape, wound around the edge.", .price = 500 },
    .{ .id = "frame_stitch", .kind = .frame, .name = pair("Stitched", "Sutured"), .text = "A seam of heavy stitches.", .price = 600 },
    .{ .id = "frame_reticle", .kind = .frame, .name = pair("Crosshair", "Prey Sight"), .text = "Corner brackets and tick marks.", .price = 800 },
    .{ .id = "frame_barbed", .kind = .frame, .name = pair("Barbed Wire", "Bramble"), .text = "A ring of wire and barbs.", .price = 1000 },
    .{ .id = "frame_bloom", .kind = .frame, .name = pair("Kessler Bloom", "The Bloom"), .text = "Spores creeping round the frame. Earned by claiming four sets of notes.", .price = 0 },
    .{ .id = "frame_wreath", .kind = .frame, .name = pair("Laurels", "Thorn Crown"), .text = "A wreath for the last survivor. Earned by reaching level 50.", .price = 0 },
    // Event cosmetics: earned in a limited-time event (DESIGN.md section 18), never sold.
    .{ .id = "color_bloodmoon", .kind = .color, .name = pair("Blood Moon Red", "Red Feast"), .text = "Your callsign in blood red. Earned in the Blood Moon event.", .price = 0, .survey = "#9B1C1C", .heat = "#FF5A5A", .event = .blood_moon },
    .{ .id = "color_supply", .kind = .color, .name = pair("Crate Orange", "Carrion Orange"), .text = "Your callsign in crate orange. Earned in the Supply Run event.", .price = 0, .survey = "#B54A00", .heat = "#FF9A3D", .event = .supply_run },
    .{ .id = "color_lastlight", .kind = .color, .name = pair("Dawn Pink", "Frenzy Pink"), .text = "Your callsign in pink. Earned in the Last Light event.", .price = 0, .survey = "#9A2F68", .heat = "#FF9CCB", .event = .last_light },
    .{ .id = "frame_horde", .kind = .frame, .name = pair("Tally Marks", "Claw Marks"), .text = "Scratches round the portrait. Earned in the Swarm event.", .price = 0, .event = .horde },
    .{ .id = "frame_echo", .kind = .frame, .name = pair("Static", "Afterimage"), .text = "A doubled ring that will not hold still. Earned in the Echo event.", .price = 0, .event = .echo_week },
    .{ .id = "frame_dayzero", .kind = .frame, .name = pair("Quarantine Seal", "Open Wound"), .text = "A broken seal round the portrait. Earned in the monthly Day Zero event.", .price = 0, .event = .day_zero },
    // Sold only at the Event Exchange.
    .{ .id = "color_gilt", .kind = .color, .name = pair("Gilt Ink", "Gilded Rot"), .text = "Your callsign in gilt. Sold only at the Event Exchange.", .price = 0, .survey = "#6B5A12", .heat = "#F2E28B", .exchange = true },
    .{ .id = "frame_gilt", .kind = .frame, .name = pair("Gilt Frame", "Gilded Frame"), .text = "A gilt ring round the portrait. Sold only at the Event Exchange.", .price = 0, .exchange = true },
    .{ .id = "color_tag", .kind = .color, .name = pair("Bus Stop Tag", "Livid"), .text = "Your callsign in spray-can magenta. Found in the field.", .price = 0, .found = true, .survey = "#A0246B", .heat = "#FF8AC8" },
    .{ .id = "color_glow", .kind = .color, .name = pair("Dead Glowstick", "Marrow Glow"), .text = "Your callsign in a dying chemical green. Found in the field.", .price = 0, .found = true, .survey = "#5A7A0A", .heat = "#D4F26B" },
    .{ .id = "frame_fence", .kind = .frame, .name = pair("Cut Fence", "Rib Cage"), .text = "A scrap of chain-link, bent round your portrait. Found in the field.", .price = 0, .found = true },
    .{ .id = "frame_flare", .kind = .frame, .name = pair("Spent Flare", "Cinder Crown"), .text = "The last sparks of a road flare. Found in the field.", .price = 0, .found = true },
};

pub fn find(id: []const u8) ?u8 {
    for (list, 0..) |c, i| {
        if (std.mem.eql(u8, c.id, id)) return @intCast(i);
    }
    return null;
}

/// The achievement that unlocks cosmetic `id`, if it is an earned one.
pub fn unlockedBy(id: []const u8) ?u8 {
    for (ach.list, 0..) |a, i| {
        if (a.cosmetic) |c| {
            if (std.mem.eql(u8, c, id)) return @intCast(i);
        }
    }
    return null;
}

test "ids are unique, prices sit in the designed range, colours carry both hexes" {
    for (list, 0..) |c, i| {
        try std.testing.expectEqual(@as(?u8, @intCast(i)), find(c.id));
        try std.testing.expect(c.name.human.len > 0 and c.name.zombie.len > 0 and c.text.len > 0);
        if (c.price != 0) try std.testing.expect(c.price >= 250 and c.price <= 1000);
        try std.testing.expectEqual(c.kind == .color, c.survey != null and c.heat != null);
        // The id says what it is.
        try std.testing.expect(std.mem.startsWith(u8, c.id, if (c.kind == .color) "color_" else "frame_"));
    }
}

/// Where a found cosmetic can drop from, and the chance per event. Tuned with `zig build sim` so a
/// dedicated player finds one about every 15 to 30 hours of play.
pub const Source = enum { airdrop, elite, landmark, raid_top, raid };

pub fn dropChance(src: Source) f64 {
    return switch (src) {
        .airdrop => 0.08,
        .elite => 0.006,
        .landmark => 0.016,
        .raid_top => 0.40,
        .raid => 0.15,
    };
}

/// One roll for a find from `src`: an index into `list`, or null. Uniform over the found cosmetics.
/// `odds` scales the chance (1 outside dev servers and tests).
pub fn roll(rng: *Rng, src: Source, odds: f64) ?u8 {
    if (!rng.chance(@min(1.0, dropChance(src) * odds))) return null;
    return found_list[rng.below(found_count)];
}

/// Salvage paid instead when a found cosmetic turns up again.
pub fn duplicateSalvage(c: Cosmetic) u32 {
    return if (c.kind == .color) 150 else 250;
}

/// Cosmetics that can drop, in catalogue order.
pub const found_count = blk: {
    var n: usize = 0;
    for (list) |c| {
        if (c.found) n += 1;
    }
    break :blk n;
};

pub const found_list = blk: {
    var out: [found_count]u8 = undefined;
    var n: usize = 0;
    for (list, 0..) |c, i| {
        if (c.found) {
            out[n] = @intCast(i);
            n += 1;
        }
    }
    break :blk out;
};

test "every cosmetic is for sale, earned or found; never two, never none" {
    for (list) |c| {
        const earned = unlockedBy(c.id) != null or c.event != null or c.exchange;
        try std.testing.expect((c.price == 0) == (earned or c.found));
        // Only one way to get it.
        const ways = @as(u8, @intFromBool(unlockedBy(c.id) != null)) + @intFromBool(c.event != null) + @intFromBool(c.exchange) + @intFromBool(c.found);
        try std.testing.expect(ways <= 1);
    }
    // Each event names a cosmetic that names it back; the Exchange sells the cosmetics it lists.
    for (data.events) |e| {
        const c = list[find(e.cosmetic).?];
        try std.testing.expectEqual(@as(?data.EventType, e.id), c.event);
    }
    for (data.event_exchange) |x| {
        if (find(x.sku)) |i| try std.testing.expect(list[i].exchange);
    }
    for (list) |c| {
        if (c.exchange) try std.testing.expect(data.findExchange(c.id) != null);
    }
    try std.testing.expectEqual(@as(usize, 4), found_count);
    for (ach.list) |a| {
        if (a.cosmetic) |c| try std.testing.expect(find(c) != null);
    }
}

test "finds are rare, only ever found cosmetics, and the odds scale" {
    var rng = Rng.init(77);
    var hits = [_]u32{0} ** list.len;
    var airdrops: f64 = 0;
    const n = 200_000;
    for (0..n) |_| {
        if (roll(&rng, .airdrop, 1.0)) |i| {
            airdrops += 1;
            hits[i] += 1;
            try std.testing.expect(list[i].found);
        }
    }
    try std.testing.expectApproxEqAbs(dropChance(.airdrop), airdrops / n, 0.004);
    // Every found cosmetic turns up, about equally often.
    for (found_list) |i| try std.testing.expectApproxEqRel(airdrops / found_count, @as(f64, @floatFromInt(hits[i])), 0.15);
    // Per event an elite is rarer than a landmark, which is rarer than an airdrop; a raid's top
    // three do better than the rest; odds of 0 shut a source off.
    try std.testing.expect(dropChance(.elite) < dropChance(.landmark) and dropChance(.landmark) < dropChance(.airdrop));
    try std.testing.expect(dropChance(.raid) < dropChance(.raid_top));
    for (0..1000) |_| try std.testing.expectEqual(@as(?u8, null), roll(&rng, .raid_top, 0.0));
    for (0..100) |_| try std.testing.expect(roll(&rng, .elite, 1000.0) != null);
}
