//! CORE (B1, B2). The world, as columns.
//!
//! MODULE BOUNDARY: `world.zig` and `tick.zig` are ONE MODULE, split across two files for
//! readability. A module is a unit of hidden decision (D1), not a file.
//!
//! This is stated explicitly because A5 is a [MUST] and the alternative reading fails it. A
//! `Run` is a pair of raw indexes into these columns, and `tick.zig` uses them -- an index is
//! meaningless without its array, so if these were two modules that would be a bare index
//! crossing a boundary, which A5 forbids outright.
//!
//! They are not two modules. The world's layout and the transform over that layout are the
//! same decision: change the columns and the tick changes with them. Splitting them would be
//! change amplification, not encapsulation.
//!
//! What DOES cross a real boundary is the combat module, and it receives SLICES OF PLAIN
//! VALUES -- never a Run, never an index (B5). And nothing outside this module mutates these
//! columns; `relocate` exists so callers say who is where and the world does the writing (C4).
//!
//! There is no Player. There is a column of cell ids, a column of hit points, a column
//! of factions, and free functions that walk them (A1, A3). No record here has a method,
//! an identity, or an invariant enforced by code attached to it.
//!
//! Every function that allocates takes an allocator (C1). Nothing here allocates behind
//! your back (C2).

const std = @import("std");
const spatial = @import("spatial.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const CellId = spatial.CellId;

/// An opaque, stable, server-issued id (A8).
///
/// Opaque so that it cannot be derived from anything a user controls, cannot be done
/// arithmetic on, and reveals no creation order that would leak the size of the
/// population. It is never reused after deletion.
pub const PlayerId = enum(u32) { _ };

/// Chosen once, at registration, permanently.
///
/// Faction is not a team you coordinate with -- you do not know who the other Humans
/// are either. It is a secret allegiance carried through a city full of people who might
/// share it.
pub const Faction = enum(u8) { human, zombie };

/// A player is in a cell, with a faction and hit points. That is the entire record.
///
/// No position. No bearing. No heading. No coordinate has ever been anywhere near this
/// struct, and the type system has no way to put one here (B6).
pub const Presence = struct {
    cell: CellId, // u64
    player: PlayerId, // u32
    hp: u16,
    faction: Faction, // u8
    _pad: u8 = 0,

    comptime {
        // THE SIZE GUARD (A7). The hottest struct in the system: one per player per
        // tick. 8 + 4 + 2 + 1 + 1 = 16 bytes packed, and the exact check catches both
        // unexpected growth and silent padding.
        //
        // Raising this number requires a recorded justification (A7.1). Bumping it to
        // make the build pass is a violation equal to deleting the guard.
        assert(@sizeOf(Presence) == 16);
    }
};

/// The world state.
///
/// A7.2: cold struct, size guard waived -- there is one of these per server and it never
/// sits in a hot loop. The columns it holds are the hot thing, and they are guarded.
pub const World = struct {
    presences: std.MultiArrayList(Presence),

    /// When the current engagement in each cell began (0.5).
    ///
    /// A fight is an EVENT, not a climate. A cell that goes live with hostiles starts an
    /// engagement, it runs for a bounded number of ticks, it resolves, and then the room is
    /// spent for a while. This table is the only thing the world remembers between ticks
    /// besides the people themselves.
    ///
    /// Keyed by cell, never by player: it is the ROOM that is spent, which is what stops a
    /// crowded office from being an eight-hour war and, incidentally, from being the best
    /// XP strategy in the game.
    ///
    /// I7: this holds a CellId and a tick index. It holds no coordinate, because there is no
    /// coordinate. Entries are dropped the moment they expire.
    engagements: std.AutoHashMapUnmanaged(CellId, Engagement),

    pub const empty: World = .{ .presences = .empty, .engagements = .empty };
};

/// One fight, in one room.
///
/// The head counts are sampled ONCE, when the engagement begins, and never updated. That is
/// what makes the crowd band a horizon rather than a scalpel: a player cannot watch the
/// number move, because it does not move (I5). See `combat.Crowd`.
///
/// These are the true counts, held in the core, where they are safe. What leaves the core is
/// a band.
pub const Engagement = struct {
    started: u64,
    humans: u16,
    zombies: u16,

    comptime {
        // THE SIZE GUARD (A7). One per room currently fighting.
        // 8 + 2 + 2 = 12 packed, padded to 16 by the u64's alignment.
        assert(@sizeOf(Engagement) == 16);
    }
};

/// CORE. Deterministic cleanup at the point of acquisition (C5).
pub fn deinit(world: *World, gpa: Allocator) void {
    world.presences.deinit(gpa);
    world.engagements.deinit(gpa);
    world.* = .empty;
}

/// CORE. Add a presence. Allocates, and says so (C1, C2).
pub fn add(world: *World, gpa: Allocator, presence: Presence) Allocator.Error!void {
    return world.presences.append(gpa, presence);
}

/// CORE. Reserve room for `n` presences up front.
///
/// The tick knows how many presences it has before it starts, so the realistic path is
/// one reservation and no reallocation. Design for the many, never the one (A2).
pub fn ensureCapacity(world: *World, gpa: Allocator, n: usize) Allocator.Error!void {
    return world.presences.ensureTotalCapacity(gpa, n);
}

/// CORE. Read-only views of the columns. THE ONLY WAY TO SEE THEM.
///
/// Arrays of plain values may cross a module boundary (B5). The MultiArrayList that holds them
/// may not: it is this module's layout decision, and a caller that reaches into
/// `world.presences.items(...)` has taken a dependency on how the world is stored (D3) and can
/// write to memory it does not own (C4). Three modules did exactly that before the audit.
///
/// The guard now fails the build if `presences` appears outside this module. These accessors
/// are what callers use instead, and they hand back `const` slices -- readable, not writable.
pub fn cellsOf(world: *const World) []const CellId {
    return world.presences.items(.cell);
}

pub fn playerIds(world: *const World) []const PlayerId {
    return world.presences.items(.player);
}

pub fn factions(world: *const World) []const Faction {
    return world.presences.items(.faction);
}

pub fn hitPoints(world: *const World) []const u16 {
    return world.presences.items(.hp);
}

pub fn population(world: *const World) usize {
    return world.presences.len;
}

/// How many presences the world has room for without reallocating. For tests that assert the
/// tick does not allocate per tick.
pub fn capacityOf(world: *const World) usize {
    return world.presences.capacity;
}

/// CORE. Move people. THE ONLY WAY TO MOVE THEM.
///
/// The caller supplies a function from (player, where they are now) to (where they are now).
/// The world walks its own columns and applies it.
///
/// C4: ONE SUBSYSTEM NEVER MUTATES MEMORY OWNED BY ANOTHER. Before the ruleset audit, three
/// separate modules -- the synthetic city, the session layer, and replay -- each reached into
/// `world.presences.items(.cell)` and wrote to it directly. Each one worked. Each one was a
/// module writing into another module's arrays, which is the exact coupling C4 forbids and the
/// exact way a struct-of-arrays layout leaks out of the module that owns it (D3).
///
/// Now the layout stays here, and the callers say WHAT they want, not HOW it is stored.
/// Allocates nothing.
pub fn relocate(
    world: *World,
    context: anytype,
    comptime cellFor: fn (@TypeOf(context), PlayerId, CellId) CellId,
) void {
    const players = world.presences.items(.player);
    const cells = world.presences.items(.cell);

    for (players, cells) |player, *cell| {
        cell.* = cellFor(context, player, cell.*);
    }
}

/// CORE. The engagement table, flattened and sorted by cell, for writing down.
///
/// Sorted because a hash map's iteration order is not something we will ever rely on (B8).
/// The caller owns the returned slices and frees both with the same allocator (C1, C5).
pub fn engagementsSorted(world: *const World, gpa: Allocator) Allocator.Error!struct {
    cells: []CellId,
    engagements: []Engagement,
} {
    const n = world.engagements.count();

    const cells = try gpa.alloc(CellId, n);
    errdefer gpa.free(cells);
    const values = try gpa.alloc(Engagement, n);
    errdefer gpa.free(values);

    var pairs: std.ArrayList(struct { cell: CellId, engagement: Engagement }) = .empty;
    defer pairs.deinit(gpa);
    try pairs.ensureTotalCapacity(gpa, n);

    var it = world.engagements.iterator();
    while (it.next()) |entry| {
        pairs.appendAssumeCapacity(.{ .cell = entry.key_ptr.*, .engagement = entry.value_ptr.* });
    }

    const Sort = struct {
        fn lessThan(_: void, a: @TypeOf(pairs.items[0]), b: @TypeOf(pairs.items[0])) bool {
            return spatial.lessThan(a.cell, b.cell);
        }
    };
    std.mem.sort(@TypeOf(pairs.items[0]), pairs.items, {}, Sort.lessThan);

    for (pairs.items, cells, values) |pair, *cell, *value| {
        cell.* = pair.cell;
        value.* = pair.engagement;
    }

    return .{ .cells = cells, .engagements = values };
}

/// CORE. Sort presences by cell, then by player.
///
/// This is the entire spatial algorithm, and it is a sort (0.3). Not an index, not a
/// tree, not a grid. The ordering is a group-by key and nothing more: two cells adjacent
/// in this order are not adjacent in the world, and no code may assume otherwise (A9).
///
/// The tie-break on player is what makes it a TOTAL order, and it is load-bearing for
/// determinism (B8). The sort is unstable, so presences sharing a cell would otherwise
/// have no defined order among themselves -- and the order in which the tick emits events
/// would then depend on the order presences happened to arrive in. Replay would still pass
/// (same input, same output), while two servers fed the same facts in a different sequence
/// would disagree. A total order costs one comparison and removes the question.
pub fn sortByCell(world: *World) void {
    const Order = struct {
        cells: []const CellId,
        players: []const PlayerId,

        pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            if (ctx.cells[a] != ctx.cells[b]) return spatial.lessThan(ctx.cells[a], ctx.cells[b]);
            return @intFromEnum(ctx.players[a]) < @intFromEnum(ctx.players[b]);
        }
    };

    world.presences.sortUnstable(Order{
        .cells = world.presences.items(.cell),
        .players = world.presences.items(.player),
    });
}

