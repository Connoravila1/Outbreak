//! SHELL (B1, B3). THE C ABI. What the phone is allowed to ask the core to do.
//!
//! This is the whole surface between the Zig core and the Kotlin (later, Swift) shell. It is
//! deliberately tiny, and what it LEAVES OUT is the point.
//!
//! ============================================================================
//! THE PHONE COMPUTES NOTHING (H1)
//!
//! Look at what is exported below. There is no combat here. No tick. No quorum. No XP. No
//! damage. No loot. The phone cannot resolve a fight because THE CODE TO RESOLVE A FIGHT IS NOT
//! REACHABLE FROM THIS FILE, and the build guard fails if anyone makes it reachable.
//!
//! The phone can do exactly three things:
//!
//!   1. Turn a GPS reading into a room, and forget the reading.
//!   2. Put bytes on a wire.
//!   3. Take bytes off a wire and read what it was told.
//!
//! That is the entire vocabulary of a device we have decided to believe nothing from. Every
//! outcome is computed server-side from data the client cannot influence, and the only lie a
//! perfectly modified phone can tell is a false cell -- which is worth nothing, because no cell
//! is worth reaching (H2).
//!
//! ============================================================================
//! THE COORDINATE WALL RUNS THROUGH THIS FILE (B6)
//!
//! `outbreak_quantize` is THE ONLY FUNCTION IN THE ENTIRE SYSTEM, on either side of the network,
//! that accepts a latitude and a longitude. It takes them, turns them into a u64, and returns.
//! The floats are dead the instant it returns: they are not stored, not cached, not logged, and
//! not sent anywhere.
//!
//! The Kotlin side must do the same -- take the Location object, call this, and drop it. The
//! roadmap is explicit: "Raw location dies here." This function is the "here".
//!
//! ============================================================================
//! A PANIC ACROSS AN FFI BOUNDARY IS UNDEFINED BEHAVIOUR
//!
//! Zig unwinding into the JVM is not a defined operation. It is not a crash we can debug; it is
//! a corrupted runtime.
//!
//! So NOTHING HERE MAY PANIC. Every function validates its arguments and returns a status code.
//! There is no `unreachable`, no unchecked `@intCast`, no `.?` on an optional, and no slice
//! indexed without a bounds check. A hostile or merely buggy caller gets an error code, never a
//! signal.
//!
//! This is E3 (errors explicit in signatures) expressed in a language that has no error unions:
//! the error IS the return value.

const std = @import("std");
const loadout = @import("loadout.zig");
const protocol = @import("protocol.zig");
const spatial = @import("spatial.zig");

/// Status codes. Zero is success, and every failure has a name.
///
/// The C ABI has no error unions, so the error is the return value (E3). A caller that ignores
/// it gets a zeroed output and no data -- never a corrupted one.
pub const Status = enum(c_int) {
    ok = 0,
    /// The GPS reading was NaN, infinite, or off the planet. Not an error: an absent fix (E4).
    bad_coordinate = 1,
    /// The buffer the caller gave us is the wrong size.
    bad_buffer = 2,
    /// The bytes on the wire are not a message we understand.
    bad_message = 3,
    /// A version we do not speak.
    bad_version = 4,
    /// A field carrying a value that does not exist. (The crash the fuzzer found; never a panic.)
    bad_value = 5,
};

/// THE COORDINATE WALL, AND THE ONLY DOOR IN IT (B6).
///
/// A latitude and a longitude go in. A room comes out. The floats do not survive the return.
///
/// Returns 0 -- which is never a valid cell, because every real cell carries a sentinel bit --
/// if the fix is unusable. An unusable fix is not an error; it is a phone that does not currently
/// know where it is, which is an ordinary condition and not a failure (E4).
export fn outbreak_quantize(lat: f64, lon: f64, precision: u8) u64 {
    if (precision == 0 or precision > spatial.max_precision) return 0;

    const cell = spatial.quantize(lat, lon, @intCast(precision)) orelse return 0;
    return @intFromEnum(cell);
}

