//! CORE (B1, B2). The wire protocol (2.1). A sealed module (D1).
//!
//! Pure: messages to bytes, bytes to messages. It opens no socket and knows what a socket is
//! not. The transport is shell and lives elsewhere -- which means the entire protocol,
//! including the two properties below that the whole design rests on, is testable without a
//! network, a server, or a phone.
//!
//! The wire format appears in no other module's signatures (D3). It is going to change, and
//! it gets expensive to change the moment a client ships.
//!
//! ============================================================================
//! THE CLIENT IS AUTHORITATIVE OVER NOTHING (H1)
//!
//! The client's entire vocabulary is: A SESSION, AND A CELL.
//!
//! It never sends a damage figure, a combat result, an inventory delta, an XP amount, a loot
//! claim, a kill, a level, or a territory capture. Every outcome is computed server-side from
//! data the client cannot influence. The only lie a perfectly modified phone can tell is a
//! FALSE CELL -- and the protocol is designed so that this stays true.
//!
//! That is not a comment. It is a `comptime` assertion at the bottom of `Report`: the build
//! fails if anyone ever adds a field to the client's message. The rule cannot rot, because
//! the compiler is what enforces it.
//!
//! ============================================================================
//! QUORUM SILENCE IS ABSOLUTE, INCLUDING THROUGH TIMING AND SIZE (I3, 2.2)
//!
//! Below k, a cell reports nothing -- and "nothing" has to mean nothing *observable*. If a
//! live cell's reply is 40 bytes and a quiet one's is 12, the size has leaked the count. If a
//! live cell takes 40ms and a dead one takes 12ms, the latency has leaked it. A player with a
//! packet sniffer would learn what the game refuses to tell them, and Section I would be
//! decoration.
//!
//! So: EVERY REPLY IS THE SAME SIZE. Always. A player in a live cell in the middle of a fight
//! and a player alone in an empty field receive byte-count-identical responses, and the quiet
//! ones are byte-IDENTICAL to each other. There is no branch in the encoder on whether
//! anything happened.
//!
//! Timing is the transport's job (see store/transport), and the rule there is the same: reply
//! on the tick, with the same work, whatever the world did.

const std = @import("std");
const combat = @import("combat.zig");
const spatial = @import("spatial.zig");
const tick_mod = @import("tick.zig");
const world = @import("world.zig");

const assert = std.debug.assert;

const CellId = spatial.CellId;
const Crowd = combat.Crowd;
const Momentum = combat.Momentum;

pub const version: u16 = 1;

pub const Error = error{
    BadVersion,
    Truncated,
    /// A byte that is not a value this program has. `Momentum` and `Crowd` are exhaustive
    /// enums, so casting an arbitrary byte into one is ILLEGAL BEHAVIOUR -- a panic, from data
    /// alone. A hostile or broken server could crash every client that parsed its reply.
    ///
    /// Found by the fuzzer. An attacker-controlled integer is never turned into an enum
    /// without a check.
    BadValue,
};

/// A server-issued session. Opaque, unguessable, and it is the ONLY thing that identifies the
/// speaker. It is not derived from anything the user controls (A8).
pub const SessionId = enum(u64) { _ };

// ============================================================================ client -> server