/// A run of presences that share a cell, as a half-open range into the columns.
///
/// A Run only ever names presences that are already contiguous, which is why the group-by
/// is a sort and a scan and not an index (0.3). These indexes are meaningless without the
/// columns they index, so they do not leave this module (A5).
pub const Run = struct {
    start: u32,
    len: u32,

    comptime {
        // THE SIZE GUARD (A7). One per live cell per tick.
        assert(@sizeOf(Run) == 8);
    }
};

/// CORE. The live cells: group presences by cell, and discard every run below quorum.
///
/// QUORUM SILENCE IS ABSOLUTE (I3). A run shorter than k is not marked, not counted, not
/// returned with a flag, and not reported as quiet. It is DISCARDED here, at the only
/// place that could ever have known about it, so that no downstream code is even capable
/// of emitting a sub-quorum signal. There is no code path from a run of two to anything a
/// player can observe -- not a count, not a hint, not a timing difference. A cell below
/// quorum is indistinguishable from an empty field because, past this function, it does
/// not exist.
///
/// A cell below quorum is not an error and is not an absence of data. It is simply not a
/// result (E4).
///
/// The caller owns the returned slice and frees it with the same allocator (C1, C5).
pub fn liveRuns(world: *World, gpa: Allocator, k: u32) Allocator.Error![]Run {
    sortByCell(world);

    const cells = world.presences.items(.cell);

    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);

    var start: usize = 0;
    while (start < cells.len) {
        var end = start + 1;
        while (end < cells.len and cells[end] == cells[start]) : (end += 1) {}

        const len = end - start;

        // NOWHERE IS NOT SOMEWHERE. Players with no GPS fix share the value zero, but they do
        // not share a room -- they are not in one. Without this, everybody whose phone had not
        // reported would be co-located with everybody else whose phone had not reported, would
        // reach quorum, and would fight. An invisible war in an imaginary room.
        //
        // Zero sorts first, so this is one run at the front, skipped once.
        if (cells[start] == spatial.nowhere) {
            start = end;
            continue;
        }

        if (len >= k) {
            try runs.append(gpa, .{
                .start = @intCast(start),
                .len = @intCast(len),
            });
        }
        // else: discarded. Not counted, not remembered, not emitted (I3).

        start = end;
    }

    return runs.toOwnedSlice(gpa);
}

