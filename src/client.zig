//! SHELL (B1, B3). The client socket. It sends the room and receives the tell.
//!
//! ============================================================================
//! WHAT CROSSES THIS WIRE, AND WHAT DOES NOT
//!
//! Up:   a session token and a `u64` room id. NOTHING ELSE. Not a coordinate -- the coordinate
//!       died in `location.zig` long before this file sees a thing (H1, B6). The client is
//!       authoritative over nothing; the only lie a modified phone can tell is a false room.
//!
//! Down: a fixed-size response -- your own hit points, the crowd BAND, the momentum. Never a count,
//!       never a bearing, never a who. The response was built to be safe on the server; this file
//!       only reads it.
//!
//! ============================================================================
//! DEV CREDENTIALS, AND WHY THEY ARE HERE
//!
//! There is no text entry yet (O5 is unsolved: register in a browser, sign in with a device code).
//! So this file logs in with a fixed development credential, and if that account does not exist
//! yet, registers it. It is scaffolding, it is obviously scaffolding, and O5 replaces it wholesale.
//! It exists so the socket can be proven end to end before the registration flow is designed.

const std = @import("std");
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
        });
        try writer.interface.writeAll(&report);
        try writer.interface.flush();

        // TELL DOWN. Blocks until the server's next tick reply -- which paces this loop at the tick
        // rate for free, the thirty-second heartbeat the whole design is built on.
        try reader.interface.readSliceAll(&response_bytes);
        const response = protocol.decodeResponse(&response_bytes) catch continue;

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
    const hello = protocol.encodeHello(devHello(faction, intent));
    try writer.interface.writeAll(&hello);
    try writer.interface.flush();

    var reader = stream.reader(io, read_buffer);
    var welcome_bytes: [protocol.welcome_size]u8 = undefined;
    reader.interface.readSliceAll(&welcome_bytes) catch return null;

    const welcome = try protocol.decodeWelcome(&welcome_bytes);
    location.setPrecision(welcome.precision);
    return welcome.session;
}

/// THE DEV CREDENTIAL. Replaced wholesale by O5. See the file header.
///
/// A fixed contact and password so the socket can be exercised without a registration UI. The
/// password clears the server's floor (>= 8). It is not a secret and is not pretending to be one.
fn devHello(faction: Faction, intent: protocol.Hello.Intent) protocol.Hello {
    var contact: [64]u8 = @splat(0);
    var password: [64]u8 = @splat(0);
    @memcpy(contact[0.."dev@outbreak.local".len], "dev@outbreak.local");
    @memcpy(password[0.."dev-password-0001".len], "dev-password-0001");
    return .{
        .contact = contact,
        .password = password,
        .faction = faction,
        .intent = intent,
    };
}
