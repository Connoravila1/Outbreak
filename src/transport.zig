//! SHELL (B1, B3). The socket. Everything hostile enters here and nowhere else.
//!
//! ============================================================================
//! TLS TERMINATES IN FRONT OF THIS PROCESS, NOT INSIDE IT
//!
//! Zig 0.16's standard library ships a TLS **client** and no TLS **server**. That leaves three
//! options and only one of them is defensible:
//!
//!   1. Write our own TLS server. NO. "Do not implement your own crypto" is the one rule with
//!      no exceptions, and a hand-rolled TLS stack is the most catastrophic possible place to
//!      learn that lesson.
//!   2. Import a C TLS library. Possible, but it is an enormous attack surface INSIDE our
//!      binary, in a language without our safety checks, and F1's default answer to a
//!      dependency is no.
//!   3. TERMINATE TLS IN FRONT. A reverse proxy (Caddy, nginx) holds the certificate and speaks
//!      TLS to the world; this process binds to LOOPBACK ONLY and speaks plain TCP to the proxy.
//!
//! We take (3). It costs zero dependencies in our binary and hands TLS to software that has been
//! attacked continuously for twenty years.
//!
//! IT COSTS US NOTHING WE CARE ABOUT. Every reply is a constant 16 bytes of plaintext, so every
//! TLS record carrying one is the same length as every other. The size guarantee (I3) survives
//! the proxy exactly.
//!
//! THE HONEST PART: the proxy becomes a trusted component. It sees plaintext. It must be
//! configured, patched, and threat-modelled as part of this system -- not bolted on and
//! forgotten. `SECURITY.md` says so and names it.
//!
//! LOOPBACK ONLY. This process must never be reachable from the internet directly, because
//! nothing here does TLS. The bind address is not a configuration flag someone can widen by
//! accident: see `listen`.
//!
//! ============================================================================
//! CONSTANT-TIME SILENCE, ACHIEVED STRUCTURALLY (I3, 2.2)
//!
//! Quorum silence is only absolute if a quiet cell is indistinguishable from a live one THROUGH
//! TIMING. If a live cell's reply takes 40ms and a dead one takes 12ms, the latency has leaked
//! the count and the whole design is decoration.
//!
//! The usual way to get this wrong is to reply as soon as you have an answer, and then try very
//! hard to make computing the answer take the same time. That is a losing game.
//!
//! We do not play it. **THE REPLY IS SENT ON THE TICK BOUNDARY, NOT WHEN THE REQUEST ARRIVES.**
//! A report lands whenever it lands; the reply goes out when the tick fires. The delay between
//! them is "time until the next tick" -- which depends on the clock and on NOTHING ELSE. Not on
//! quorum. Not on whether a fight happened. Not on how many people are in the room.
//!
//! The property is a consequence of the architecture rather than a thing we are carefully not
//! breaking, and that is the only kind of security property worth having.

