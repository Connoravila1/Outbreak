//! SHELL (B1, B3). The client socket. It sends the room and receives the tell.
//!
//! ============================================================================
//! WHAT CROSSES THIS WIRE, AND WHAT DOES NOT
//!
//! Up:   a session token, a `u64` room id, and bounded kit intent. Not a coordinate -- the coordinate
//!       died in `location.zig` long before this file sees a thing (H1, B6). The client is
//!       authoritative over no outcome; the server owns kit stats and whether a change is legal.
//!
//! Down: a fixed-size response -- your own hit points, the crowd BAND, the momentum. Never a count,
//!       never a bearing, never a who. The response was built to be safe on the server; this file
//!       only reads it.
//!
//! ============================================================================
//! INSTALL IDENTITY
//!
//! There is no identifying login surface in the MVP. Each installation instead creates 64 random
//! bytes in Android's private app directory: half becomes an opaque account key, half a password.
//! Both cross only inside TLS and the server stores neither plaintext. Separate phones therefore
//! become separate players without collecting an email, phone number, hardware id, or name.

const std = @import("std");
const loadout = @import("loadout.zig");
const protocol = @import("protocol.zig");
const location = @import("location.zig");
const world = @import("world.zig");

const Io = std.Io;
const net = std.Io.net;
const Faction = world.Faction;

// ============================================================================ what the UI reads

/// The latest response, waiting to be folded into the interface by the render thread.
///
/// Written by the client thread, taken by the render thread. A plain value behind a lightweight
/// spinlock -- a `protocol.Response` is 24 bytes and does not tear on any target we ship, but the
/// optional needs to be published and cleared atomically, and a mutex here would drag `Io` into a
/// file that does not otherwise need it on this path.
var have_response: std.atomic.Value(bool) = .init(false);
var latest: protocol.Response = undefined;

var connected: std.atomic.Value(bool) = .init(false);
var should_run: std.atomic.Value(bool) = .init(false);

/// THE SERVER'S TRUTH ABOUT YOUR OWN SIDE. -1 until a welcome arrives; 0/1 = human/zombie. The
/// phone colours its terminal from a LOCAL byte at launch (O5, android.zig) so it need not wait for
/// the wire -- but the server is authoritative (a login uses the account's stored faction, not the
/// one the client sent), so the render thread reconciles the local cache against this. It is the
/// player's OWN side and nothing about anyone else (I1-I3).
var server_faction: std.atomic.Value(i32) = .init(-1);
var selected_kit: std.atomic.Value(u8) = .init(@intFromEnum(loadout.Kit.field));
var selected_weapon: std.atomic.Value(u8) = .init(@intFromEnum(loadout.ItemId.salvaged_pipe));
var selected_armor: std.atomic.Value(u8) = .init(@intFromEnum(loadout.ItemId.work_jacket));
var selected_utility: std.atomic.Value(u8) = .init(@intFromEnum(loadout.ItemId.field_radio));

pub const identity_size = 64;
var install_identity: [identity_size]u8 = undefined;
var identity_ready: std.atomic.Value(bool) = .init(false);

/// Set exactly once at process start, before the client thread exists.
pub fn setInstallIdentity(identity: [identity_size]u8) void {
    install_identity = identity;
    identity_ready.store(true, .release);
}

/// The side the server says you are, or null if no welcome has arrived this run. The render thread
/// folds this into the UI and persists any correction (android.zig).
pub fn authoritativeFaction() ?Faction {
    return switch (server_faction.load(.acquire)) {
        0 => .human,
        1 => .zombie,
        else => null,
    };
}

/// The UI may choose a kit; the server confirms or rejects it on the next heartbeat.
pub fn selectKit(kit: loadout.Kit) void {
    selected_kit.store(@intFromEnum(kit), .release);
}

pub fn selectedKit() loadout.Kit {
    return switch (selected_kit.load(.acquire)) {
        1 => .raider,
        2 => .bulwark,
        else => .field,
    };
}

