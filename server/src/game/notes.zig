//! Found notes (docs/LORE.md): which drop, from what, and what completing a set pays. Pure: the
//! caller passes the notes a player already holds as a bit set, and gets back at most one new one.
//! The text lives in notes_data.zig.

const std = @import("std");
const data = @import("data.zig");
const d = @import("notes_data.zig");
const Rng = @import("rng.zig").Rng;

pub const Note = d.Note;
pub const SetRow = d.SetRow;
pub const SetId = d.SetId;
pub const Form = d.Form;
pub const sets = d.sets;
pub const notes = d.notes;

/// A player's found notes: bit i is `notes[i]`.
pub const Found = std.bit_set.IntegerBitSet(128);

comptime {
    std.debug.assert(notes.len <= 128);
}

/// The note First Blood always leaves: Dale's last text, the hook into the whole story.
pub const first_blood_id = "starlite.04";

/// Where a drop came from; each has its own chance.
pub const Source = enum { cache, landmark, pve, elite, airdrop, raid };

pub fn dropChance(src: Source) f64 {
    return switch (src) {
        .cache => 0.12,
        .landmark => 0.25,
        .pve => 0.03,
        .elite => 0.10,
        .airdrop => 0.35,
        .raid => 1.0,
    };
}

/// Patient Zero notes drop only from these, and only late.
fn canDropZero(src: Source) bool {
    return switch (src) {
        .airdrop, .elite, .raid => true,
        else => false,
    };
}

/// Share of the other sets' notes a player must hold before Patient Zero pieces can drop.
pub const zero_gate = 0.5;

pub fn set(id: SetId) SetRow {
    return sets[@intFromEnum(id)];
}

pub fn indexOf(id: []const u8) ?u16 {
    for (notes, 0..) |n, i| {
        if (std.mem.eql(u8, n.id, id)) return @intCast(i);
    }
    return null;
}

pub fn setIndexOf(id: []const u8) ?SetId {
    for (sets) |s| {
        if (std.mem.eql(u8, @tagName(s.id), id)) return s.id;
    }
    return null;
}

pub fn setVisibleTo(id: SetId, f: data.Faction) bool {
    return switch (set(id).audience) {
        .both => true,
        .human => f == .human,
        .zombie => f == .zombie,
    };
}

pub fn visibleTo(n: Note, f: data.Faction) bool {
    return setVisibleTo(n.set, f);
}

/// Notes a faction can ever find.
pub fn visibleTotal(f: data.Faction) u32 {
    var n: u32 = 0;
    for (notes) |note| {
        if (visibleTo(note, f)) n += 1;
    }
    return n;
}

pub fn setTotal(id: SetId) u32 {
    var n: u32 = 0;
    for (notes) |note| {
        if (note.set == id) n += 1;
    }
    return n;
}

pub fn setFound(id: SetId, found: Found) u32 {
    var n: u32 = 0;
    for (notes, 0..) |note, i| {
        if (note.set == id and found.isSet(i)) n += 1;
    }
    return n;
}

pub fn setComplete(id: SetId, found: Found) bool {
    return setFound(id, found) == setTotal(id);
}

/// Salvage a note adds to its set's reward.
pub fn rarityValue(r: data.Rarity) u32 {
    return switch (r) {
        .common => 10,
        .uncommon => 20,
        .rare => 40,
        .legendary => 100,
    };
}

/// Salvage for completing a set: the sum of its notes' rarity values.
pub fn setReward(id: SetId) u32 {
    var s: u32 = 0;
    for (notes) |note| {
        if (note.set == id) s += rarityValue(note.rarity);
    }
    return s;
}

/// True once the player holds enough of everything except Patient Zero.
pub fn zeroUnlocked(f: data.Faction, found: Found) bool {
    var have: u32 = 0;
    var total: u32 = 0;
    for (notes, 0..) |note, i| {
        if (note.set == .zero or !visibleTo(note, f)) continue;
        total += 1;
        if (found.isSet(i)) have += 1;
    }
    return @as(f64, @floatFromInt(have)) >= zero_gate * @as(f64, @floatFromInt(total));
}