/// The precision to quantize at, if the server has not said otherwise yet.
export fn outbreak_default_precision() u8 {
    return spatial.default_precision;
}

/// The size of each frame, so the Kotlin side never guesses.
export fn outbreak_hello_size() c_int {
    return protocol.hello_size;
}

export fn outbreak_report_size() c_int {
    return protocol.report_size;
}

export fn outbreak_response_size() c_int {
    return protocol.response_size;
}

export fn outbreak_welcome_size() c_int {
    return protocol.welcome_size;
}

/// Put a login/registration on the wire.
///
/// `contact` and `password` are NUL-terminated. They are copied into the frame and this function
/// keeps nothing.
export fn outbreak_encode_hello(
    contact: [*:0]const u8,
    password: [*:0]const u8,
    faction: u8,
    registering: bool,
    out: [*]u8,
    out_len: c_int,
) Status {
    if (out_len != protocol.hello_size) return .bad_buffer;
    if (faction > 1) return .bad_value;

    const contact_slice = std.mem.span(contact);
    const password_slice = std.mem.span(password);

    // Bounds-checked, because a caller who hands us a 400-byte email must get an error and not a
    // smashed stack. (This is the "never index without a bounds check" rule, and it is the whole
    // reason this file exists rather than letting Kotlin build the frame itself.)
    if (contact_slice.len >= 64 or password_slice.len >= 64) return .bad_buffer;

    var hello: protocol.Hello = .{
        .contact = @splat(0),
        .password = @splat(0),
        .faction = if (faction == 0) .human else .zombie,
        .intent = if (registering) .register else .login,
    };
    @memcpy(hello.contact[0..contact_slice.len], contact_slice);
    @memcpy(hello.password[0..password_slice.len], password_slice);

    const bytes = protocol.encodeHello(hello);
    @memcpy(out[0..protocol.hello_size], &bytes);
    return .ok;
}

/// What the server said when we said hello.
export fn outbreak_decode_welcome(
    bytes: [*]const u8,
    len: c_int,
    out_session: *u64,
    out_precision: *u8,
    out_tick_seconds: *u8,
) Status {
    if (len != protocol.welcome_size) return .bad_buffer;

    const welcome = protocol.decodeWelcome(bytes[0..protocol.welcome_size]) catch |err| {
        return switch (err) {
            error.BadVersion => .bad_version,
            error.Truncated => .bad_buffer,
            error.BadValue => .bad_value,
        };
    };

    out_session.* = @intFromEnum(welcome.session);
    out_precision.* = welcome.precision;
    out_tick_seconds.* = welcome.tick_seconds;
    return .ok;
}

/// THE ENTIRE OUTBOUND VOCABULARY OF THE PHONE, AFTER THE HANDSHAKE.
///
/// Identity and location plus bounded equipment intent. The server still authors every outcome.
export fn outbreak_encode_report(
    session: u64,
    cell: u64,
    kit: u8,
    weapon: u8,
    armor: u8,
    utility: u8,
    out: [*]u8,
    out_len: c_int,
) Status {
    if (out_len != protocol.report_size) return .bad_buffer;
    if (cell == 0) return .bad_coordinate; // nowhere is not somewhere
    if (kit > 2) return .bad_value;
    const equipped: loadout.Loadout = .{
        .weapon = loadout.itemFromByte(weapon) orelse return .bad_value,
        .armor = loadout.itemFromByte(armor) orelse return .bad_value,
        .utility = loadout.itemFromByte(utility) orelse return .bad_value,
    };
    if (loadout.definition(equipped.weapon).slot != .weapon or
        loadout.definition(equipped.armor).slot != .armor or
        loadout.definition(equipped.utility).slot != .utility) return .bad_value;

    const bytes = protocol.encodeReport(.{
        .session = @enumFromInt(session),
        .cell = @enumFromInt(cell),
        .kit = switch (kit) { 1 => .raider, 2 => .bulwark, else => .field },
        .equipped = equipped,
    });
    @memcpy(out[0..protocol.report_size], &bytes);
    return .ok;
}