pub fn selectedEquipment() loadout.Loadout {
    return .{
        .weapon = loadout.itemFromByte(selected_weapon.load(.acquire)) orelse .salvaged_pipe,
        .armor = loadout.itemFromByte(selected_armor.load(.acquire)) orelse .work_jacket,
        .utility = loadout.itemFromByte(selected_utility.load(.acquire)) orelse .field_radio,
    };
}

pub fn equipItem(item: loadout.ItemId) void {
    switch (loadout.definition(item).slot) {
        .weapon => selected_weapon.store(@intFromEnum(item), .release),
        .armor => selected_armor.store(@intFromEnum(item), .release),
        .utility => selected_utility.store(@intFromEnum(item), .release),
        .evidence => {},
    }
}

fn selectEquipment(equipped: loadout.Loadout) void {
    selected_weapon.store(@intFromEnum(equipped.weapon), .release);
    selected_armor.store(@intFromEnum(equipped.armor), .release);
    selected_utility.store(@intFromEnum(equipped.utility), .release);
}

/// Take the latest response, if there is one. Returns null if nothing new has arrived.
///
/// The render thread calls this each frame and folds a result into the UI (`ui.told`). Clearing on
/// take means a response is shown once and not re-shown for thirty seconds.
pub fn takeResponse() ?protocol.Response {
    if (!have_response.swap(false, .acq_rel)) return null;
    return latest;
}

pub fn isConnected() bool {
    return connected.load(.acquire);
}

// ============================================================================ the loop

/// The server. Loopback, because the phone reaches it through `adb reverse tcp:7777 tcp:7777` in
/// development and through a TLS proxy in production -- both terminate at the phone's own localhost.
/// When the real endpoint exists, this is the one line that changes.
const host = "127.0.0.1";
const port: u16 = 7777;

/// Ask the client to stop. It closes the socket and the thread returns.
pub fn stop() void {
    should_run.store(false, .release);
}

/// SHELL. Connect, hand over, and loop -- room up, tell down -- until told to stop. Blocking; run
/// on a thread of its own.
///
/// Failure to connect is not an error. It is a phone that cannot reach the server right now, which
/// for an ambient game is ordinary: the world resolves whether or not any one phone is listening,
/// and the next attempt reconnects.
pub fn run(gpa: std.mem.Allocator, faction: Faction, radio: *location.Radio) void {
    if (!identity_ready.load(.acquire)) return;
    should_run.store(true, .release);

    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    while (should_run.load(.acquire)) {
        session(io, faction, radio) catch {};
        connected.store(false, .release);

        // A dropped connection is not a crash. Wait a moment and try again. Backoff is one line;
        // the game does not need a storm of reconnects.
        io.sleep(Io.Duration.fromSeconds(3), .awake) catch return;
    }
}

