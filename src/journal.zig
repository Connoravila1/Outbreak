//! CORE (B1, B2). The journal: what the world writes down, and what it refuses to (1.2).
//!
//! A sealed module (D1). Persistence strategy is a decision that will change; the on-disk
//! layout appears in no other module's signatures (D3).
//!
//! This file is PURE. It turns records into bytes and bytes back into records. It does not
//! open a file, and it does not know what a file is -- that is `store.zig`, which is four
//! functions long. The split is not ceremony: it means the entire persistence format is
//! testable without a disk, and it means the thing that decides WHAT IS WRITTEN DOWN can be
//! held to the same standard as the rest of the core.
//!
//! WHAT IS WRITTEN DOWN, AND WHAT IS NOT (I7, B6)
//!
//! A `CellId` and a tick index. That is all. There is no coordinate in this file, no float
//! in this file, and no way to put one here -- the build guard fails on a float in this
//! file exactly as it does in the core, because a persisted coordinate is the one mistake
//! that cannot be walked back. There is no coordinate database to breach, to subpoena, or
//! to leak, because there is no coordinate.
//!
//! RETENTION IS DESIGNED IN, NOT BOLTED ON (I7)
//!
//! `prune` exists in the first version of this file, before a single byte has ever been
//! written, because retrofitting deletion into a schema is misery and because a retention
//! policy that is not code is not a policy. The plausibility and farm-detection windows are
//! the only reason to keep a cell history at all; past those windows it is deleted.

