//! Cosmetics (DESIGN.md section 17): callsign colours and avatar frames. Bought with salvage in the
//! Store (price > 0) or unlocked by an achievement (price 0; achievements.zig names the id).
//! Owned forever, no effect on play. Map themes are not offered (see DESIGN.md).

const std = @import("std");
const data = @import("data.zig");
const ach = @import("achievements.zig");

const Pair = data.Pair;

pub const Kind = enum { color, frame };

pub const Cosmetic = struct {
    id: []const u8,
    kind: Kind,
    name: Pair,
    text: []const u8,
    /// Salvage price; 0 means it cannot be bought, only earned.
    price: u32,
    /// Callsign colours: the hex to draw it in on each lens (paper needs a dark one, thermal a bright one).
    survey: ?[]const u8 = null,
    heat: ?[]const u8 = null,
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

test "every cosmetic is either for sale or earned, never both, never neither" {
    for (list) |c| {
        const earned = unlockedBy(c.id) != null;
        try std.testing.expect((c.price == 0) == earned);
    }
    for (ach.list) |a| {
        if (a.cosmetic) |c| try std.testing.expect(find(c) != null);
    }
}