/// What the phone is told. A plain struct, so Kotlin can read it without knowing the wire format
/// (D3: the wire layout appears in no other module's signatures -- including the client's).
pub const Tell = extern struct {
    tick: u64,
    total_xp: u32,
    hp: u16,
    damage: u16,
    xp: u16,
    level: u16,
    /// 0 even, 1 humans_edge, 2 zombies_edge, 3 humans_winning, 4 zombies_winning.
    momentum: u8,
    /// 0 a_few, 1 dozens, 2 scores, 3 hundreds, 4 thousands.
    crowd: u8,
    kit: u8,
    reward: u8,
    salvage: u16,
    owned: u32,
    weapon: u8,
    armor: u8,
    utility: u8,
    item: u8,
    discovered: u8,
    capacity: u8,
};

/// Take bytes off the wire and read what we were told.
///
/// Never panics on a hostile server. An enum byte we do not recognise is `bad_value`, not an
/// illegal cast -- which is the crash the fuzzer found on the server side, and it would have
/// been exactly as fatal here.
export fn outbreak_decode_tell(bytes: [*]const u8, len: c_int, out: *Tell) Status {
    if (len != protocol.response_size) return .bad_buffer;

    const response = protocol.decodeResponse(bytes[0..protocol.response_size]) catch |err| {
        return switch (err) {
            error.BadVersion => .bad_version,
            error.Truncated => .bad_buffer,
            error.BadValue => .bad_value,
        };
    };

    out.* = .{
        .tick = response.tick,
        .total_xp = response.total_xp,
        .hp = response.hp,
        .damage = response.damage,
        .xp = response.xp,
        .level = response.level,
        .momentum = @intFromEnum(response.momentum),
        .crowd = @intFromEnum(response.crowd),
        .kit = @intFromEnum(response.kit),
        .reward = @intFromEnum(response.reward),
        .salvage = response.salvage,
        .owned = response.owned,
        .weapon = @intFromEnum(response.equipped.weapon),
        .armor = @intFromEnum(response.equipped.armor),
        .utility = @intFromEnum(response.equipped.utility),
        .item = response.item,
        .discovered = @intFromBool(response.discovered),
        .capacity = response.capacity,
    };
    return .ok;
}

const testing = std.testing;

test "the coordinate dies in the quantizer, and nowhere else" {
    // The only door in the coordinate wall (B6). A latitude goes in; a room comes out; the float
    // does not survive the return.
    const cell = outbreak_quantize(51.5007, -0.1246, spatial.default_precision);
    try testing.expect(cell != 0);

    // And it really is a room -- the same room, for two readings a few metres apart.
    const nearby = outbreak_quantize(51.50072, -0.12462, spatial.default_precision);
    try testing.expectEqual(cell, nearby);
}

test "an unusable fix is not an error, it is a phone that does not know where it is" {
    // E4: define the error out of existence. A GPS receiver in a tunnel is an ordinary
    // condition, not a failure to propagate.
    try testing.expectEqual(@as(u64, 0), outbreak_quantize(std.math.nan(f64), 0, 39));
    try testing.expectEqual(@as(u64, 0), outbreak_quantize(0, std.math.inf(f64), 39));
    try testing.expectEqual(@as(u64, 0), outbreak_quantize(91.0, 0, 39)); // off the planet
    try testing.expectEqual(@as(u64, 0), outbreak_quantize(0, 0, 0)); // no precision
    try testing.expectEqual(@as(u64, 0), outbreak_quantize(0, 0, 200)); // absurd precision
}