const std = @import("std");
const accounts_mod = @import("accounts.zig");
const credential = @import("credential.zig");
const entropy = @import("entropy.zig");
const protocol = @import("protocol.zig");
const session_mod = @import("session.zig");
const spatial = @import("spatial.zig");
const world = @import("world.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const net = std.Io.net;

/// RESOURCE LIMITS. Every one of these exists to bound what a hostile client can cost us.
pub const Limits = struct {
    /// The connection table is preallocated. A flood cannot grow it.
    max_connections: usize = 20_000,

    /// A connection that says nothing for this many ticks is dropped.
    ///
    /// Slow-loris defence: an attacker opening thousands of sockets and dribbling nothing costs
    /// us a socket each until we hang up. There is no reason for a real client to hold a
    /// connection open and stay silent -- it reports every tick or it is not playing.
    idle_ticks: u64 = 10,

    /// Argon2 is deliberately expensive, so a flood of registration attempts is a
    /// CPU-exhaustion attack aimed at our own server. The account layer rate-limits per source;
    /// this bounds how many can even be in flight.
    max_handshakes_in_flight: usize = 64,
};

/// One connected phone.
///
/// A7.2: cold struct, size guard waived -- one per connection, not walked in a hot loop.
const Connection = struct {
    stream: net.Stream,
    session: protocol.SessionId,
    /// The tick we last heard from them. Silence past `idle_ticks` and they are gone.
    last_heard: u64,
};

pub const Server = struct {
    /// Guards everything below it. The tick and every connection contend here.
    ///
    /// std.Io.Mutex in 0.16 -- it takes an Io and is cancelable, which is the stdlib saying the
    /// same thing the ruleset says: blocking is I/O, and I/O belongs to the shell.
    mutex: Io.Mutex = .init,

    sessions: session_mod.Server,
    accounts: accounts_mod.Accounts,
    connections: std.ArrayList(Connection),

    /// The server's pepper: what makes a stolen contact table unmatched-able (credential.zig).
    /// It comes from the OS and never leaves this process.
    pepper: [32]u8,

    limits: Limits,
    running: std.atomic.Value(bool),
};

pub fn init(io: Io, seed: u64, precision: u6, limits: Limits) !Server {
    var pepper: [32]u8 = undefined;
    try io.randomSecure(&pepper);

    return .{
        .sessions = session_mod.init(seed, precision),
        .accounts = .empty,
        .connections = .empty,
        .pepper = pepper,
        .limits = limits,
        .running = .init(true),
    };
}

pub fn deinit(server: *Server, gpa: Allocator) void {
    session_mod.deinit(&server.sessions, gpa);
    accounts_mod.deinit(&server.accounts, gpa);
    server.connections.deinit(gpa);

    // The pepper is a secret. Wipe it rather than leave it in a core dump.
    std.crypto.secureZero(u8, &server.pepper);
}

/// SHELL. Bind. LOOPBACK ONLY, and not negotiably.
///
/// This process does no TLS. Exposing it directly would put every session credential on the
/// wire in the clear. The address is hard-coded rather than configurable precisely so that
/// nobody can widen it with a config change at 2am -- if you want it public, you put a TLS
/// proxy in front of it, which is the whole point.
pub fn listen(io: Io, port: u16) !net.Server {
    const address = try net.IpAddress.parse("127.0.0.1", port);
    return address.listen(io, .{ .reuse_address = true });
}

/// SHELL. Serve one connection, start to finish.
///
/// Everything hostile a phone can do arrives in this function. It is deliberately short.
pub fn serve(server: *Server, io: Io, gpa: Allocator, stream: net.Stream) void {
    defer stream.close(io);

    // ---- the handshake. Exactly one fixed-size frame, or you are not a client.
    var hello_bytes: [protocol.hello_size]u8 = undefined;
    var read_buffer: [512]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);

    reader.interface.readSliceAll(&hello_bytes) catch return;

    const hello = protocol.decodeHello(&hello_bytes) catch return; // garbage is not a client

    const auth = authenticate(server, io, gpa, hello) catch return;
    const session = auth.session;

    // Wipe the credentials out of our stack the instant we are done with them. They do not
    // belong in a core dump, a crash report, or a page of swap.
    std.crypto.secureZero(u8, &hello_bytes);

    var welcome_bytes = protocol.encodeWelcome(.{
        .session = session,
        .precision = server.sessions.precision,
        .tick_seconds = 30,
        // AUTHORITATIVE. On a login this is the account's stored side, not the one the client just
        // sent -- the vow is the server's to keep, not the phone's (H1). On a register it is the
        // side just sworn. Either way, the client's local cache reconciles to this.
        .faction = auth.faction,
    });

    var write_buffer: [64]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    writer.interface.writeAll(&welcome_bytes) catch return;
    writer.interface.flush() catch return;

    // ---- registered. Now it is just reports, forever.
    {
        server.mutex.lock(io) catch return;
        defer server.mutex.unlock(io);

        if (server.connections.items.len >= server.limits.max_connections) return; // full
        server.connections.append(gpa, .{
            .stream = stream,
            .session = session,
            .last_heard = server.sessions.tick_index,
        }) catch return;
    }
    defer forget(server, io, session);

    var report_bytes: [protocol.report_size]u8 = undefined;
    while (server.running.load(.acquire)) {
        // A fixed-size read. There is no length field to lie about, so there is no
        // "this array has four billion elements" to defend against -- the entire class is absent
        // from this protocol by construction.
        reader.interface.readSliceAll(&report_bytes) catch return;

        const report = protocol.decodeReport(&report_bytes) catch continue; // a bad frame is not fatal

        server.mutex.lock(io) catch return;
        defer server.mutex.unlock(io);

        // A phone talking nonsense is an absent player, not an error (E4, E5). The report is
        // dropped at this boundary and never reaches the core.
        _ = session_mod.ingest(&server.sessions, report);

        for (server.connections.items) |*connection| {
            if (connection.session == session) connection.last_heard = server.sessions.tick_index;
        }
    }
}

/// What a completed handshake yields: the session token, and the authoritative side the server
/// holds for this account (which the welcome carries back to the client).
const Authenticated = struct { session: protocol.SessionId, faction: world.Faction };

