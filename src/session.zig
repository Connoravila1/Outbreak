//! CORE (B1, B2). Sessions: who is connected, what they last claimed, and what they are told.
//!
//! This is the whole server, minus the socket. It is pure, which means the two properties the
//! entire design rests on -- H1 (the client is authoritative over nothing) and I3 (quorum
//! silence is absolute, including through message size) -- are testable without a network, a
//! VPS, or a phone.
//!
//! THE TICK IS SACRED (E5). Nothing a client does can abort, delay, or partially apply a tick.
//! A malformed report, a client that vanishes, a client that reports a cell from the future,
//! a client that reports nothing at all -- each is DROPPED HERE, at the shell boundary, and
//! the tick resolves the world from the data it has. There is no error path from a packet to
//! the core.

const std = @import("std");
const combat = @import("combat.zig");
const protocol = @import("protocol.zig");
const spatial = @import("spatial.zig");
const tick_mod = @import("tick.zig");
const world_mod = @import("world.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const CellId = spatial.CellId;
const Faction = world_mod.Faction;
const PlayerId = world_mod.PlayerId;
const SessionId = protocol.SessionId;
const World = world_mod.World;

/// What the server remembers about one connected player.
///
/// A7.2: cold struct, size guard waived -- one per connected player, and it is not walked in
/// a hot loop; the world's columns are.
pub const Session = struct {
    player: PlayerId,
    /// The room they last claimed. Null if they have not reported since the last tick -- which
    /// is not an error, it is an absent presence (E4).
    claimed: ?CellId = null,
};

pub const Server = struct {
    world: World,
    sessions: std.AutoHashMapUnmanaged(SessionId, Session),

    /// The precision every client is told to quantize at (O6). Server-side, so changing the
    /// cell size is a config change rather than a flag day.
    precision: u6,
    seed: u64,
    tick_index: u64,
    next_player: u32,

    pub fn empty(seed: u64, precision: u6) Server {
        return .{
            .world = .empty,
            .sessions = .empty,
            .precision = precision,
            .seed = seed,
            .tick_index = 0,
            .next_player = 1,
        };
    }
};

pub fn deinit(server: *Server, gpa: Allocator) void {
    world_mod.deinit(&server.world, gpa);
    server.sessions.deinit(gpa);
    server.* = .empty(server.seed, server.precision);
}

/// CORE. A player joins. Faction is chosen once, here, and never again (2.4).
///
/// THE SESSION ID IS SUPPLIED BY THE SHELL, and it must come from a CSPRNG (`entropy.zig`).
/// The core does not mint it, and cannot: randomness is I/O and I/O lives in the shell (B3).
///
/// This signature is the fix for a real vulnerability. The first version minted the id here,
/// with the tick's splitmix64 mixer -- which is a bijection, trivially invertible, seeded from
/// the server seed and the player id. Session ids were FORGEABLE: an attacker holding their
/// own session could invert the mix and derive other players'. A forged session in this game
/// means impersonating a real person and moving where the system believes they are.
///
/// The deterministic mixer exists so a fight replays. It is not a source of secrets. Passing
/// the id in makes it impossible to reach for the wrong one by accident.
///
/// An id issued this way is also opaque: it reveals no creation order, and therefore leaks no
/// population count (A8).
pub fn join(
    server: *Server,
    gpa: Allocator,
    faction: Faction,
    session: SessionId,
) Allocator.Error!protocol.Welcome {
    const player: PlayerId = @enumFromInt(server.next_player);
    server.next_player += 1;

    try server.sessions.put(gpa, session, .{ .player = player });

    try world_mod.add(&server.world, gpa, .{
        // Nowhere, until they say otherwise. A player who has never reported is not in a room --
        // and is not in a room WITH everyone else who has never reported, which is the trap.
        .cell = spatial.nowhere,
        .player = player,
        .hp = (combat.Rules.default).max_hp,
        .faction = faction,
    });

    return .{
        .session = session,
        .precision = server.precision,
        .tick_seconds = 30,
    };
}

/// CORE. A phone said something. Believe as little of it as possible.
///
/// Returns false if the report was discarded -- an unknown session, a cell we did not ask for,
/// a zeroed packet. A discarded report is not an error and does not propagate: the player is
/// simply not somewhere this tick (E4, E5).
pub fn ingest(server: *Server, report: protocol.Report) bool {
    const session = server.sessions.getPtr(report.session) orelse return false;

    // The shell boundary. A cell finer than we asked for is coarsened; a coarser one, or a
    // zeroed one, is dropped and never reaches the core.
    const cell = protocol.validate(report, server.precision) orelse return false;

    session.claimed = cell;
    return true;
}

/// CORE. Resolve the tick, and tell every session what happened to them -- INCLUDING the ones
/// that nothing happened to.
///
/// The caller owns the returned responses (C1, C5). There is one per session, always, in
/// sorted order, whatever the world did.
pub fn tick(server: *Server, gpa: Allocator, scratch: Allocator) Allocator.Error![]Reply {
    // Move everyone to where they claimed to be. A player who did not report keeps their last
    // room -- the phone may simply be asleep, and a missing packet is not a teleport.
    const players = server.world.presences.items(.player);
    const cells = server.world.presences.items(.cell);

    var by_player: std.AutoHashMapUnmanaged(PlayerId, CellId) = .empty;
    defer by_player.deinit(scratch);

    var it = server.sessions.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.claimed) |cell| {
            try by_player.put(scratch, entry.value_ptr.player, cell);
        }
    }

    for (players, cells) |player, *cell| {
        if (by_player.get(player)) |claimed| cell.* = claimed;
    }

    const result = try tick_mod.tick(
        &server.world,
        gpa,
        scratch,
        server.seed,
        server.tick_index,
        .default,
    );
    defer scratch.free(result.tells);

    // Who was told something? Everyone else gets silence -- and silence is the same size.
    var told: std.AutoHashMapUnmanaged(PlayerId, tick_mod.Tell) = .empty;
    defer told.deinit(scratch);
    for (result.tells) |tell| try told.put(scratch, tell.player, tell);

    const hp_by_player = server.world.presences.items(.hp);
    const player_col = server.world.presences.items(.player);

    var hp: std.AutoHashMapUnmanaged(PlayerId, u16) = .empty;
    defer hp.deinit(scratch);
    for (player_col, hp_by_player) |player, points| try hp.put(scratch, player, points);

    var replies: std.ArrayList(Reply) = .empty;
    defer replies.deinit(gpa);
    try replies.ensureTotalCapacity(gpa, server.sessions.count());

    var sessions = server.sessions.iterator();
    while (sessions.next()) |entry| {
        const player = entry.value_ptr.player;

        replies.appendAssumeCapacity(.{
            .session = entry.key_ptr.*,
            .response = protocol.respond(
                server.tick_index,
                hp.get(player) orelse 0,
                told.get(player),
            ),
        });

        // The claim expires with the tick. A phone that goes quiet does not keep asserting a
        // room forever; it keeps its last position in the world, and says nothing new.
        entry.value_ptr.claimed = null;
    }

    // Hash map iteration order is not a thing we rely on (B8).
    const out = try replies.toOwnedSlice(gpa);
    std.mem.sort(Reply, out, {}, lessThanReply);

    server.tick_index += 1;
    return out;
}

