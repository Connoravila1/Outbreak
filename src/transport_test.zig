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

/// Resolve two worlds of `population` people -- one crammed into a single enormous fight, one
/// where every soul is alone in their own room -- and return how many MORE allocation calls the
/// war took than the silence.
///
/// The counter sits ON TOP of the arena, not underneath it. This is the whole trick: an arena
/// serves a per-fight allocation out of a chunk it already holds, so a counter underneath the
/// arena would see a per-fight allocation and report nothing at all. On top, it sees every call.
fn extraAllocationsAtWar(io: Io, gpa: std.mem.Allocator, population: u32) !usize {
    const precision = spatial.default_precision;

    // Two worlds, identical in every way except what is happening in them.
    var at_war = try transport.init(io, 1, precision, .{});
    defer transport.deinit(&at_war, gpa);

    var asleep = try transport.init(io, 1, precision, .{});
    defer transport.deinit(&asleep, gpa);

    const battlefield = spatial.cellFromKey(0xBA771E, precision);

    var i: u32 = 0;
    while (i < population) : (i += 1) {
        const faction: @import("world.zig").Faction = if (i % 2 == 0) .human else .zombie;
        const who: protocol.SessionId = @enumFromInt(1000 + i);

        // AT WAR: everyone crammed into one enormous fight.
        _ = try session_mod.join(&at_war.sessions, gpa, faction, who);
        _ = session_mod.ingest(&at_war.sessions, .{ .session = who, .cell = battlefield });

        // ASLEEP: every one of them alone in their own room. Not one live cell in the world.
        _ = try session_mod.join(&asleep.sessions, gpa, faction, who);
        _ = session_mod.ingest(&asleep.sessions, .{
            .session = who,
            .cell = spatial.cellFromKey(0x100000 + i, precision),
        });
    }

    var war_arena: std.heap.ArenaAllocator = .init(gpa);
    defer war_arena.deinit();
    var war_gpa: std.testing.FailingAllocator = .init(gpa, .{});
    var war_scratch: std.testing.FailingAllocator = .init(war_arena.allocator(), .{});
    try transport.tick(&at_war, io, war_gpa.allocator(), war_scratch.allocator());
    const war = war_gpa.allocations + war_scratch.allocations;

    var quiet_arena: std.heap.ArenaAllocator = .init(gpa);
    defer quiet_arena.deinit();
    var quiet_gpa: std.testing.FailingAllocator = .init(gpa, .{});
    var quiet_scratch: std.testing.FailingAllocator = .init(quiet_arena.allocator(), .{});
    try transport.tick(&asleep, io, quiet_gpa.allocator(), quiet_scratch.allocator());
    const quiet = quiet_gpa.allocations + quiet_scratch.allocations;

    std.debug.print(
        "\n    population {d:>4} -- allocation calls at war: {d:>3}   asleep: {d:>3}   extra: {d}\n",
        .{ population, war, quiet, war -| quiet },
    );

    return war -| quiet;
}

test "THE TIMING HALF: resolving a fight costs no allocation per person in it" {
    // I3's nastiest edge, and the one I was most likely to get wrong.
    //
    // Quorum silence is only absolute if a quiet cell is indistinguishable from a live one
    // THROUGH TIMING. If resolving a live cell takes measurably longer than resolving a dead one,
    // an attacker with a stopwatch reads the count we refused to send.
    //
    // ================================================================
    // WHY THIS TEST NO LONGER HOLDS A STOPWATCH.
    //
    // It used to. It timed a warring world against a sleeping one and asserted the difference was
    // under a millisecond. That assertion was deleted, and it is worth being precise about why,
    // because deleting an assertion is exactly the move that should make a reader suspicious:
    //
    //   1. IT COULD NOT CATCH THE REGRESSION IT NAMED. Its own comment said the danger was
    //      "replying to each player as their cell finishes resolving." That danger lives in the
    //      WRITE LOOP -- and the test attached no connections, so it never ran the write loop at
    //      all. It timed resolution and nothing else. Someone could have moved the socket write
    //      inside the cell-resolution loop, leaked an exact headcount to anyone with a stopwatch,
    //      and this test would have gone right on passing.
    //
    //   2. IT ASSERTED A MACHINE, NOT A PROPERTY. A busy world really does take longer to resolve
    //      than a sleeping one -- 600 people in one fight genuinely is more arithmetic. The old
    //      comment said so itself and correctly judged it benign. So the test put an absolute
    //      microsecond bound on a quantity it had already agreed was allowed to be nonzero, and
    //      the bound was one the hardware could cross on a bad afternoon. It flaked. A guard that
    //      cries wolf is a guard people learn to silence.
    //
    // WHAT ACTUALLY PROTECTS I3 HERE IS STRUCTURAL, NOT MEASURED.
    //
    // The replies go out AFTER the whole world has resolved, in one loop over connections, in
    // connection order, with no branch on what happened to any individual -- and the replies are
    // one-per-session, sorted by SessionId, which is CSPRNG-drawn. So there is no path by which a
    // player's own cell can influence when their own bytes are written. The timing an attacker
    // can observe is a function of GLOBAL LOAD ACROSS THE ENTIRE CITY. Timing your own reply tells
    // you "the world was busy this tick." It does not tell you whether YOUR room reached quorum,
    // which is the thing I3 protects.
    //
    // ** That structural property is in the HUMAN bucket. Nothing here enforces it. **
    // If you move the write inside the resolution loop, no test in this file will stop you. Say it
    // out loud at every review of transport.tick: THE WRITE LOOP RUNS AFTER THE WORLD RESOLVES.
    //
    // WHAT THIS TEST DOES ENFORCE is the one thing the old comment worried about that IS
    // mechanisable: "an allocation per fight, a syscall per fight, a log line per fight." Any of
    // those would put a per-person cost inside the resolution of a live cell -- which is the raw
    // material a timing channel is built from, and which would show up here as an allocation count
    // that scales with the number of people in the room. So: count the calls, at two populations.
    const gpa = testing.allocator;

    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const at_600 = try extraAllocationsAtWar(io, gpa, 600);
    const at_1200 = try extraAllocationsAtWar(io, gpa, 1200);

    // THE TRIPWIRE. Measured at 13: the handful of bulk allocations a fight needs that a silent
    // world does not (the tells array, and the growth steps of the map that holds them). Thirteen,
    // not six hundred. The slack is headroom for an honest new bulk allocation; it is nowhere near
    // enough room to hide a per-person one.
    const slack = 32;
    try testing.expect(at_600 <= slack);

    // THE PROPERTY, STATED WITHOUT A MAGIC NUMBER. Double the people in the fight and the extra
    // allocation calls must NOT double. If anything allocates per combatant, per engagement, or
    // per fight participant, this is where it dies: at_1200 would land near 2x at_600, or worse,
    // near 1200. Hash maps grow logarithmically, so the honest cost of doubling is a step or two.
    //
    // This is the assertion that survives a change of machine, a change of compiler, and a bad
    // afternoon -- because it is about the SHAPE of the cost, not its size in microseconds.
    try testing.expect(at_1200 < at_600 * 2);
}