/// EVERYTHING THE CLIENT IS ALLOWED TO SAY.
///
/// A session, and a room. That is the whole vocabulary of the phone.
pub const Report = struct {
    session: SessionId, // u64
    cell: CellId, // u64

    comptime {
        // ------------------------------------------------------------------
        // H1, ENFORCED BY THE COMPILER. Checked FIRST, and deliberately so.
        //
        // Every feature request will want to add a field here. Damage dealt, so the client can
        // "help" resolve a fight. An XP claim, to save a round trip. A loot pickup, because it
        // felt instant on the phone. A kill, a score, a capture. Each will be reasonable, and
        // each hands authority to a device we have decided to believe nothing from.
        //
        // The answer is no, and it is not a review comment: the build fails, and it fails with
        // a sentence explaining why. (The size guard below would also have failed -- but it
        // would have said "expected 16 bytes", which tells the next person to fix the number.
        // The order of these two checks is the difference between a rule and a speed bump.)
        //
        // The only lie a perfectly modified phone can tell is a false cell. This is what keeps
        // that sentence true.
        const permitted = [_][]const u8{ "session", "cell" };

        for (@typeInfo(Report).@"struct".fields) |field| {
            var allowed = false;
            for (permitted) |name| {
                if (std.mem.eql(u8, field.name, name)) allowed = true;
            }
            if (!allowed) {
                @compileError("H1 VIOLATION: the client may not send '" ++ field.name ++
                    "'. The client is authoritative over NOTHING. It transmits a session and a " ++
                    "cell. It never transmits a damage figure, a combat result, an inventory " ++
                    "delta, an XP amount, a loot claim, or a capture -- every outcome is " ++
                    "computed server-side from data the client cannot influence. The only lie a " ++
                    "modified phone can tell is a false cell, and that is the whole point.");
            }
        }

        // THE SIZE GUARD (A7). One per player per tick: the only thing the server ever
        // receives, 333 times a second at ten thousand players.
        assert(@sizeOf(Report) == 16);
    }
};

pub const report_size = 18; // version(2) + session(8) + cell(8)

/// CORE. Encode a report. The client's entire outbound traffic.
pub fn encodeReport(report: Report) [report_size]u8 {
    var out: [report_size]u8 = undefined;
    std.mem.writeInt(u16, out[0..2], version, .little);
    std.mem.writeInt(u64, out[2..10], @intFromEnum(report.session), .little);
    std.mem.writeInt(u64, out[10..18], @intFromEnum(report.cell), .little);
    return out;
}

/// CORE. Decode a report, and refuse anything that is not one (E3).
pub fn decodeReport(bytes: []const u8) Error!Report {
    if (bytes.len != report_size) return Error.Truncated;
    if (std.mem.readInt(u16, bytes[0..2], .little) != version) return Error.BadVersion;

    return .{
        .session = @enumFromInt(std.mem.readInt(u64, bytes[2..10], .little)),
        .cell = @enumFromInt(std.mem.readInt(u64, bytes[10..18], .little)),
    };
}

/// CORE. THE SHELL BOUNDARY (E5). Turn what a phone claimed into something the core may see,
/// or into nothing at all.
///
/// A presence that fails validation is dropped HERE and never enters the core. It is not an
/// error to propagate -- a phone talking nonsense is an absent player, not a failure (E4).
///
/// `wanted` is the precision the server told this client to use (O6). A client reporting a
/// FINER cell than we asked for is coarsened down to the working precision -- which is what
/// makes changing the cell size a server-side config change rather than a flag day, since a
/// mid-rollout mix of client versions still shares rooms. A client reporting a COARSER cell
/// than we asked for cannot be refined, and is dropped.
pub fn validate(report: Report, wanted: u6) ?CellId {
    const value = @intFromEnum(report.cell);
    if (value == 0) return null; // 0 is not a place; a zeroed packet is not a report

    const claimed = spatial.precisionOf(report.cell);
    if (claimed == wanted) return report.cell;
    if (claimed < wanted) return null; // coarser than we asked; we cannot invent the bits back

    return spatial.coarsen(report.cell, claimed - wanted);
}

// ============================================================================ server -> client