pub const Reply = struct {
    session: SessionId,
    response: protocol.Response,
};

fn lessThanReply(_: void, a: Reply, b: Reply) bool {
    return @intFromEnum(a.session) < @intFromEnum(b.session);
}

const testing = std.testing;

/// A stand-in for the shell's CSPRNG. In the real server these come from `entropy.newSession`,
/// which syscalls the OS; a test needs them to be reproducible, so it supplies its own.
fn joinAt(server: *Server, gpa: Allocator, faction: Faction, fake_session: u64) !SessionId {
    const welcome = try join(server, gpa, faction, @enumFromInt(fake_session));
    return welcome.session;
}

test "a session is issued, and it is not the player id" {
    const gpa = testing.allocator;

    var server: Server = .empty(0xABC, spatial.default_precision);
    defer deinit(&server, gpa);

    // In production these come from entropy.newSession -- the OS CSPRNG. The core does not
    // mint them and cannot: randomness is I/O, and I/O lives in the shell (B3).
    const a = try join(&server, gpa, .human, @enumFromInt(0xA11CE5));
    const b = try join(&server, gpa, .zombie, @enumFromInt(0xB0B));

    try testing.expect(a.session != b.session);

    // And the server tells the client how to quantize (O6).
    try testing.expectEqual(spatial.default_precision, a.precision);
}