fn rarityWeight(r: data.Rarity) f64 {
    return switch (r) {
        .common => 10,
        .uncommon => 6,
        .rare => 3,
        .legendary => 1.5,
    };
}

/// How much a source or a place leans towards a set (1 = not at all).
fn setBias(id: SetId, src: Source, place: ?data.PlaceKind) f64 {
    var w: f64 = 1;
    if (src == .landmark) {
        if (place) |p| switch (p) {
            .pharmacy => if (id == .lantern or id == .road) {
                w *= 4;
            },
            .diner => if (id == .starlite) {
                w *= 5;
            },
            .police => if (id == .containment) {
                w *= 4;
            },
            .outfitter => if (id == .survey) {
                w *= 2;
            },
            .hardware, .fuel, .grocery => if (id == .ordinary) {
                w *= 2;
            },
        };
    }
    // Fights turn up what the other side wrote or left behind.
    if (src == .pve or src == .elite) {
        if (id == .survey or id == .hunger) w *= 2.5;
    }
    return w;
}

/// Roll for a note: the source's chance first, then a weighted pick among notes this faction can
/// see and has not found. Road notes need a landmark of their kind; Patient Zero needs an
/// airdrop, elite or raid and the gate. Null when nothing drops or nothing is left.
pub fn roll(rng: *Rng, f: data.Faction, found: Found, src: Source, place: ?data.PlaceKind) ?u16 {
    if (!rng.chance(dropChance(src))) return null;
    return pick(rng, f, found, src, place);
}

pub fn pick(rng: *Rng, f: data.Faction, found: Found, src: Source, place: ?data.PlaceKind) ?u16 {
    var w: [notes.len]f64 = undefined;
    const zero_ok = canDropZero(src) and zeroUnlocked(f, found);
    var any = false;
    for (notes, 0..) |n, i| {
        w[i] = 0;
        if (!visibleTo(n, f) or found.isSet(i)) continue;
        if (n.set == .zero and !zero_ok) continue;
        if (n.set == .road) {
            // Place notes: only at the kind of place they belong to.
            if (src != .landmark) continue;
            const np = n.place orelse continue;
            if (np != (place orelse continue)) continue;
            w[i] = rarityWeight(n.rarity) * 4;
        } else {
            w[i] = rarityWeight(n.rarity) * setBias(n.set, src, place);
        }
        any = true;
    }
    if (!any) return null;
    return @intCast(rng.weighted(&w));
}

// --- Tests -------------------------------------------------------------------------------------

const testing = std.testing;

fn words(s: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, " \n\t");
    while (it.next()) |_| n += 1;
    return n;
}

test "the table: unique ids, set sizes, word counts, rarities" {
    for (notes, 0..) |a, i| {
        for (notes[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a.id, b.id));
        const w = words(a.body);
        if (w < 40 or w > 220) std.debug.print("{s}: {d} words\n", .{ a.id, w });
        try testing.expect(w >= 40 and w <= 220);
        try testing.expect(a.title.len > 0 and a.author.len > 0 and a.date.len > 0);
        // Every id starts with its set's name.
        try testing.expect(std.mem.startsWith(u8, a.id, @tagName(a.set)));
        // Legendary notes are Patient Zero's, and only those.
        try testing.expectEqual(a.set == .zero, a.rarity == .legendary);
        try testing.expect((a.set == .road) == (a.place != null));
    }
    const want = [_]u32{ 8, 7, 12, 7, 8, 8, 5, 5 };
    for (sets, want) |s, n| try testing.expectEqual(n, setTotal(s.id));
    try testing.expectEqual(@as(usize, 60), notes.len);
    try testing.expectEqual(@as(u32, 52), visibleTotal(.human));
    try testing.expectEqual(@as(u32, 52), visibleTotal(.zombie));
    try testing.expect(indexOf(first_blood_id) != null);
}

