//! SHELL. The server, as a program you can run.
//!
//! Everything under this was already built and tested in Phase 2 -- the protocol, the sessions,
//! the accounts, the transport. What was missing was the thing that ASSEMBLES them: a process that
//! binds a socket, accepts connections, and beats a tick. That is all this file is.
//!
//! ============================================================================
//! LOOPBACK ONLY, AND THAT IS NOT A LIMITATION OF THIS FILE
//!
//! `transport.listen` binds 127.0.0.1 and nothing else, on purpose (the address is hard-coded so
//! nobody widens it at 2am). This process speaks plain TCP and does no TLS. In production a TLS
//! proxy sits in front of it; in development, `adb reverse tcp:PORT tcp:PORT` tunnels a phone's
//! own localhost to this process, which is exactly the shape the proxy will have.
//!
//! ============================================================================
//! ReleaseSafe, ALWAYS
//!
//! Every byte this process reads came off a socket from a phone it cannot verify. The overflow,
//! bounds, and unreachable checks are what turn a memory-corruption exploit into a clean abort.
//! The build wires it ReleaseSafe (SECURITY.md).

const std = @import("std");
const account_journal = @import("account_journal.zig");
const accounts = @import("accounts.zig");
const combat = @import("combat.zig");
const replay = @import("replay.zig");
const server_state = @import("server_state.zig");
const store = @import("store.zig");
const transport = @import("transport.zig");
const world = @import("world.zig");

const Io = std.Io;

fn configurePepper(
    server: *transport.Server,
    io: Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    state_exists: bool,
) !void {
    const saved = store.load(io, gpa, path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (saved) |bytes| {
        defer {
            std.crypto.secureZero(u8, bytes);
            gpa.free(bytes);
        }
        if (bytes.len != 32) return error.BadPepper;
        var pepper: [32]u8 = undefined;
        @memcpy(&pepper, bytes);
        transport.setPepper(server, pepper);
        return;
    }
    // A state database without its key is not a new server. Starting anyway would make every
    // account unreachable and invite duplicate registrations over durable player rows.
    if (state_exists) return error.MissingPepper;
    try store.save(io, path, &server.pepper);
}

fn restoreSnapshot(server: *transport.Server, io: Io, gpa: std.mem.Allocator, bytes: []const u8) !void {
    const parts = try server_state.decode(bytes);
    var auth = try account_journal.decode(gpa, parts.accounts);
    errdefer accounts.deinit(&auth.accounts, gpa);
    var restored = try replay.replay(gpa, parts.world, combat.Rules.default);
    errdefer world.deinit(&restored.world, gpa);
    try transport.restore(
        server,
        io,
        gpa,
        restored.world,
        auth,
        restored.next_tick,
        restored.seed,
        restored.precision,
    );
}

/// One thread per connection. `serve` blocks on reads for the life of the connection, so it needs
/// a thread of its own; the accept loop hands each new stream to one and moves on.
const Connection = struct {
    fn run(server: *transport.Server, io: Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream) void {
        transport.serve(server, io, gpa, stream);
    }
};

/// The heartbeat. Every `tick_seconds`, resolve the world and reply to everyone.
///
/// This is the ONLY place a response is sent, which is the structural guarantee behind quorum
/// silence-through-timing (I3): the reply goes out on the tick boundary, after the whole world has
/// resolved, so a stopwatch reads global load and never a per-cell count. See transport_test.zig.
fn tickLoop(server: *transport.Server, io: Io, gpa: std.mem.Allocator, tick_seconds: u32, journal_path: []const u8) void {
    var arena_backing = std.heap.ArenaAllocator.init(gpa);
    defer arena_backing.deinit();

    while (server.running.load(.acquire)) {
        io.sleep(Io.Duration.fromSeconds(@intCast(tick_seconds)), .awake) catch return;

        // Per-tick work in an arena, reset wholesale at the end of the unit of work (C3).
        _ = arena_backing.reset(.retain_capacity);
        transport.tick(server, io, gpa, arena_backing.allocator()) catch {
            // The tick is sacred (E5): a failure to resolve one tick is not a reason to bring the
            // server down. The next tick resolves the world from the data it has.
        };
        const bytes = transport.snapshot(server, io, gpa) catch continue;
        defer gpa.free(bytes);
        store.save(io, journal_path, bytes) catch {};
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // ---- arguments: port, and the tick interval. Both have honest defaults.
    var port: u16 = 7777;
    var tick_seconds: u32 = 30;
    var journal_path: []const u8 = "outbreak.journal";

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next(); // exe
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch port;
        } else if (std.mem.startsWith(u8, arg, "--tick=")) {
            tick_seconds = std.fmt.parseInt(u32, arg["--tick=".len..], 10) catch tick_seconds;
        } else if (std.mem.startsWith(u8, arg, "--journal=")) {
            journal_path = arg["--journal=".len..];
        }
    }

    // The seed is the tick's deterministic mixer input (B7). A fixed value makes a session replay
    // byte-identically, which is a property worth having in development; production supplies its
    // own. It is NOT a source of secrets -- the pepper and session ids come from the OS CSPRNG.
    const seed: u64 = 0x0B5EC7; // "obsect"-ish; any fixed value. Not a secret (B7).

    var server = try transport.init(io, seed, 39, .{});
    defer transport.deinit(&server, gpa);

    const pepper_path = try std.fmt.allocPrint(gpa, "{s}.pepper", .{journal_path});
    defer gpa.free(pepper_path);
    const saved_state = store.load(io, gpa, journal_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (saved_state) |bytes| gpa.free(bytes);
    try configurePepper(&server, io, gpa, pepper_path, saved_state != null);

    if (saved_state) |bytes| {
        if (restoreSnapshot(&server, io, gpa, bytes)) |_| {
            std.debug.print("restored {d} players at tick {d}\n", .{
                server.sessions.next_player -| 1,
                server.sessions.tick_index,
            });
        } else |_| {
            std.debug.print("journal rejected; starting an empty world\n", .{});
        }
    }

    var listener = try transport.listen(io, port);
    defer listener.deinit(io);

    std.debug.print("outbreak server: 127.0.0.1:{d}, tick {d}s\n", .{ port, tick_seconds });

    const tick_thread = try std.Thread.spawn(.{}, tickLoop, .{ &server, io, gpa, tick_seconds, journal_path });
    defer tick_thread.join();

    // ---- accept, forever. One thread per connection.
    while (server.running.load(.acquire)) {
        const stream = listener.accept(io) catch continue;
        const thread = std.Thread.spawn(.{}, Connection.run, .{ &server, io, gpa, stream }) catch {
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}