test "a report from an unknown session is dropped" {
    const gpa = testing.allocator;

    var server: Server = .empty(1, spatial.default_precision);
    defer deinit(&server, gpa);

    const dropped = ingest(&server, .{
        .session = @enumFromInt(0xDEADBEEF),
        .cell = spatial.cellFromKey(1, spatial.default_precision),
    });

    try testing.expect(!dropped);
}

test "THE PHASE 2 EXIT CRITERION" {
    // > Two clients, standing in the same cell, on opposite factions, fight -- and the
    // > responses from a sub-quorum cell are byte-identical to those from an empty one.
    //
    // This is I3 as bytes on a wire, and it is the property a packet sniffer would attack.
    const gpa = testing.allocator;
    const p = spatial.default_precision;
    const cafe = spatial.cellFromKey(0xCAFE, p);
    const empty_field = spatial.cellFromKey(0xF1E1D, p);

    var server: Server = .empty(0x5EED, p);
    defer deinit(&server, gpa);

    // Two players, opposite factions, in the same café. That is BELOW QUORUM (k = 3).
    const a = try joinAt(&server, gpa, .human, 11);
    const b = try joinAt(&server, gpa, .zombie, 22);

    // And one player standing alone in a field, on the other side of the city.
    const c = try joinAt(&server, gpa, .human, 33);

    try testing.expect(ingest(&server, .{ .session = a, .cell = cafe }));
    try testing.expect(ingest(&server, .{ .session = b, .cell = cafe }));
    try testing.expect(ingest(&server, .{ .session = c, .cell = empty_field }));

    const replies = try tick(&server, gpa, gpa);
    defer gpa.free(replies);

    try testing.expectEqual(@as(usize, 3), replies.len);

    // Find each player's bytes on the wire.
    var cafe_bytes: [protocol.response_size]u8 = undefined;
    var field_bytes: [protocol.response_size]u8 = undefined;

    for (replies) |reply| {
        const encoded = protocol.encodeResponse(reply.response);
        if (reply.session == a) cafe_bytes = encoded;
        if (reply.session == c) field_bytes = encoded;
    }

    // THE WHOLE OF I3, ON THE WIRE.
    //
    // The player standing in a café with a hostile two feet away, below quorum, receives
    // EXACTLY the bytes received by the player standing alone in an empty field. Not a similar
    // message. Not a shorter one. The same sixteen bytes.
    //
    // There is no count to read, no flag to test, and nothing in the packet length to measure.
    // A cell below quorum is indistinguishable from an empty field, and it is indistinguishable
    // to someone reading the traffic, not merely to someone reading the screen.
    try testing.expectEqualSlices(u8, &field_bytes, &cafe_bytes);
}

