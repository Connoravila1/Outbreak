//! CORE. Fuzzing the trust boundary.
//!
//! THESE ARE THE TWO PLACES HOSTILE BYTES FIRST TOUCH US:
//!
//!   - `protocol.decodeReport` -- what a phone sends. Assume the phone is an attacker, because
//!     one of them is.
//!   - `journal.open` / `journal.next` -- what we read back from disk. A corrupted, truncated,
//!     or maliciously-crafted journal must not crash the server that reads it.
//!
//! Purity is a security testability win: the decoders take bytes and return values, with no
//! I/O and no global state, so fuzzing them is `feed bytes, assert no crash, no leak, no hang`
//! and nothing else. This is the payoff for B2 that nobody advertises.
//!
//! Deterministic and seeded, so a failure is reproducible from its seed rather than being a
//! story about a build that went red once. (The mixer is fine here -- fuzz inputs are not
//! secrets, and B3's point is that a deterministic PRNG must never be mistaken for a CSPRNG,
//! not that determinism is bad.)

const std = @import("std");
const combat = @import("combat.zig");
const journal = @import("journal.zig");
const protocol = @import("protocol.zig");
const rand = @import("rand.zig");
const replay = @import("replay.zig");
const spatial = @import("spatial.zig");
const world_mod = @import("world.zig");

const testing = std.testing;

/// Fill `buffer` with bytes derived from `seed`. Reproducible: a failure names its seed.
fn garbage(seed: u64, buffer: []u8) void {
    var state = seed;
    for (buffer) |*byte| {
        state = rand.mix(state);
        byte.* = @truncate(state >> 24);
    }
}

test "fuzz: a report from a hostile phone never crashes the server" {
    // Every length, including the right one, the empty one, and lengths that straddle the
    // field boundaries. Whatever comes back -- a value or an error -- is a RESULT. A crash is
    // not a result.
    var seed: u64 = 0;
    while (seed < 4000) : (seed += 1) {
        var buffer: [64]u8 = undefined;
        garbage(seed, &buffer);

        const len = seed % buffer.len;
        const bytes = buffer[0..len];

        if (protocol.decodeReport(bytes)) |report| {
            // It decoded. Now validate it -- the shell boundary, where a lying phone becomes an
            // absent player rather than a problem (E5).
            const cell = protocol.validate(report, spatial.default_precision);

            // Whatever survives validation is a real cell at exactly the precision we asked
            // for. Nothing else may reach the core.
            if (cell) |c| {
                try testing.expectEqual(spatial.default_precision, spatial.precisionOf(c));
                try testing.expect(c != spatial.nowhere);
            }
        } else |err| {
            // An explicit error is the correct outcome for garbage (E3). Not a panic, not a
            // silent zero.
            try testing.expect(err == protocol.Error.Truncated or err == protocol.Error.BadVersion);
        }
    }
}

test "fuzz: a hostile cell value never produces a bad cell" {
    // The one lie a perfectly modified phone can tell is a false cell (H1). So: every possible
    // shape of lie, and the shell must either reject it or hand the core something well-formed.
    var seed: u64 = 0;
    while (seed < 20000) : (seed += 1) {
        const claimed: spatial.CellId = @enumFromInt(rand.mix(seed));

        const cell = protocol.validate(
            .{ .session = @enumFromInt(1), .cell = claimed },
            spatial.default_precision,
        );

        if (cell) |c| {
            // Whatever came out is a real room at the working precision. There is no third
            // possibility, and that is what makes the core safe to hand it to.
            try testing.expectEqual(spatial.default_precision, spatial.precisionOf(c));
            try testing.expect(@intFromEnum(c) != 0);
        }
    }
}

test "fuzz: a corrupt journal never crashes the reader" {
    // A journal is read back from a disk we may not control, after a crash we did not plan, on
    // a machine that may have been tampered with. Truncated, corrupted, or hostile -- it must
    // fail cleanly.
    const gpa = testing.allocator;

    var seed: u64 = 0;
    while (seed < 2000) : (seed += 1) {
        var buffer: [128]u8 = undefined;
        garbage(seed, &buffer);

        const len = seed % buffer.len;
        const bytes = buffer[0..len];

        const opened = journal.open(bytes) catch continue; // a clean rejection is the right answer

        var cursor = opened.cursor;
        var records: usize = 0;
        while (journal.next(&cursor) catch break) |_| {
            records += 1;
            if (records > 1000) break; // a hostile journal must not become an infinite loop
        }

        // And replay must survive it too -- it is the thing that actually reads a journal.
        if (replay.replay(gpa, bytes, .default)) |result| {
            var world = result.world;
            world_mod.deinit(&world, gpa);
        } else |_| {
            // An error is fine. A crash is not.
        }
    }
}

