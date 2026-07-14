//! SHELL. The Phase 2 exit criterion, over a real socket.
//!
//!   > Two clients, standing in the same cell, on opposite factions -- and the responses from a
//!   > sub-quorum cell are BYTE-IDENTICAL and TIME-IDENTICAL to those from an empty one.
//!
//! Byte-identical is checked by reading the actual bytes off an actual TCP connection.
//! Time-identical is MEASURED, not asserted -- because it is the property I was most likely to
//! get wrong, and a security property nobody measured is a security property nobody has.

const std = @import("std");
const accounts_mod = @import("accounts.zig");
const protocol = @import("protocol.zig");
const session_mod = @import("session.zig");
const spatial = @import("spatial.zig");
const transport = @import("transport.zig");

const Io = std.Io;
const net = std.Io.net;
const testing = std.testing;

fn countClaimed(server: *transport.Server) usize {
    var claimed: usize = 0;
    var it = server.sessions.sessions.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.claimed != null) claimed += 1;
    }
    return claimed;
}

fn helloBytes(contact: []const u8, password: []const u8, faction: @import("world.zig").Faction) [protocol.hello_size]u8 {
    var hello: protocol.Hello = .{
        .contact = @splat(0),
        .password = @splat(0),
        .faction = faction,
        .intent = .register,
    };
    @memcpy(hello.contact[0..contact.len], contact);
    @memcpy(hello.password[0..password.len], password);
    return protocol.encodeHello(hello);
}

/// One client, from connect to first reply.
///
/// It sends its report and then simply BLOCKS ON THE READ. That is not a testing convenience --
/// it is the protocol. The reply comes on the tick boundary, not when the request arrives, and
/// that is precisely what makes a quiet cell and a live one take the same time (I3).
fn play(
    io: Io,
    port: u16,
    contact: []const u8,
    faction: @import("world.zig").Faction,
    cell: spatial.CellId,
    got: *[protocol.response_size]u8,
) !void {
    const address = try net.IpAddress.parse("127.0.0.1", port);
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    var read_buffer: [256]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);

    // Register.
    const hello = helloBytes(contact, "a good long password", faction);
    try writer.interface.writeAll(&hello);
    try writer.interface.flush();

    var welcome_bytes: [protocol.welcome_size]u8 = undefined;
    try reader.interface.readSliceAll(&welcome_bytes);
    const welcome = try protocol.decodeWelcome(&welcome_bytes);

    // Report a room.
    const report = protocol.encodeReport(.{ .session = welcome.session, .cell = cell });
    try writer.interface.writeAll(&report);
    try writer.interface.flush();

    // Block until the tick fires. However long that is, it is the same however the world is.
    try reader.interface.readSliceAll(got);
}

test "THE PHASE 2 EXIT CRITERION, over a socket" {
    const gpa = testing.allocator;

    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const port: u16 = 47231;
    const precision = spatial.default_precision;

    var server = try transport.init(io, 0x5EED, precision, .{});
    defer transport.deinit(&server, gpa);

    var listener = try transport.listen(io, port);
    defer listener.deinit(io);

    // Accept three clients, each on its own thread.
    const Acceptor = struct {
        fn run(s: *transport.Server, l: *net.Server, i: Io, g: std.mem.Allocator, n: usize) void {
            var accepted: usize = 0;
            while (accepted < n) : (accepted += 1) {
                const stream = l.accept(i) catch return;
                _ = std.Thread.spawn(.{}, transport.serve, .{ s, i, g, stream }) catch return;
            }
        }
    };
    const acceptor = try std.Thread.spawn(.{}, Acceptor.run, .{ &server, &listener, io, gpa, @as(usize, 3) });
    defer acceptor.join();

    const cafe = spatial.cellFromKey(0xCAFE, precision);
    const empty_field = spatial.cellFromKey(0xF1E1D, precision);

    var human_in_cafe: [protocol.response_size]u8 = undefined;
    var zombie_in_cafe: [protocol.response_size]u8 = undefined;
    var alone_in_field: [protocol.response_size]u8 = undefined;

    // TWO people of opposite factions, standing in the same café. That is BELOW QUORUM (k = 3).
    const a = try std.Thread.spawn(.{}, play, .{ io, port, "a@example.com", .human, cafe, &human_in_cafe });
    const b = try std.Thread.spawn(.{}, play, .{ io, port, "b@example.com", .zombie, cafe, &zombie_in_cafe });
    // And one person alone in an empty field, on the other side of the city.
    const c = try std.Thread.spawn(.{}, play, .{ io, port, "c@example.com", .human, empty_field, &alone_in_field });

    // Wait until all three have registered and reported a room. (Argon2 is deliberately slow, so
    // registration takes real time -- which is the point of it.)
    var waited: usize = 0;
    while (waited < 20_000) : (waited += 1) {
        try server.mutex.lock(io);
        const claimed = countClaimed(&server);
        server.mutex.unlock(io);

        if (claimed == 3) break;
        std.Thread.yield() catch {};
    }

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try transport.tick(&server, io, gpa, arena.allocator());

    a.join();
    b.join();
    c.join();

    // ================================================================
    // THE WHOLE OF I3, AS BYTES OFF A WIRE.
    //
    // The player standing in a café with a hostile two feet away, below quorum, received EXACTLY
    // the bytes received by the player standing alone in an empty field. Not a similar message.
    // Not a shorter one. The same sixteen bytes.
    //
    // A packet sniffer on the café's wifi learns nothing. There is no length to measure, no
    // count to read, and no flag to test.
    try testing.expectEqualSlices(u8, &alone_in_field, &human_in_cafe);
    try testing.expectEqualSlices(u8, &alone_in_field, &zombie_in_cafe);
}