/// WHAT THE SERVER SAYS BACK. Always. Every tick. The same size, whatever happened.
///
/// When nothing happened, every field about the fight is zero -- and the response a player
/// gets in a sub-quorum cell is BYTE-IDENTICAL to the one they get standing alone in an empty
/// field, and to the one they get in a live cell whose fight is over. The player cannot tell
/// those apart, and neither can anyone reading their traffic (I3).
pub const Response = struct {
    tick: u64,
    /// What the player has earned in total, and the level it buys. AUTHORITATIVE, from the
    /// server, every tick.
    ///
    /// The client could add up the deltas itself and save six bytes. It will not: state on the
    /// client is state in two places, and state in two places is the oldest source of complexity
    /// in the field. The phone renders what it is told and computes nothing (H1).
    total_xp: u32,
    hp: u16,
    damage: u16,
    xp: u16,
    level: u16,
    momentum: Momentum, // u8
    crowd: Crowd, // u8
    _pad: u16 = 0,

    comptime {
        // THE SIZE GUARD (A7). One per player per tick.
        //
        // A7.1 -- BUDGET RAISED FROM 16 TO 24, DELIBERATELY.
        //
        // The total and the level. Before this, the game sent a per-tick XP delta and kept no
        // total anywhere -- so the client had nothing to display and the server had nothing to
        // remember. Everyone was level one, forever.
        //
        // Eight more bytes per player per tick. At ten thousand players that is 2.6 kB/s across
        // the whole world, against a thirty-second tick budget. It is not a number worth
        // discussing (G3).
        //
        // IT IS STILL CONSTANT, which is the property that actually matters: every reply is the
        // same size, whatever happened, so silence is still exactly as large as a war (I3).
        assert(@sizeOf(Response) == 24);
    }
};

/// CORE. Nothing happened to you.
///
/// This is what an empty field says, what a cell below quorum says, and what a room whose
/// fight has ended says. They are the same sentence, and that is the entire content of I3.
///
/// A free function, not a method: a record contains fields and nothing else (A1). It was a
/// method until the ruleset audit, and it had no business being one.
pub fn quiet(tick: u64, hp: u16, progress: world.Progress) Response {
    return .{
        .tick = tick,
        .total_xp = progress.xp,
        .hp = hp,
        .damage = 0,
        .xp = 0,
        .level = progress.level,
        .momentum = .even,
        .crowd = .a_few,
    };
}

pub const response_size = 22; // tick + total_xp + hp + damage + xp + level + momentum + crowd

/// CORE. Encode a response.
///
/// NOTE WHAT IS NOT HERE: a branch on whether anything happened. There is one encoder, it
/// writes the same sixteen bytes every time, and it does the same work every time. A shorter
/// message for a quiet cell would be a smaller packet, and a smaller packet is a count (I3).
pub fn encodeResponse(response: Response) [response_size]u8 {
    var out: [response_size]u8 = undefined;
    std.mem.writeInt(u64, out[0..8], response.tick, .little);
    std.mem.writeInt(u32, out[8..12], response.total_xp, .little);
    std.mem.writeInt(u16, out[12..14], response.hp, .little);
    std.mem.writeInt(u16, out[14..16], response.damage, .little);
    std.mem.writeInt(u16, out[16..18], response.xp, .little);
    std.mem.writeInt(u16, out[18..20], response.level, .little);
    out[20] = @intFromEnum(response.momentum);
    out[21] = @intFromEnum(response.crowd);
    return out;
}

pub fn decodeResponse(bytes: []const u8) Error!Response {
    if (bytes.len != response_size) return Error.Truncated;

    const momentum: Momentum = switch (bytes[20]) {
        0 => .even,
        1 => .humans_edge,
        2 => .zombies_edge,
        3 => .humans_winning,
        4 => .zombies_winning,
        else => return Error.BadValue,
    };

    const crowd: Crowd = switch (bytes[21]) {
        0 => .a_few,
        1 => .dozens,
        2 => .scores,
        3 => .hundreds,
        4 => .thousands,
        else => return Error.BadValue,
    };

    return .{
        .tick = std.mem.readInt(u64, bytes[0..8], .little),
        .total_xp = std.mem.readInt(u32, bytes[8..12], .little),
        .hp = std.mem.readInt(u16, bytes[12..14], .little),
        .damage = std.mem.readInt(u16, bytes[14..16], .little),
        .xp = std.mem.readInt(u16, bytes[16..18], .little),
        .level = std.mem.readInt(u16, bytes[18..20], .little),
        .momentum = momentum,
        .crowd = crowd,
    };
}