test "fuzz: a VALID journal with corrupted innards never crashes the reader" {
    // Nastier than pure garbage: a journal whose header is perfect, so the reader commits to
    // parsing it, and whose body is then poisoned. This is what a tampered file looks like --
    // and what a partially-flushed one looks like after a power cut.
    const gpa = testing.allocator;

    var seed: u64 = 1;
    while (seed < 600) : (seed += 1) {
        var log: std.ArrayList(u8) = .empty;
        defer log.deinit(gpa);

        try journal.writeHeader(&log, gpa, .{ .seed = seed, .precision = spatial.default_precision });

        const players = [_]world_mod.PlayerId{ @enumFromInt(1), @enumFromInt(2), @enumFromInt(3) };
        const factions = [_]world_mod.Faction{ .human, .zombie, .human };
        const hps = [_]u16{ 100, 100, 100 };
        try journal.writeRoster(&log, gpa, 0, &players, &factions, &hps);

        const cell = spatial.cellFromKey(seed, spatial.default_precision);
        try journal.writeTick(&log, gpa, 0, &players, &.{ cell, cell, cell });

        // Poison one byte of the body, anywhere after the header.
        const at = 17 + (rand.mix(seed) % (log.items.len - 17));
        log.items[at] ^= @truncate(rand.mix(seed ^ 0xBAD) | 1);

        if (replay.replay(gpa, log.items, .default)) |result| {
            var world = result.world;
            world_mod.deinit(&world, gpa);
        } else |_| {}
    }
}

test "fuzz: a hostile journal cannot make retention lose its mind" {
    // Retention deletion is the one thing standing between us and holding a location history
    // we promised not to keep (I7). It runs against files we may not control.
    const gpa = testing.allocator;

    var seed: u64 = 0;
    while (seed < 400) : (seed += 1) {
        var buffer: [96]u8 = undefined;
        garbage(seed, &buffer);

        if (journal.prune(gpa, buffer[0 .. seed % buffer.len], seed)) |pruned| {
            var out = pruned;
            out.deinit(gpa);
        } else |_| {}
    }
}

test "fuzz: the handshake frame is the first thing an attacker touches" {
    // `decodeHello` is now the very first code a hostile connection reaches. Before this test it
    // had never been fed a hostile byte, which is how the enum-cast crash got in.
    var seed: u64 = 0;
    while (seed < 6000) : (seed += 1) {
        var buffer: [protocol.hello_size + 16]u8 = undefined;
        garbage(seed, &buffer);

        const len = seed % buffer.len;

        if (protocol.decodeHello(buffer[0..len])) |hello| {
            // It decoded. The faction and intent bytes were VALIDATED, not cast -- so whatever
            // came out is a real value of a real enum, and nothing downstream can be surprised.
            try testing.expect(hello.faction == .human or hello.faction == .zombie);
            try testing.expect(hello.intent == .register or hello.intent == .login);

            // And the padded fields are read safely, whatever garbage is in them. A field with no
            // zero byte at all must not read past its own end.
            const contact = protocol.unpad(&hello.contact);
            const password = protocol.unpad(&hello.password);
            try testing.expect(contact.len <= hello.contact.len);
            try testing.expect(password.len <= hello.password.len);
        } else |err| {
            try testing.expect(
                err == protocol.Error.Truncated or
                    err == protocol.Error.BadVersion or
                    err == protocol.Error.BadValue,
            );
        }
    }
}

test "fuzz: a hello whose version is right and whose body is poison" {
    // Nastier: the frame passes the version check, so the parser COMMITS to it, and only then
    // does it meet the garbage. This is what a real attacker sends -- not noise, but a
    // well-formed envelope around a hostile payload.
    var seed: u64 = 1;
    while (seed < 4000) : (seed += 1) {
        var hello: protocol.Hello = .{
            .contact = undefined,
            .password = undefined,
            .faction = .human,
            .intent = .register,
        };
        garbage(seed, &hello.contact);
        garbage(seed ^ 0xFACE, &hello.password);

        var bytes = protocol.encodeHello(hello);

        // Poison the faction and intent bytes with whatever an attacker likes.
        bytes[130] = @truncate(rand.mix(seed));
        bytes[131] = @truncate(rand.mix(seed ^ 1));

        if (protocol.decodeHello(&bytes)) |decoded| {
            try testing.expect(decoded.faction == .human or decoded.faction == .zombie);
            try testing.expect(decoded.intent == .register or decoded.intent == .login);
        } else |err| {
            // The only way a version-correct frame fails is a value we do not have. Which is
            // exactly right, and exactly what was missing when the fuzzer found the crash.
            try testing.expectEqual(protocol.Error.BadValue, err);
        }
    }
}

test "fuzz: unpad never reads past the end of its field" {
    // A padded field with NO zero byte in it is the edge case: the naive implementation walks off
    // the end looking for a terminator that is not there.
    var seed: u64 = 0;
    while (seed < 2000) : (seed += 1) {
        var field: [64]u8 = undefined;
        garbage(seed, &field);

        // Guarantee some have no zero byte at all.
        if (seed % 3 == 0) {
            for (&field) |*byte| {
                if (byte.* == 0) byte.* = 0xFF;
            }
        }

        const out = protocol.unpad(&field);
        try testing.expect(out.len <= field.len);
    }
}