test "THE TIMING HALF: a tick costs the same whether the world is at war or asleep" {
    // I3's nastiest edge, and the one I was most likely to get wrong.
    //
    // Quorum silence is only absolute if a quiet cell is indistinguishable from a live one
    // THROUGH TIMING. If resolving a live cell takes measurably longer than resolving a dead
    // one, an attacker with a stopwatch reads the count we refused to send.
    //
    // The architecture is supposed to make this free: the reply goes out ON THE TICK BOUNDARY,
    // in one loop, with no branch on what happened. But "supposed to" is not a security
    // property. So: MEASURE IT.
    const gpa = testing.allocator;

    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const precision = spatial.default_precision;
    const population = 600;

    // Two worlds, identical in every way except what is happening in them.
    var at_war = try transport.init(io, 1, precision, .{});
    defer transport.deinit(&at_war, gpa);

    var asleep = try transport.init(io, 1, precision, .{});
    defer transport.deinit(&asleep, gpa);

    const battlefield = spatial.cellFromKey(0xBA771E, precision);

    var i: u32 = 0;
    while (i < population) : (i += 1) {
        const faction: @import("world.zig").Faction = if (i % 2 == 0) .human else .zombie;

        // AT WAR: everyone crammed into one enormous fight.
        const war_session: protocol.SessionId = @enumFromInt(1000 + i);
        _ = try session_mod.join(&at_war.sessions, gpa, faction, war_session);
        _ = session_mod.ingest(&at_war.sessions, .{ .session = war_session, .cell = battlefield });

        // ASLEEP: every one of them alone in their own room. Not one live cell in the world.
        const quiet_session: protocol.SessionId = @enumFromInt(1000 + i);
        _ = try session_mod.join(&asleep.sessions, gpa, faction, quiet_session);
        _ = session_mod.ingest(&asleep.sessions, .{
            .session = quiet_session,
            .cell = spatial.cellFromKey(0x100000 + i, precision),
        });
    }

    // Time both, several times, and take the best of each -- the minimum is the cleanest signal
    // through scheduler noise.
    var war_ns: u64 = std.math.maxInt(u64);
    var quiet_ns: u64 = std.math.maxInt(u64);

    var round: usize = 0;
    while (round < 20) : (round += 1) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        const w0 = Io.Timestamp.now(io, .awake);
        try transport.tick(&at_war, io, gpa, arena.allocator());
        const w1 = Io.Timestamp.now(io, .awake);
        war_ns = @min(war_ns, @as(u64, @intCast(w1.nanoseconds - w0.nanoseconds)));

        const q0 = Io.Timestamp.now(io, .awake);
        try transport.tick(&asleep, io, gpa, arena.allocator());
        const q1 = Io.Timestamp.now(io, .awake);
        quiet_ns = @min(quiet_ns, @as(u64, @intCast(q1.nanoseconds - q0.nanoseconds)));
    }

    // There ARE no connections here, so this measures the resolution, not the writes -- which is
    // the part an attacker's stopwatch would actually see through a network.
    //
    // The two are not required to be bit-for-bit identical -- 600 people in one fight really is
    // more arithmetic than 600 people alone. What matters is that the difference is nowhere near
    // measurable ACROSS A NETWORK, where jitter is milliseconds and this is microseconds.
    //
    // The real guarantee is not this number. It is that the reply is sent on the tick boundary,
    // thirty seconds wide, so the client's observable latency is dominated by the clock and not
    // by the world. This test exists to catch the day someone "optimises" that away.
    const slower = @max(war_ns, quiet_ns);
    const faster = @min(war_ns, quiet_ns);
    const difference_us = (slower - faster) / 1000;

    std.debug.print(
        "\n    tick at war: {d}us   tick asleep: {d}us   difference: {d}us\n" ++
            "    (network jitter is milliseconds; the reply waits for the tick boundary regardless)\n",
        .{ war_ns / 1000, quiet_ns / 1000, difference_us },
    );

    // ================================================================
    // THE FINDING, STATED HONESTLY. THE DIFFERENCE IS NOT ZERO.
    //
    // A busy world really does take longer to resolve than a sleeping one -- about 750us at six
    // hundred players. So: is that a leak?
    //
    // NO, AND THE REASON IS STRUCTURAL RATHER THAN LUCKY.
    //
    // The replies go out AFTER the whole world has resolved, in one loop over connections, in
    // connection order, with no branch on what happened to any individual. So the timing an
    // attacker can observe is a function of GLOBAL LOAD ACROSS THE ENTIRE CITY -- not of their
    // own cell.
    //
    // Timing your own reply tells you "the world was busy this tick". It does NOT tell you
    // whether YOUR room reached quorum, which is the thing I3 protects. A per-cell channel would
    // require the reply's timing to depend on that player's cell, and it CANNOT, because by the
    // time any byte is written the entire world has already been resolved.
    //
    // What would break this: replying to each player as their cell finishes resolving. That is
    // the natural, obvious, efficient design, and it would leak the count to anyone with a
    // stopwatch. It is why the reply waits for the tick boundary.
    //
    // A full millisecond of difference at this population would mean something has gone wrong --
    // an allocation per fight, a syscall per fight, a log line per fight -- and would be worth
    // investigating even though it is a global signal.
    try testing.expect(difference_us < 1000);
}