/// CORE. What the server says to a player, given what the tick did to them -- or did not.
pub fn respond(tick: u64, hp: u16, progress: world.Progress, told: ?tick_mod.Tell) Response {
    const tell = told orelse return quiet(tick, hp, progress);

    return .{
        .tick = tick,
        .total_xp = progress.xp,
        .hp = tell.hp,
        .damage = tell.damage,
        .xp = tell.xp,
        .level = progress.level,
        .momentum = tell.momentum,
        .crowd = tell.crowd,
    };
}

// ============================================================================ hello

/// The client's first and only other sentence: prove who you are.
///
/// FIXED SIZE, LIKE EVERYTHING ELSE ON THIS WIRE. There is no length field anywhere in this
/// protocol, which means there is no length field to lie about -- the entire class of
/// "attacker claims this array has four billion elements" simply does not exist here. Every
/// frame is exactly as long as it is, or it is not a frame.
///
/// The contact point and password travel in the clear INSIDE TLS, which is where they are meant
/// to travel. The server hashes the contact with its pepper and derives the verifier; neither
/// the address nor the password is ever stored (credential.zig).
///
/// A7.2: cold struct, size guard waived -- one per session, at the very start of it.
pub const Hello = struct {
    /// Zero-padded. Not a length-prefixed string: see above.
    contact: [64]u8,
    password: [64]u8,
    /// Chosen once, permanently, and only honoured on registration.
    faction: world.Faction,
    /// Registering, or logging in.
    intent: Intent,

    pub const Intent = enum(u8) { register, login };
};

pub const hello_size = 2 + 64 + 64 + 1 + 1; // version + contact + password + faction + intent

pub fn encodeHello(hello: Hello) [hello_size]u8 {
    var out: [hello_size]u8 = undefined;
    std.mem.writeInt(u16, out[0..2], version, .little);
    @memcpy(out[2..66], &hello.contact);
    @memcpy(out[66..130], &hello.password);
    out[130] = @intFromEnum(hello.faction);
    out[131] = @intFromEnum(hello.intent);
    return out;
}

pub fn decodeHello(bytes: []const u8) Error!Hello {
    if (bytes.len != hello_size) return Error.Truncated;
    if (std.mem.readInt(u16, bytes[0..2], .little) != version) return Error.BadVersion;

    // An attacker-controlled byte is never cast into an enum (see Error.BadValue). This is the
    // crash the fuzzer found, and it is a class, not an instance.
    const faction: world.Faction = switch (bytes[130]) {
        0 => .human,
        1 => .zombie,
        else => return Error.BadValue,
    };

    const intent: Hello.Intent = switch (bytes[131]) {
        0 => .register,
        1 => .login,
        else => return Error.BadValue,
    };

    var hello: Hello = .{
        .contact = undefined,
        .password = undefined,
        .faction = faction,
        .intent = intent,
    };
    @memcpy(&hello.contact, bytes[2..66]);
    @memcpy(&hello.password, bytes[66..130]);
    return hello;
}

/// The bytes of a zero-padded field, without the padding.
pub fn unpad(field: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
    return field[0..end];
}

// ============================================================================ handshake

/// The server tells the client how to quantize (O6).
///
/// THIS IS WHY CELL SIZE IS NOT A ONE-WAY DOOR. The precision lives on the server. A client
/// asks, is told, and quantizes to exactly that -- so changing the cell size is a config
/// change that clients pick up on their next session, not a flag day and not an app update.
///
/// It does not mean collecting finer location "just in case": the client quantizes to the
/// precision it was given, and the raw coordinate still dies on the phone (B6).
///
/// A7.2: cold struct, size guard waived -- one per session, never in a hot loop.
pub const Welcome = struct {
    session: SessionId,
    /// Quantize at this many geohash bits. Nothing finer. Nothing coarser.
    precision: u6,
    /// Seconds between ticks. The client uses it to pace GPS, which is a battery decision
    /// before it is a protocol one (G5).
    tick_seconds: u8,
};

pub const welcome_size = 10;

pub fn encodeWelcome(welcome: Welcome) [welcome_size]u8 {
    var out: [welcome_size]u8 = undefined;
    std.mem.writeInt(u64, out[0..8], @intFromEnum(welcome.session), .little);
    out[8] = welcome.precision;
    out[9] = welcome.tick_seconds;
    return out;
}