test "Presence is exactly 16 bytes" {
    // The guard above already fails the build if this regresses. This test exists so the
    // number is also asserted somewhere a human reads.
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Presence));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Presence));
}

test "the world is columns, not records" {
    const gpa = std.testing.allocator;

    var world: World = .empty;
    defer deinit(&world, gpa);

    const cell = spatial.cellFromKey(0xABCD, spatial.default_precision);
    try add(&world, gpa, .{
        .cell = cell,
        .player = @enumFromInt(1),
        .hp = 100,
        .faction = .human,
    });
    try add(&world, gpa, .{
        .cell = cell,
        .player = @enumFromInt(2),
        .hp = 80,
        .faction = .zombie,
    });

    // Each field is its own run. This is what the tick walks.
    const hp = world.presences.items(.hp);
    try std.testing.expectEqualSlices(u16, &.{ 100, 80 }, hp);
    try std.testing.expectEqual(@as(usize, 2), world.presences.len);
}

test "sorting by cell groups co-located presences into runs" {
    const gpa = std.testing.allocator;

    var world: World = .empty;
    defer deinit(&world, gpa);

    const p = spatial.default_precision;
    const a = spatial.cellFromKey(0xAAAA, p);
    const b = spatial.cellFromKey(0xBBBB, p);
    try std.testing.expect(a != b);

    // Interleaved on the way in, as they would arrive from ten thousand phones.
    try add(&world, gpa, .{ .cell = a, .player = @enumFromInt(1), .hp = 100, .faction = .human });
    try add(&world, gpa, .{ .cell = b, .player = @enumFromInt(2), .hp = 100, .faction = .zombie });
    try add(&world, gpa, .{ .cell = a, .player = @enumFromInt(3), .hp = 100, .faction = .zombie });
    try add(&world, gpa, .{ .cell = b, .player = @enumFromInt(4), .hp = 100, .faction = .human });

    sortByCell(&world);

    // Equal cells are now contiguous: the runs the tick will scan.
    const cells = world.presences.items(.cell);
    try std.testing.expectEqual(cells[0], cells[1]);
    try std.testing.expectEqual(cells[2], cells[3]);
    try std.testing.expect(cells[0] != cells[2]);
}