test "a hostile server cannot crash the phone" {
    // A panic across an FFI boundary is undefined behaviour -- Zig unwinding into the JVM is not
    // a crash we can debug, it is a corrupted runtime. So every hostile byte gets a status code.
    var tell: Tell = undefined;

    // Wrong length.
    var short: [4]u8 = @splat(0);
    try testing.expectEqual(Status.bad_buffer, outbreak_decode_tell(&short, 4, &tell));

    // Right length, garbage inside -- including enum bytes that do not name anything.
    var bytes: [protocol.response_size]u8 = @splat(0xFF);
    const status = outbreak_decode_tell(&bytes, protocol.response_size, &tell);
    try testing.expect(status == .bad_value or status == .bad_version);
}

test "a report carries bounded equipment intent, never an outcome" {
    var out: [protocol.report_size]u8 = undefined;

    const cell = outbreak_quantize(51.5, -0.12, spatial.default_precision);
    try testing.expectEqual(Status.ok, outbreak_encode_report(0xABCD, cell, 1, 2, 6, 13, &out, protocol.report_size));

    // Nowhere is not somewhere: a phone with no fix does not claim a room.
    try testing.expectEqual(
        Status.bad_coordinate,
        outbreak_encode_report(0xABCD, 0, 0, 0, 6, 12, &out, protocol.report_size),
    );

    // And a caller who lies about the buffer size gets an error, not a smashed stack.
    try testing.expectEqual(Status.bad_buffer, outbreak_encode_report(0xABCD, cell, 0, 0, 6, 12, &out, 4));
    try testing.expectEqual(Status.bad_value, outbreak_encode_report(0xABCD, cell, 9, 0, 6, 12, &out, protocol.report_size));
    try testing.expectEqual(Status.bad_value, outbreak_encode_report(0xABCD, cell, 0, 6, 6, 12, &out, protocol.report_size));
}

test "an over-long contact point is refused, not written past the end of the frame" {
    // A caller handing us a 400-byte email must get an error code. This is the bounds check that
    // exists because the alternative is a stack smash in a process we do not control.
    var out: [protocol.hello_size]u8 = undefined;

    const long: [200:0]u8 = @splat('a');
    try testing.expectEqual(
        Status.bad_buffer,
        outbreak_encode_hello(&long, "password", 0, true, &out, protocol.hello_size),
    );

    // A reasonable one works.
    try testing.expectEqual(
        Status.ok,
        outbreak_encode_hello("a@example.com", "a good password", 0, true, &out, protocol.hello_size),
    );

    // A faction that does not exist is refused rather than cast.
    try testing.expectEqual(
        Status.bad_value,
        outbreak_encode_hello("a@example.com", "a good password", 7, true, &out, protocol.hello_size),
    );
}

test "the round trip: quantize, encode, decode" {
    // What the phone actually does, end to end, in the order it does it.
    const cell = outbreak_quantize(40.7128, -74.0060, spatial.default_precision);
    try testing.expect(cell != 0);

    var report: [protocol.report_size]u8 = undefined;
    try testing.expectEqual(Status.ok, outbreak_encode_report(1234, cell, 2, 0, 6, 12, &report, protocol.report_size));

    // The server would reply with something like this.
    const wire = protocol.encodeResponse(.{
        .tick = 900,
        .total_xp = 4200,
        .hp = 62,
        .damage = 18,
        .xp = 10,
        .level = 7,
        .momentum = .zombies_winning,
        .crowd = .hundreds,
    });

    var tell: Tell = undefined;
    try testing.expectEqual(Status.ok, outbreak_decode_tell(&wire, protocol.response_size, &tell));

    try testing.expectEqual(@as(u16, 62), tell.hp);
    try testing.expectEqual(@as(u16, 7), tell.level);
    try testing.expectEqual(@as(u8, 4), tell.momentum); // zombies_winning
    try testing.expectEqual(@as(u8, 3), tell.crowd); // hundreds
}