pub fn decodeWelcome(bytes: []const u8) Error!Welcome {
    if (bytes.len != welcome_size) return Error.Truncated;
    return .{
        .session = @enumFromInt(std.mem.readInt(u64, bytes[0..8], .little)),
        .precision = @intCast(bytes[8] & 0x3f),
        .tick_seconds = bytes[9],
    };
}

const testing = std.testing;

test "the client's entire vocabulary is a session and a cell" {
    // H1. The compiler already refuses to build a Report with any other field (see the
    // comptime block). This asserts the shape a human reads.
    const fields = @typeInfo(Report).@"struct".fields;
    try testing.expectEqual(@as(usize, 2), fields.len);
    try testing.expectEqualStrings("session", fields[0].name);
    try testing.expectEqualStrings("cell", fields[1].name);
}

test "a report round-trips" {
    const report: Report = .{
        .session = @enumFromInt(0xABCD),
        .cell = spatial.cellFromKey(0xCAFE, spatial.default_precision),
    };

    const bytes = encodeReport(report);
    const back = try decodeReport(&bytes);

    try testing.expectEqual(report.session, back.session);
    try testing.expectEqual(report.cell, back.cell);
}

test "a report from another version is refused" {
    var bytes = encodeReport(.{ .session = @enumFromInt(1), .cell = spatial.cellFromKey(1, 39) });
    bytes[0] = 99; // a client from the future, or from nowhere

    try testing.expectError(Error.BadVersion, decodeReport(&bytes));
    try testing.expectError(Error.Truncated, decodeReport(bytes[0..4]));
}

test "SILENCE IS THE SAME SIZE AS A WAR" {
    // I3, 2.2. The nasty edge of quorum silence: if a live cell's reply is bigger than a quiet
    // one's, the SIZE has leaked the count, and anyone watching the traffic learns what the
    // game refuses to say.
    const fighting = encodeResponse(.{
        .tick = 900,
        .total_xp = 4200,
        .hp = 62,
        .damage = 18,
        .xp = 10,
        .level = 7,
        .momentum = .zombies_winning,
        .crowd = .hundreds,
    });

    const nothing = encodeResponse(quiet(900, 100, .{ .xp = 4200, .level = 7 }));

    try testing.expectEqual(fighting.len, nothing.len);
    try testing.expectEqual(@as(usize, response_size), fighting.len);
}

test "AN EMPTY FIELD AND A CELL BELOW QUORUM SAY EXACTLY THE SAME THING" {
    // The claim I3 actually makes, as bytes.
    //
    // A player standing alone in a field. A player in a cell with two other people, below
    // quorum. A player in a crowded room whose fight has already ended. All three receive the
    // same sixteen bytes, and there is no branch anywhere that could make them differ.
    const tick: u64 = 4242;
    const hp: u16 = 87;

    const earned: world.Progress = .{ .xp = 1234, .level = 4 };

    const alone_in_a_field = encodeResponse(respond(tick, hp, earned, null));
    const below_quorum = encodeResponse(respond(tick, hp, earned, null));
    const room_already_fought = encodeResponse(respond(tick, hp, earned, null));

    try testing.expectEqualSlices(u8, &alone_in_a_field, &below_quorum);
    try testing.expectEqualSlices(u8, &alone_in_a_field, &room_already_fought);

    // And it is indistinguishable from the response of a player who is simply not playing.
    try testing.expectEqualSlices(u8, &alone_in_a_field, &encodeResponse(quiet(tick, hp, earned)));
}

test "a response round-trips, fighting or quiet" {
    const fighting: Response = .{
        .tick = 7,
        .total_xp = 900,
        .hp = 40,
        .damage = 24,
        .xp = 10,
        .level = 3,
        .momentum = .humans_edge,
        .crowd = .dozens,
    };

    const back = try decodeResponse(&encodeResponse(fighting));
    try testing.expectEqual(fighting.hp, back.hp);
    try testing.expectEqual(fighting.momentum, back.momentum);
    try testing.expectEqual(fighting.crowd, back.crowd);

    const nothing = try decodeResponse(&encodeResponse(quiet(7, 100, .{ .xp = 0, .level = 1 })));
    try testing.expectEqual(@as(u16, 0), nothing.damage);
    try testing.expectEqual(@as(u16, 0), nothing.xp);
}