fn addN(world: *World, gpa: Allocator, cell: CellId, n: u32, first_id: u32) !void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        try add(world, gpa, .{
            .cell = cell,
            .player = @enumFromInt(first_id + i),
            .hp = 100,
            .faction = if (i % 2 == 0) .human else .zombie,
        });
    }
}

test "a run below quorum is discarded, not reported" {
    const gpa = std.testing.allocator;
    const k = spatial.quorum; // 3

    var world: World = .empty;
    defer deinit(&world, gpa);

    const p = spatial.default_precision;
    const quiet = spatial.cellFromKey(0x1111, p); // 2 occupants: below quorum
    const live = spatial.cellFromKey(0x2222, p); // 3 occupants: at quorum

    try addN(&world, gpa, quiet, 2, 100);
    try addN(&world, gpa, live, 3, 200);

    const runs = try liveRuns(&world, gpa, k);
    defer gpa.free(runs);

    // The sub-quorum cell is not present in the output in any form. There is no entry
    // for it, no count, no marker. It is indistinguishable from the empty field (I3).
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try std.testing.expectEqual(@as(u32, 3), runs[0].len);

    const cells = world.presences.items(.cell);
    try std.testing.expectEqual(live, cells[runs[0].start]);
}

test "an empty field and a field below quorum are the same result" {
    const gpa = std.testing.allocator;
    const k = spatial.quorum;
    const p = spatial.default_precision;

    // A world with k-1 people standing together.
    var populated: World = .empty;
    defer deinit(&populated, gpa);
    try addN(&populated, gpa, spatial.cellFromKey(0x3333, p), k - 1, 300);

    const from_populated = try liveRuns(&populated, gpa, k);
    defer gpa.free(from_populated);

    // A world with nobody in it at all.
    var empty_world: World = .empty;
    defer deinit(&empty_world, gpa);

    const from_empty = try liveRuns(&empty_world, gpa, k);
    defer gpa.free(from_empty);

    // The two are byte-identical results. This is the whole of I3: below quorum, the
    // system does not say "quiet" -- it says nothing, and it says exactly what an empty
    // field says.
    try std.testing.expectEqualSlices(Run, from_empty, from_populated);
    try std.testing.expectEqual(@as(usize, 0), from_populated.len);
}

test "quorum is a floor, and coarsening is what reaches it" {
    const gpa = std.testing.allocator;
    const k = spatial.quorum;
    const p = spatial.default_precision;

    // Three people in a sparse region: one per fine cell, all sharing a coarse parent.
    // Nobody reaches quorum, so the world is silent.
    const a = spatial.cellFromKey(0b110100, p);
    const b = spatial.cellFromKey(0b110101, p);
    const c = spatial.cellFromKey(0b110110, p);

    var world: World = .empty;
    defer deinit(&world, gpa);
    try addN(&world, gpa, a, 1, 400);
    try addN(&world, gpa, b, 1, 401);
    try addN(&world, gpa, c, 1, 402);

    const silent = try liveRuns(&world, gpa, k);
    defer gpa.free(silent);
    try std.testing.expectEqual(@as(usize, 0), silent.len);

    // Grow the room (I8). k does not move; the cell does.
    const cells = world.presences.items(.cell);
    for (cells) |*cell| cell.* = spatial.coarsen(cell.*, 2);

    const reached = try liveRuns(&world, gpa, k);
    defer gpa.free(reached);
    try std.testing.expectEqual(@as(usize, 1), reached.len);
    try std.testing.expectEqual(@as(u32, 3), reached[0].len);
}