test "drops never repeat and respect who may read them" {
    var rng = Rng.init(7);
    for ([_]data.Faction{ .human, .zombie }) |f| {
        var found = Found.initEmpty();
        var got: u32 = 0;
        // Landmarks anywhere and raids: between them every note is reachable.
        for (0..20_000) |_| {
            const src: Source = if (rng.chance(0.5)) .landmark else .raid;
            const place: ?data.PlaceKind = @enumFromInt(rng.below(7));
            const i = pick(&rng, f, found, src, place) orelse continue;
            try testing.expect(!found.isSet(i));
            try testing.expect(visibleTo(notes[i], f));
            found.set(i);
            got += 1;
        }
        try testing.expectEqual(visibleTotal(f), got);
    }
}

test "Patient Zero waits for half of everything else, and only some sources carry it" {
    var rng = Rng.init(99);
    var found = Found.initEmpty();
    // Fresh player: thousands of airdrops, raids and elites, never a Patient Zero piece.
    for (0..3000) |_| {
        const src: Source = switch (rng.below(3)) {
            0 => .airdrop,
            1 => .elite,
            else => .raid,
        };
        const i = pick(&rng, .human, found, src, null).?;
        try testing.expect(notes[i].set != .zero);
    }
    try testing.expect(!zeroUnlocked(.human, found));

    // Half of the rest held: the gate opens, and caches still never carry it.
    var held: u32 = 0;
    for (notes, 0..) |n, i| {
        if (n.set == .zero or !visibleTo(n, .human)) continue;
        if (held < 26) found.set(i);
        held += 1;
    }
    try testing.expect(zeroUnlocked(.human, found));
    var zero_seen = false;
    for (0..4000) |_| {
        const i = pick(&rng, .human, found, .airdrop, null).?;
        if (notes[i].set == .zero) zero_seen = true;
        const c = pick(&rng, .human, found, .cache, null).?;
        try testing.expect(notes[c].set != .zero);
    }
    try testing.expect(zero_seen);
}

test "landmark kinds lean towards their sets, and road notes keep to their place" {
    var rng = Rng.init(5);
    var starlite: u32 = 0;
    var lantern: u32 = 0;
    for (0..3000) |_| {
        const i = pick(&rng, .human, Found.initEmpty(), .landmark, .diner).?;
        if (notes[i].set == .starlite) starlite += 1;
        if (notes[i].set == .road) try testing.expectEqual(data.PlaceKind.diner, notes[i].place.?);
        const j = pick(&rng, .human, Found.initEmpty(), .landmark, .pharmacy).?;
        if (notes[j].set == .lantern) lantern += 1;
    }
    // Starlite is 7 of 52 notes, but a diner favours it well past that.
    try testing.expect(starlite > 3000 * 7 / 52 * 2);
    try testing.expect(lantern > 3000 * 8 / 52 * 2);
    // Road notes never come from a cache, and a diner has no road note.
    for (0..2000) |_| {
        const i = pick(&rng, .zombie, Found.initEmpty(), .cache, null).?;
        try testing.expect(notes[i].set != .road);
    }
    // Only the hardware store's own note.
    var found = Found.initEmpty();
    for (notes, 0..) |n, i| {
        if (n.set != .road) found.set(i);
    }
    const i = pick(&rng, .human, found, .landmark, .hardware).?;
    try testing.expectEqualStrings("road.03", notes[i].id);
    try testing.expect(pick(&rng, .human, found, .landmark, .diner) == null);
}

test "chances and rewards" {
    var rng = Rng.init(11);
    var hits: u32 = 0;
    for (0..50_000) |_| {
        if (roll(&rng, .human, Found.initEmpty(), .cache, null) != null) hits += 1;
    }
    try testing.expect(hits > 5400 and hits < 6600); // 12% of 50k
    for (0..200) |_| try testing.expect(roll(&rng, .human, Found.initEmpty(), .raid, null) != null);
    try testing.expectEqual(@as(u32, 500), setReward(.zero));
}