test "the server tells the client how to quantize" {
    // O6. The precision lives on the server, so cell size is a config change and not a flag
    // day.
    const welcome: Welcome = .{
        .session = @enumFromInt(0x5E5510),
        .precision = spatial.default_precision,
        .tick_seconds = 30,
    };

    const back = try decodeWelcome(&encodeWelcome(welcome));
    try testing.expectEqual(welcome.session, back.session);
    try testing.expectEqual(welcome.precision, back.precision);
    try testing.expectEqual(@as(u8, 30), back.tick_seconds);
}

test "a client reporting a finer cell than we asked for is coarsened, not trusted" {
    // The rollout case. The server moves to a coarser working precision; old clients keep
    // sending the finer cells they were built with. Coarsening is a bit-shift, so they still
    // share rooms with everyone else and nobody has a flag day (O6).
    const wanted: u6 = 37;
    const fine = spatial.cellFromKey(0xABCDEF, 39);

    const validated = validate(.{ .session = @enumFromInt(1), .cell = fine }, wanted).?;

    try testing.expectEqual(wanted, spatial.precisionOf(validated));
    try testing.expectEqual(spatial.coarsen(fine, 2), validated);
}

test "a client reporting a coarser cell than we asked for is dropped at the shell" {
    // We cannot invent the bits back, and a coarse cell would silently fuse rooms. It is not
    // an error to propagate -- it is an absent player (E4, E5).
    const wanted: u6 = 39;
    const coarse = spatial.cellFromKey(0xABC, 35);

    try testing.expectEqual(
        @as(?CellId, null),
        validate(.{ .session = @enumFromInt(1), .cell = coarse }, wanted),
    );
}

test "a zeroed packet is not a place" {
    const wanted: u6 = 39;
    try testing.expectEqual(
        @as(?CellId, null),
        validate(.{ .session = @enumFromInt(1), .cell = @enumFromInt(0) }, wanted),
    );
}

test "the only lie a modified phone can tell is a false cell" {
    // H1, stated as a test. A perfectly modified client can put ANY value in the report and
    // the worst it achieves is claiming to be in a room it is not in.
    //
    // It cannot claim damage: there is no field for it.
    // It cannot claim XP: there is no field for it.
    // It cannot claim loot, a kill, a level, or a capture: there are no fields for them.
    //
    // The report is 18 bytes and every one of them is either a session it was given or a cell
    // it claims. There is nothing else on the wire to forge.
    try testing.expectEqual(@as(usize, 18), report_size);
    try testing.expectEqual(@as(usize, 2), @typeInfo(Report).@"struct".fields.len);

    // And a false cell buys nothing: it is worth nothing without k real humans standing in it
    // (H2), and no exploit conjures strangers into a room.
}

test "an attacker-controlled byte is never cast into an enum" {
    // THE CRASH THE FUZZER FOUND, ON ITS FIRST RUN.
    //
    // Momentum and Crowd are exhaustive enums, so @enumFromInt on an arbitrary byte is ILLEGAL
    // BEHAVIOUR -- a panic, from data alone. A hostile or merely broken server could crash every
    // client that parsed its reply, with a single byte.
    //
    // A network- or disk-derived integer is never turned into an enum without a check.
    var bytes = encodeResponse(quiet(1, 100, .{ .xp = 0, .level = 1 }));

    bytes[20] = 200; // not a momentum
    try testing.expectError(Error.BadValue, decodeResponse(&bytes));

    bytes[20] = 0;
    bytes[21] = 77; // not a crowd
    try testing.expectError(Error.BadValue, decodeResponse(&bytes));

    // And every legal value still decodes.
    bytes[21] = 4;
    _ = try decodeResponse(&bytes);
}