test "and when quorum is reached, the fight is real" {
    // The other half: silence is not the only thing the protocol can say. Add a third person
    // and the café goes live.
    const gpa = testing.allocator;
    const p = spatial.default_precision;
    const cafe = spatial.cellFromKey(0xCAFE, p);

    var server: Server = .empty(0x5EED, p);
    defer deinit(&server, gpa);

    const a = try joinAt(&server, gpa, .human, 11);
    const b = try joinAt(&server, gpa, .zombie, 22);
    const c = try joinAt(&server, gpa, .zombie, 33);

    for ([_]SessionId{ a, b, c }) |session| {
        try testing.expect(ingest(&server, .{ .session = session, .cell = cafe }));
    }

    const replies = try tick(&server, gpa, gpa);
    defer gpa.free(replies);

    var human_took_damage = false;
    for (replies) |reply| {
        if (reply.session == a and reply.response.damage > 0) human_took_damage = true;
    }

    try testing.expect(human_took_damage);

    // But the response is still exactly the same size as silence. Always.
    for (replies) |reply| {
        try testing.expectEqual(
            @as(usize, protocol.response_size),
            protocol.encodeResponse(reply.response).len,
        );
    }
}

test "every session gets a reply, every tick, whatever happened" {
    // The shape of the traffic must not depend on the state of the world. If a quiet player got
    // NO packet while a fighting one got a packet, then the presence of a packet is a signal --
    // and the fact of being in a live cell would leak from the traffic pattern alone (I3).
    const gpa = testing.allocator;

    var server: Server = .empty(7, spatial.default_precision);
    defer deinit(&server, gpa);

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        _ = try join(&server, gpa, if (i % 2 == 0) .human else .zombie, @enumFromInt(0x1000 + i));
    }

    // Nobody reports anything at all. Ten silent phones.
    const replies = try tick(&server, gpa, gpa);
    defer gpa.free(replies);

    try testing.expectEqual(@as(usize, 10), replies.len);
    for (replies) |reply| {
        try testing.expectEqual(@as(u16, 0), reply.response.damage);
        try testing.expectEqual(@as(u16, 0), reply.response.xp);
    }
}

test "a client that lies about its cell arrives at silence" {
    // H2, on the wire. A perfectly modified phone can claim to be anywhere. It claims to be in
    // the most valuable cell it can think of -- and there is no such cell, so it arrives at
    // nothing.
    const gpa = testing.allocator;
    const p = spatial.default_precision;

    var server: Server = .empty(3, p);
    defer deinit(&server, gpa);

    const honest = try joinAt(&server, gpa, .human, 1);
    const liar = try joinAt(&server, gpa, .zombie, 2);

    try testing.expect(ingest(&server, .{ .session = honest, .cell = spatial.cellFromKey(1, p) }));

    // The liar teleports somewhere else entirely. Anywhere. It does not matter.
    try testing.expect(ingest(&server, .{ .session = liar, .cell = spatial.cellFromKey(0xFFFFFF, p) }));

    const replies = try tick(&server, gpa, gpa);
    defer gpa.free(replies);

    // They arrive at silence, because a cell is worth nothing without k real humans in it, and
    // no exploit conjures strangers into a room. There is no destination.
    for (replies) |reply| {
        try testing.expectEqual(@as(u16, 0), reply.response.xp);
    }
}

test "the tick is sacred: a flood of garbage cannot stop it" {
    // E5. Malformed reports, unknown sessions, zeroed packets, cells at the wrong precision --
    // all of it is dropped at the boundary, and the tick resolves the world from the data it
    // has. There is no error path from a packet to the core.
    const gpa = testing.allocator;
    const p = spatial.default_precision;

    var server: Server = .empty(9, p);
    defer deinit(&server, gpa);

    const real = try joinAt(&server, gpa, .human, 1);

    // Every bad thing a phone can say.
    _ = ingest(&server, .{ .session = @enumFromInt(0), .cell = spatial.cellFromKey(1, p) });
    _ = ingest(&server, .{ .session = @enumFromInt(0xBAD), .cell = spatial.cellFromKey(1, p) });
    _ = ingest(&server, .{ .session = real, .cell = @enumFromInt(0) }); // a zeroed cell
    _ = ingest(&server, .{ .session = real, .cell = spatial.cellFromKey(1, 20) }); // wrong precision

    // The tick runs anyway, and the real player is still there.
    const replies = try tick(&server, gpa, gpa);
    defer gpa.free(replies);

    try testing.expectEqual(@as(usize, 1), replies.len);
    try testing.expectEqual(real, replies[0].session);
}