/// SHELL. Register or log in. The only place a password exists in this process.
fn authenticate(server: *Server, io: Io, gpa: Allocator, hello: protocol.Hello) !Authenticated {
    const contact = protocol.unpad(&hello.contact);
    const password = protocol.unpad(&hello.password);

    if (contact.len == 0 or password.len < 8) return error.BadCredentials;

    // The address is hashed with the pepper and the address itself is discarded here, in this
    // expression. We keep a fingerprint, never a directory of who is who (credential.zig).
    const fingerprint = credential.hashContact(&server.pepper, contact);

    try server.mutex.lock(io);
    defer server.mutex.unlock(io);

    const now = server.sessions.tick_index;

    const account = switch (hello.intent) {
        .register => blk: {
            const salt = try credential.newSalt(io);
            const verifier = try credential.derive(io, gpa, password, salt);

            // ONE CONTACT POINT, ONE ACCOUNT, and rate-limited (H5). The farm's front door.
            //
            // The source key is the contact fingerprint for now. When the proxy is in front, it
            // supplies the client address, and THAT becomes the source -- which is the right
            // key, because a farm has many addresses and one machine.
            const source = std.mem.readInt(u64, fingerprint[0..8], .little);
            break :blk try accounts_mod.register(
                &server.accounts,
                gpa,
                fingerprint,
                salt,
                verifier,
                hello.faction,
                source,
                now,
                .default,
            );
        },

        .login => blk: {
            const account = try accounts_mod.beginLogin(&server.accounts, gpa, fingerprint, now, .default);

            // Constant-time. Never a compare that returns early on the first wrong byte.
            if (!credential.verify(io, gpa, password, account.salt, account.verifier)) {
                return error.BadCredentials;
            }

            accounts_mod.loginSucceeded(&server.accounts, fingerprint);
            break :blk account;
        },
    };

    // Unguessable, from the OS, never from the tick's mixer (B3). See POSTMORTEM_2026-07-13.
    const session = try entropy.newSession(io);
    _ = try session_mod.joinAuthenticated(&server.sessions, gpa, account.player, account.faction, session);
    return .{ .session = session, .faction = account.faction };
}

fn forget(server: *Server, io: Io, session: protocol.SessionId) void {
    server.mutex.lock(io) catch return;
    defer server.mutex.unlock(io);

    var i: usize = 0;
    while (i < server.connections.items.len) {
        if (server.connections.items[i].session == session) {
            _ = server.connections.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

/// SHELL. THE TICK. Resolve the world, and reply to every connection.
///
/// THIS IS WHERE CONSTANT-TIME SILENCE LIVES, and it lives here for free.
///
/// Every connection is written to, every tick, with exactly sixteen bytes, in the same loop, in
/// the same order, doing the same work -- whether that player is in a war, in a quiet room, or
/// alone in a field. There is no branch on what happened to them, so there is no timing to
/// measure and no size to compare.
///
/// The reply is not a response to a request. It is a heartbeat that happens to carry news.
pub fn tick(server: *Server, io: Io, gpa: Allocator, scratch: Allocator) !void {
    try server.mutex.lock(io);
    defer server.mutex.unlock(io);

    const replies = try session_mod.tick(&server.sessions, gpa, scratch);
    defer gpa.free(replies);

    const now = server.sessions.tick_index;

    // Drop the silent. A connection that has said nothing for `idle_ticks` is a slow-loris, a
    // dead phone, or a socket somebody forgot -- and in every case it is costing us a file
    // descriptor to hold open.
    var i: usize = 0;
    while (i < server.connections.items.len) {
        const connection = server.connections.items[i];
        if (now -| connection.last_heard > server.limits.idle_ticks) {
            connection.stream.close(io);
            _ = server.connections.swapRemove(i);
        } else {
            i += 1;
        }
    }

    // And now: sixteen bytes to everyone. The same sixteen bytes' worth of work for everyone.
    for (server.connections.items) |connection| {
        const response = find(replies, connection.session) orelse protocol.quiet(now, 0, .{ .xp = 0, .level = 1 });
        const bytes = protocol.encodeResponse(response);

        var write_buffer: [64]u8 = undefined;
        var writer = connection.stream.writer(io, &write_buffer);

        // A write failure is a gone phone, not a problem. The next tick will drop them (E2).
        writer.interface.writeAll(&bytes) catch continue;
        writer.interface.flush() catch continue;
    }
}

fn find(replies: []const session_mod.Reply, session: protocol.SessionId) ?protocol.Response {
    for (replies) |reply| {
        if (reply.session == session) return reply.response;
    }
    return null;
}

const testing = std.testing;

test "a login is bound to the account's sworn side, not the one it sends" {
    // THE VOW IS THE SERVER'S TO KEEP (H1). A returning player -- or a modified client -- can put any
    // faction in a login Hello. The server ignores it and hands back the side the account registered
    // with, and THAT is what the welcome carries to the phone (the client reconciles its local cache
    // to it). Break this -- reach for hello.faction on the login path -- and a permanent choice
    // becomes changeable from the client, which is the one thing it must never be.
    //
    // Tested through `authenticate` directly, not a socket: this is server logic, and it keeps the
    // argon2 work single-threaded and off the flake-prone socket path.
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try init(io, 0x5EED, spatial.default_precision, .{});
    defer deinit(&server, gpa);

    var reg: protocol.Hello = .{ .contact = @splat(0), .password = @splat(0), .faction = .human, .intent = .register };
    @memcpy(reg.contact[0.."op@example.com".len], "op@example.com");
    @memcpy(reg.password[0.."a good long password".len], "a good long password");

    // Sworn to the humans, once.
    const registered = try authenticate(&server, io, gpa, reg);
    try testing.expectEqual(world.Faction.human, registered.faction);

    // The same account returns, its Hello claiming the other side. The claim is ignored.
    var log = reg;
    log.faction = .zombie;
    log.intent = .login;
    const returned = try authenticate(&server, io, gpa, log);
    try testing.expectEqual(world.Faction.human, returned.faction);
}