test "many cells, only the live ones survive" {
    const gpa = std.testing.allocator;
    const k = spatial.quorum;
    const p = spatial.default_precision;

    var world: World = .empty;
    defer deinit(&world, gpa);

    // A thousand rooms. Every third is a live one; the rest hold a single person.
    var id: u32 = 0;
    var cell_key: u64 = 0;
    var expected_live: usize = 0;
    while (cell_key < 1000) : (cell_key += 1) {
        const cell = spatial.cellFromKey(cell_key, p);
        const occupants: u32 = if (cell_key % 3 == 0) 4 else 1;
        if (occupants >= k) expected_live += 1;
        try addN(&world, gpa, cell, occupants, id);
        id += occupants;
    }

    const runs = try liveRuns(&world, gpa, k);
    defer gpa.free(runs);

    try std.testing.expectEqual(expected_live, runs.len);
    for (runs) |run| try std.testing.expect(run.len >= k);
}

test "ensureCapacity does not allocate again" {
    const gpa = std.testing.allocator;

    var world: World = .empty;
    defer deinit(&world, gpa);

    try ensureCapacity(&world, gpa, 1000);
    const capacity = world.presences.capacity;

    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        try add(&world, gpa, .{
            .cell = spatial.cellFromKey(0xABCD, spatial.default_precision),
            .player = @enumFromInt(i),
            .hp = 100,
            .faction = .human,
        });
    }

    try std.testing.expectEqual(capacity, world.presences.capacity);
}

test "nowhere is not somewhere" {
    // THE INVISIBLE WAR.
    //
    // Every player who has not reported a cell -- no GPS fix, phone asleep, session just
    // opened, in a tunnel -- has to be SOMEWHERE in the columns, because the world is a
    // rectangle. The obvious thing is to park them all in a placeholder cell.
    //
    // The obvious thing is a catastrophe. A placeholder cell is a real cell, so every player
    // whose phone had not reported would be standing in the same room as every other, they
    // would reach quorum, and they would fight. Everyone with GPS switched off would be at war
    // with each other, in one enormous invisible room, forever.
    //
    // Zero is not a place: every real cell has its sentinel bit set, so no real cell is zero.
    // The tick skips it.
    const gpa = std.testing.allocator;

    var world: World = .empty;
    defer deinit(&world, gpa);

    // Twenty players, none of whom have reported.
    var id: u32 = 1;
    while (id <= 20) : (id += 1) {
        try add(&world, gpa, .{
            .cell = spatial.nowhere,
            .player = @enumFromInt(id),
            .hp = 100,
            .faction = if (id % 2 == 0) .human else .zombie,
        });
    }

    const runs = try liveRuns(&world, gpa, spatial.quorum);
    defer gpa.free(runs);

    // Twenty people, well past quorum, all sharing a value -- and not one live cell. They are
    // not in a room. They are nowhere.
    try std.testing.expectEqual(@as(usize, 0), runs.len);
}

test "nowhere does not stop the rest of the world" {
    const gpa = std.testing.allocator;
    const p = spatial.default_precision;
    const cafe = spatial.cellFromKey(0xCAFE, p);

    var world: World = .empty;
    defer deinit(&world, gpa);

    // Three people in a café, and five with their phones off.
    var id: u32 = 1;
    while (id <= 3) : (id += 1) {
        try add(&world, gpa, .{ .cell = cafe, .player = @enumFromInt(id), .hp = 100, .faction = .human });
    }
    while (id <= 8) : (id += 1) {
        try add(&world, gpa, .{ .cell = spatial.nowhere, .player = @enumFromInt(id), .hp = 100, .faction = .zombie });
    }

    const runs = try liveRuns(&world, gpa, spatial.quorum);
    defer gpa.free(runs);

    // The café is live. Nowhere is not.
    try std.testing.expectEqual(@as(usize, 1), runs.len);
    try std.testing.expectEqual(@as(u32, 3), runs[0].len);
}