/// One connection, from handshake to disconnect.
///
/// Each TCP connection gets exactly ONE Hello, so login-or-register is up to two opens: try to
/// register the dev account; if the server refuses (it already exists), reopen and log in. The
/// connection that succeeds is the one we keep and report on.
fn session(io: Io, faction: Faction, radio: *location.Radio) !void {
    var address = try net.IpAddress.parse(host, port);

    var stream = try address.connect(io, .{ .mode = .stream });
    var read_buffer: [128]u8 = undefined;
    var write_buffer: [64]u8 = undefined;

    var my: protocol.SessionId = undefined;
    if (try welcomeFrom(io, &stream, faction, .register, &read_buffer, &write_buffer)) |s| {
        my = s;
    } else {
        // Register refused -- the dev account exists. Reopen and log in.
        stream.close(io);
        stream = try address.connect(io, .{ .mode = .stream });
        my = (try welcomeFrom(io, &stream, faction, .login, &read_buffer, &write_buffer)) orelse
            return error.AuthFailed;
    }
    defer stream.close(io);

    connected.store(true, .release);

    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);

    // THE COMBAT ALERT, COALESCED (M.8). One raise per fight, not one per tick: raise on the first
    // tick that carries damage, clear after the fight has been quiet for a couple of ticks. The band
    // is categorical (the crowd band), never a count. This is the whole of the coalescing the
    // notification needs -- the timing is the tick's, and the content is the server's safe tell.
    var alerting = false;
    var quiet_ticks: u32 = 0;

    var response_bytes: [protocol.response_size]u8 = undefined;
    while (should_run.load(.acquire)) {
        // ROOM UP. Whatever `location.zig` last quantized. Zero -- no fix yet -- is a room the
        // server treats as nowhere, which is correct: a phone that does not know where it is is not
        // in a room with anyone.
        const room = location.read().cell;
        const report = protocol.encodeReport(.{
            .session = my,
            .cell = @enumFromInt(room),
            .kit = selectedKit(),
            .equipped = selectedEquipment(),
        });
        try writer.interface.writeAll(&report);
        try writer.interface.flush();

        // TELL DOWN. Blocks until the server's next tick reply -- which paces this loop at the tick
        // rate for free, the thirty-second heartbeat the whole design is built on.
        try reader.interface.readSliceAll(&response_bytes);
        const response = protocol.decodeResponse(&response_bytes) catch continue;

        selectKit(response.kit);
        selectEquipment(response.equipped);
        latest = response;
        have_response.store(true, .release);

        if (response.damage > 0) {
            quiet_ticks = 0;
            if (!alerting) {
                location.combatAlert(radio, @as(i32, @intFromEnum(response.crowd)));
                alerting = true;
            }
        } else if (alerting) {
            quiet_ticks += 1;
            if (quiet_ticks >= 2) {
                location.combatAlert(radio, -1); // the fight is over -- take the alert down
                alerting = false;
            }
        }
    }
}

/// Send one Hello on a fresh stream and read the Welcome. Returns null if the server closed without
/// a welcome -- which is how it says no to a duplicate register or a bad login.
fn welcomeFrom(
    io: Io,
    stream: *net.Stream,
    faction: Faction,
    intent: protocol.Hello.Intent,
    read_buffer: []u8,
    write_buffer: []u8,
) !?protocol.SessionId {
    var writer = stream.writer(io, write_buffer);
    const hello = protocol.encodeHello(installHello(faction, intent));
    try writer.interface.writeAll(&hello);
    try writer.interface.flush();

    var reader = stream.reader(io, read_buffer);
    var welcome_bytes: [protocol.welcome_size]u8 = undefined;
    reader.interface.readSliceAll(&welcome_bytes) catch return null;

    const welcome = try protocol.decodeWelcome(&welcome_bytes);
    location.setPrecision(welcome.precision);

    // THE SERVER'S TRUTH, PUBLISHED. Whether this was a register (the side just sworn) or a login
    // (the account's stored side, whatever the client sent), the welcome carries the authoritative
    // faction. The render thread reconciles the local cache against it.
    server_faction.store(@intFromEnum(welcome.faction), .release);

    return welcome.session;
}

fn installHello(faction: Faction, intent: protocol.Hello.Intent) protocol.Hello {
    const contact = std.fmt.bytesToHex(install_identity[0..32].*, .lower);
    const password = std.fmt.bytesToHex(install_identity[32..64].*, .lower);
    return .{
        .contact = contact,
        .password = password,
        .faction = faction,
        .intent = intent,
    };
}

test "separate installations present separate opaque accounts" {
    const first: [identity_size]u8 = @splat(1);
    const second: [identity_size]u8 = @splat(2);
    setInstallIdentity(first);
    const a = installHello(.human, .register);
    setInstallIdentity(second);
    const b = installHello(.human, .register);
    try std.testing.expect(!std.mem.eql(u8, &a.contact, &b.contact));
    try std.testing.expect(!std.mem.eql(u8, &a.password, &b.password));
    try std.testing.expectEqual(@as(usize, 64), protocol.unpad(&a.contact).len);
    try std.testing.expectEqual(@as(usize, 64), protocol.unpad(&a.password).len);
}