const std = @import("std");
const spatial = @import("spatial.zig");
const world_mod = @import("world.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const CellId = spatial.CellId;
const Faction = world_mod.Faction;
const PlayerId = world_mod.PlayerId;

/// "OBRK", little-endian.
pub const magic: u32 = 0x4B52_424F;
pub const version: u32 = 1;

pub const Error = error{
    BadMagic,
    BadVersion,
    Truncated,
    UnknownRecord,
    /// A field whose value is not one this program recognises -- a faction byte of 7, say.
    ///
    /// FOUND BY THE FUZZER, ON ITS FIRST RUN. `Faction` is an exhaustive enum(u8), so
    /// `@enumFromInt(7)` is ILLEGAL BEHAVIOUR: a panic, from data alone. A corrupted journal --
    /// a tampered file, a power cut mid-write, a bad disk -- crashed the server that read it.
    ///
    /// Network- and disk-derived integers are never turned into an enum without a check. The
    /// value is now validated and an unrecognised one is a clean rejection (E3).
    BadValue,
};

/// What the shell needs to know before it can replay anything.
///
/// A7.2: cold struct, size guard waived -- one per log.
pub const Header = struct {
    seed: u64,
    /// The cell precision the world was quantized at. Written down because a cell means
    /// nothing without it, and because it will change (see GAME_RULES O6).
    precision: u6,
};

const Kind = enum(u8) {
    roster = 1,
    tick = 2,
    /// What every player has earned.
    ///
    /// A snapshot without it loses everyone's XP and level on restart -- the world comes back
    /// looking correct, with every player silently returned to level one. Retention deletes the
    /// ROOMS people were in (I7); it must never delete what they earned by being there.
    progress = 4,
    /// The fights that were in progress when the snapshot was taken.
    ///
    /// A snapshot that records where everyone is and how hurt they are, but NOT the fights
    /// they are in the middle of, is not a snapshot of the world -- it is a snapshot of most
    /// of it. Replaying from it would restart every fight that was running, resolve them
    /// differently, and produce a world that is plausible and wrong.
    engagements = 3,
};

/// One player's report: they were in this room on this tick.
///
/// THE ONLY LOCATION DATA THE SYSTEM PERSISTS. A room and a name for a person. No
/// coordinate, no bearing, no path -- and the room is deleted once the integrity windows no
/// longer need it (I7).
pub const Report = struct {
    cell: CellId, // u64
    player: PlayerId, // u32
    _pad: u32 = 0,

    comptime {
        // THE SIZE GUARD (A7). One per player per tick, for the length of the retention
        // window: the largest thing this system ever holds.
        assert(@sizeOf(Report) == 16);
    }
};

pub const Record = union(enum) {
    /// A snapshot of the world at the start of tick `index`: who is playing, what they are,
    /// and how they are doing. Replay begins at one of these.
    roster: struct { index: u64, count: u32, payload: []const u8 },
    /// Where everyone was, on one tick.
    tick: struct { index: u64, count: u32, payload: []const u8 },
    /// The fights in progress at a snapshot.
    engagements: struct { index: u64, count: u32, payload: []const u8 },
    /// What everyone has earned, at a snapshot.
    progress: struct { index: u64, count: u32, payload: []const u8 },
};

// ---------------------------------------------------------------------------- writing

/// CORE. Begin a journal.
pub fn writeHeader(out: *std.ArrayList(u8), gpa: Allocator, header: Header) Allocator.Error!void {
    try appendInt(out, gpa, u32, magic);
    try appendInt(out, gpa, u32, version);
    try appendInt(out, gpa, u64, header.seed);
    try appendInt(out, gpa, u8, header.precision);
}

/// CORE. Write a SNAPSHOT: who exists, which side they are on, and how they are doing, as of
/// the start of tick `index`.
///
/// SNAPSHOTS ARE WHAT MAKE RETENTION AND REPLAY COEXIST, and that is not obvious until you
/// try to have both. Retention (I7) deletes the old ticks -- so a log that has been pruned
/// CANNOT be replayed from the beginning, because the beginning has been deleted, which is
/// the entire point of deleting it.
///
/// So the journal writes the world down periodically. `prune` keeps the most recent snapshot
/// and every tick after it, and replay starts there. The deleted past stays deleted, the
/// retained window still replays exactly, and the log stays a fixed size forever instead of
/// growing without bound. (Ten thousand players for seven days is 2.4 GB of reports. This is
/// not a theoretical concern.)
pub fn writeRoster(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    index: u64,
    players: []const PlayerId,
    factions: []const Faction,
    hps: []const u16,
) Allocator.Error!void {
    assert(players.len == factions.len);
    assert(players.len == hps.len);

    const count: u32 = @intCast(players.len);
    try appendInt(out, gpa, u8, @intFromEnum(Kind.roster));
    try appendInt(out, gpa, u64, index);
    try appendInt(out, gpa, u32, count);

    for (players, factions, hps) |player, faction, hp| {
        try appendInt(out, gpa, u32, @intFromEnum(player));
        try appendInt(out, gpa, u8, @intFromEnum(faction));
        try appendInt(out, gpa, u16, hp);
    }
}

/// CORE. Write the fights in progress, as of the start of tick `index`.
///
/// Written next to the snapshot it belongs to, and sorted by cell -- the engagement table is
/// a hash map, and hash map iteration order is not a thing we will ever rely on (B8).
pub fn writeEngagements(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    index: u64,
    cells: []const CellId,
    engagements: []const world_mod.Engagement,
) Allocator.Error!void {
    assert(cells.len == engagements.len);

    const count: u32 = @intCast(cells.len);
    try appendInt(out, gpa, u8, @intFromEnum(Kind.engagements));
    try appendInt(out, gpa, u64, index);
    try appendInt(out, gpa, u32, count);

    for (cells, engagements) |cell, e| {
        try appendInt(out, gpa, u64, @intFromEnum(cell));
        try appendInt(out, gpa, u64, e.started);
        try appendInt(out, gpa, u16, e.humans);
        try appendInt(out, gpa, u16, e.zombies);
    }
}

/// CORE. Write what everyone has earned, as of the start of tick `index`.
///
/// Sorted by player, because a hash map's iteration order is not something we rely on (B8).
pub fn writeProgress(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    index: u64,
    players: []const PlayerId,
    progress: []const world_mod.Progress,
) Allocator.Error!void {
    assert(players.len == progress.len);

    const count: u32 = @intCast(players.len);
    try appendInt(out, gpa, u8, @intFromEnum(Kind.progress));
    try appendInt(out, gpa, u64, index);
    try appendInt(out, gpa, u32, count);

    for (players, progress) |player, p| {
        try appendInt(out, gpa, u32, @intFromEnum(player));
        try appendInt(out, gpa, u32, p.xp);
        try appendInt(out, gpa, u16, p.level);
    }
}

/// CORE. Write one tick's reports: who was in which room.
///
/// This is the entire input to the tick. Given the roster, the seed, and these, the world
/// replays byte-identically (B8) -- which is what makes a log a thing you can trust rather
/// than a thing you hope about.
pub fn writeTick(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    index: u64,
    players: []const PlayerId,
    cells: []const CellId,
) Allocator.Error!void {
    assert(players.len == cells.len);

    const count: u32 = @intCast(players.len);
    try appendInt(out, gpa, u8, @intFromEnum(Kind.tick));
    try appendInt(out, gpa, u64, index);
    try appendInt(out, gpa, u32, count);

    for (players, cells) |player, cell| {
        try appendInt(out, gpa, u32, @intFromEnum(player));
        try appendInt(out, gpa, u64, @intFromEnum(cell));
    }
}

/// CORE. Write a complete snapshot of the world: the roster AND the fights in progress.
///
/// One function, so that a half-snapshot cannot be written by accident. The first version of
/// this wrote the roster alone -- and a snapshot that records everyone's hit points but not
/// the fight they are standing in the middle of is not a snapshot of the world. Replaying
/// from it would restart every running fight and produce a world that is plausible and wrong.
///
/// The caller supplies the engagements sorted by cell, so the bytes are the same on every
/// machine (B8).
pub fn writeSnapshot(
    out: *std.ArrayList(u8),
    gpa: Allocator,
    index: u64,
    players: []const PlayerId,
    factions: []const Faction,
    hps: []const u16,
    cells: []const CellId,
    engagements: []const world_mod.Engagement,
    earners: []const PlayerId,
    progress: []const world_mod.Progress,
) Allocator.Error!void {
    try writeRoster(out, gpa, index, players, factions, hps);
    try writeEngagements(out, gpa, index, cells, engagements);
    try writeProgress(out, gpa, index, earners, progress);
}

// ---------------------------------------------------------------------------- reading

pub const Cursor = struct {
    bytes: []const u8,
    pos: usize,
};

/// CORE. Read the header and position a cursor at the first record.
pub fn open(bytes: []const u8) (Error)!struct { header: Header, cursor: Cursor } {
    if (bytes.len < 17) return Error.Truncated;

    if (readInt(bytes, 0, u32) != magic) return Error.BadMagic;
    if (readInt(bytes, 4, u32) != version) return Error.BadVersion;

    const seed = readInt(bytes, 8, u64);
    const precision: u6 = @intCast(readInt(bytes, 16, u8) & 0x3f);

    return .{
        .header = .{ .seed = seed, .precision = precision },
        .cursor = .{ .bytes = bytes, .pos = 17 },
    };
}

/// CORE. The next record, or null at the end.
///
/// A truncated log is an ERROR, not a silent stop (E3). A log that was cut off mid-write is
/// exactly the situation in which quietly pretending it ended cleanly does the most damage.
pub fn next(cursor: *Cursor) Error!?Record {
    if (cursor.pos >= cursor.bytes.len) return null;

    const kind: Kind = switch (cursor.bytes[cursor.pos]) {
        1 => .roster,
        2 => .tick,
        3 => .engagements,
        4 => .progress,
        else => return Error.UnknownRecord, // a record we do not understand is not a record
    };
    cursor.pos += 1;

    switch (kind) {
        .roster => {
            const index = try take(cursor, u64);
            const count = try take(cursor, u32);
            const bytes_needed = @as(usize, count) * roster_entry_size;
            const payload = try takeSlice(cursor, bytes_needed);
            return .{ .roster = .{ .index = index, .count = count, .payload = payload } };
        },
        .tick => {
            const index = try take(cursor, u64);
            const count = try take(cursor, u32);
            const bytes_needed = @as(usize, count) * report_size;
            const payload = try takeSlice(cursor, bytes_needed);
            return .{ .tick = .{ .index = index, .count = count, .payload = payload } };
        },
        .engagements => {
            const index = try take(cursor, u64);
            const count = try take(cursor, u32);
            const bytes_needed = @as(usize, count) * engagement_size;
            const payload = try takeSlice(cursor, bytes_needed);
            return .{ .engagements = .{ .index = index, .count = count, .payload = payload } };
        },
        .progress => {
            const index = try take(cursor, u64);
            const count = try take(cursor, u32);
            const bytes_needed = @as(usize, count) * progress_size;
            const payload = try takeSlice(cursor, bytes_needed);
            return .{ .progress = .{ .index = index, .count = count, .payload = payload } };
        },
    }
}

const roster_entry_size = 4 + 1 + 2;
const report_size = 4 + 8;
const engagement_size = 8 + 8 + 2 + 2;
const progress_size = 4 + 4 + 2;

/// CORE. The i-th entry of a roster payload.
///
/// The faction byte is VALIDATED, not cast. See `Error.BadValue`.
pub fn rosterEntry(payload: []const u8, i: usize) Error!struct { player: PlayerId, faction: Faction, hp: u16 } {
    const at = i * roster_entry_size;

    const faction: Faction = switch (readInt(payload, at + 4, u8)) {
        0 => .human,
        1 => .zombie,
        else => return Error.BadValue, // a faction we do not have is not a faction
    };

    return .{
        .player = @enumFromInt(readInt(payload, at, u32)),
        .faction = faction,
        .hp = readInt(payload, at + 5, u16),
    };
}

/// CORE. The i-th fight of an engagements payload.
pub fn engagementEntry(payload: []const u8, i: usize) struct { cell: CellId, engagement: world_mod.Engagement } {
    const at = i * engagement_size;
    return .{
        .cell = @enumFromInt(readInt(payload, at, u64)),
        .engagement = .{
            .started = readInt(payload, at + 8, u64),
            .humans = readInt(payload, at + 16, u16),
            .zombies = readInt(payload, at + 18, u16),
        },
    };
}

/// CORE. The i-th player's earnings.
pub fn progressEntry(payload: []const u8, i: usize) struct { player: PlayerId, progress: world_mod.Progress } {
    const at = i * progress_size;
    return .{
        .player = @enumFromInt(readInt(payload, at, u32)),
        .progress = .{
            .xp = readInt(payload, at + 4, u32),
            .level = readInt(payload, at + 8, u16),
        },
    };
}

/// CORE. The i-th report of a tick payload.
pub fn report(payload: []const u8, i: usize) Report {
    const at = i * report_size;
    return .{
        .player = @enumFromInt(readInt(payload, at, u32)),
        .cell = @enumFromInt(readInt(payload, at + 4, u64)),
    };
}

// ---------------------------------------------------------------------------- retention

/// CORE. RETENTION DELETION (I7). Keep the most recent snapshot at or before `keep_from`,
/// and every tick from that snapshot onward. Delete everything else.
///
/// This exists in the first version of this file, before a byte has ever been written to a
/// real disk, because retrofitting deletion into a schema is misery and because a retention
/// policy that is not code is not a policy -- it is a paragraph.
///
/// What survives: one snapshot (who exists, and their hit points -- no location at all), and
/// the recent cell history that the plausibility and farm-detection windows actually need.
/// What does not: every room anyone was in before that. There is nothing else in this log
/// that anyone could ever want, because there is nothing else in it.
///
/// Returns a fresh journal. The caller owns it (C1, C5).
pub fn prune(gpa: Allocator, bytes: []const u8, keep_from: u64) !std.ArrayList(u8) {
    const opened = try open(bytes);

    // First pass: find the snapshot we will replay from -- the most recent one at or before
    // the retention boundary. Anything earlier is unreachable and therefore deleted.
    var anchor: ?u64 = null;
    {
        var scan = opened.cursor;
        while (try next(&scan)) |record| switch (record) {
            .roster => |roster| {
                if (roster.index <= keep_from) {
                    if (anchor == null or roster.index > anchor.?) anchor = roster.index;
                }
            },
            .tick, .engagements, .progress => {},
        };
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try writeHeader(&out, gpa, opened.header);

    const from = anchor orelse 0;

    var cursor = opened.cursor;
    while (try next(&cursor)) |record| {
        switch (record) {
            .roster => |roster| {
                // Keep the anchor AND every snapshot after it. A future snapshot is not
                // garbage -- it is the NEXT anchor, and throwing it away means the log can
                // never advance past this one. (It did exactly that: the journal kept its
                // snapshot from tick zero forever, could never move the boundary, and grew
                // past a gigabyte. Retention that deletes its own future is not retention.)
                if (roster.index < (anchor orelse 0)) continue;

                try appendInt(&out, gpa, u8, @intFromEnum(Kind.roster));
                try appendInt(&out, gpa, u64, roster.index);
                try appendInt(&out, gpa, u32, roster.count);
                try out.appendSlice(gpa, roster.payload);
            },
            .progress => |pr| {
                // What people EARNED is never deleted. Retention deletes the rooms they were in
                // (I7), not the game they played. Only stale snapshots' copies are dropped.
                if (pr.index < (anchor orelse 0)) continue;

                try appendInt(&out, gpa, u8, @intFromEnum(Kind.progress));
                try appendInt(&out, gpa, u64, pr.index);
                try appendInt(&out, gpa, u32, pr.count);
                try out.appendSlice(gpa, pr.payload);
            },
            .engagements => |e| {
                // The fights in progress belong to their snapshot, and travel with it.
                if (e.index < (anchor orelse 0)) continue;

                try appendInt(&out, gpa, u8, @intFromEnum(Kind.engagements));
                try appendInt(&out, gpa, u64, e.index);
                try appendInt(&out, gpa, u32, e.count);
                try out.appendSlice(gpa, e.payload);
            },
            .tick => |t| {
                if (t.index < from) continue; // deleted, and gone

                try appendInt(&out, gpa, u8, @intFromEnum(Kind.tick));
                try appendInt(&out, gpa, u64, t.index);
                try appendInt(&out, gpa, u32, t.count);
                try out.appendSlice(gpa, t.payload);
            },
        }
    }

    return out;
}

// ---------------------------------------------------------------------------- plumbing

fn appendInt(out: *std.ArrayList(u8), gpa: Allocator, comptime T: type, value: T) Allocator.Error!void {
    var buf: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try out.appendSlice(gpa, &buf);
}

fn readInt(bytes: []const u8, at: usize, comptime T: type) T {
    const size = @divExact(@typeInfo(T).int.bits, 8);
    return std.mem.readInt(T, bytes[at..][0..size], .little);
}

fn take(cursor: *Cursor, comptime T: type) Error!T {
    const size = @divExact(@typeInfo(T).int.bits, 8);
    if (cursor.pos + size > cursor.bytes.len) return Error.Truncated;
    const value = readInt(cursor.bytes, cursor.pos, T);
    cursor.pos += size;
    return value;
}

fn takeSlice(cursor: *Cursor, len: usize) Error![]const u8 {
    if (cursor.pos + len > cursor.bytes.len) return Error.Truncated;
    const slice = cursor.bytes[cursor.pos..][0..len];
    cursor.pos += len;
    return slice;
}

const testing = std.testing;

test "a journal round-trips" {
    const gpa = testing.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try writeHeader(&out, gpa, .{ .seed = 0xABCD, .precision = spatial.default_precision });

    const players = [_]PlayerId{ @enumFromInt(1), @enumFromInt(2), @enumFromInt(3) };
    const factions = [_]Faction{ .human, .zombie, .human };
    const hps = [_]u16{ 100, 90, 80 };
    try writeRoster(&out, gpa, 0, &players, &factions, &hps);

    const cells = [_]CellId{
        spatial.cellFromKey(0xCAFE, spatial.default_precision),
        spatial.cellFromKey(0xCAFE, spatial.default_precision),
        spatial.cellFromKey(0xBEEF, spatial.default_precision),
    };
    try writeTick(&out, gpa, 7, &players, &cells);

    const opened = try open(out.items);
    try testing.expectEqual(@as(u64, 0xABCD), opened.header.seed);
    try testing.expectEqual(spatial.default_precision, opened.header.precision);

    var cursor = opened.cursor;

    const first = (try next(&cursor)).?;
    try testing.expectEqual(@as(u32, 3), first.roster.count);
    try testing.expectEqual(@as(u64, 0), first.roster.index);
    try testing.expectEqual(Faction.zombie, (try rosterEntry(first.roster.payload, 1)).faction);
    try testing.expectEqual(@as(u16, 80), (try rosterEntry(first.roster.payload, 2)).hp);

    const second = (try next(&cursor)).?;
    try testing.expectEqual(@as(u64, 7), second.tick.index);
    try testing.expectEqual(cells[0], report(second.tick.payload, 0).cell);
    try testing.expectEqual(players[2], report(second.tick.payload, 2).player);

    try testing.expectEqual(@as(?Record, null), try next(&cursor));
}

test "a truncated journal is an error, not a shrug" {
    const gpa = testing.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try writeHeader(&out, gpa, .{ .seed = 1, .precision = 39 });
    const players = [_]PlayerId{@enumFromInt(1)};
    const cells = [_]CellId{spatial.cellFromKey(1, 39)};
    try writeTick(&out, gpa, 0, &players, &cells);

    // The machine died mid-write.
    const cut = out.items[0 .. out.items.len - 4];

    const opened = try open(cut);
    var cursor = opened.cursor;
    try testing.expectError(Error.Truncated, next(&cursor));
}

test "a foreign file is refused" {
    const not_ours = [_]u8{0} ** 32;
    try testing.expectError(Error.BadMagic, open(&not_ours));
    try testing.expectError(Error.Truncated, open("abc"));
}

test "retention deletes the cell history and keeps nothing else back" {
    const gpa = testing.allocator;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try writeHeader(&out, gpa, .{ .seed = 5, .precision = 39 });

    const players = [_]PlayerId{ @enumFromInt(1), @enumFromInt(2) };
    const factions = [_]Faction{ .human, .zombie };
    const hps = [_]u16{ 100, 100 };

    // A hundred ticks of history, with the world written down every twenty-five.
    //
    // The snapshots are what make deletion POSSIBLE. Without them the journal could not throw
    // its past away and still be replayable, because replay would have nowhere to start --
    // and a log you cannot replay is not a log, it is a large file.
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        if (i % 25 == 0) try writeRoster(&out, gpa, i, &players, &factions, &hps);

        const cells = [_]CellId{
            spatial.cellFromKey(i, 39),
            spatial.cellFromKey(i, 39),
        };
        try writeTick(&out, gpa, i, &players, &cells);
    }

    // The integrity windows only need the recent past. The rest is deleted (I7).
    var pruned = try prune(gpa, out.items, 80);
    defer pruned.deinit(gpa);

    try testing.expect(pruned.items.len < out.items.len);

    const opened = try open(pruned.items);
    var cursor = opened.cursor;

    var ticks: u32 = 0;
    var rosters: u32 = 0;
    var oldest: u64 = std.math.maxInt(u64);

    while (try next(&cursor)) |record| switch (record) {
        .roster => rosters += 1,
        .engagements, .progress => {},
        .tick => |t| {
            ticks += 1;
            oldest = @min(oldest, t.index);
        },
    };

    // Replay resumes from the snapshot at tick 75 -- the most recent one at or before the
    // retention boundary. Everything before it is gone.
    try testing.expectEqual(@as(u64, 75), oldest);
    try testing.expectEqual(@as(u32, 25), ticks);

    // The snapshot replay starts from survives, and so does every snapshot after it -- a
    // future snapshot is the next anchor, and deleting it would strand the log at this one
    // forever. The three OLDER snapshots are deleted, with the history they anchored.
    // Snapshots were written at 0, 25, 50, 75. The anchor is 75, so it survives and the three
    // older ones are deleted with the history they anchored. (Had the run gone on, every
    // snapshot after 75 would survive too -- a future snapshot is the next anchor.)
    try testing.expectEqual(@as(u32, 1), rosters);
}
