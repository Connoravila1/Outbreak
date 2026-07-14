//! THE FORBIDDEN-CONSTRUCT GUARD — comptime. Fails the build, not the review.
//!
//! CLAUDE.md lists constructs that "will be produced helpfully and wrongly". A distance
//! function, a neighbour search, an inverse quantizer, a coordinate carried inward. Each
//! is a single plausible-looking function that quietly ends the privacy guarantee, and
//! each will look reasonable on the day someone writes it.
//!
//! Leaving that to human vigilance is the one thing we know does not work. So this guard
//! takes the same strategy as the size guard (A7): the compiler is what stops it. A
//! forbidden construct does not fail review -- it fails to compile, on the machine of
//! the person writing it, in the second they write it.
//!
//! Four rules are enforced here:
//!
//!   1. No geometry, anywhere. No distance, bearing, heading, radius, neighbour, or
//!      inverse quantizer, in core or shell (A9, I2).
//!   2. THE COORDINATE WALL (B6). No float appears in a file classified CORE. The core
//!      has no vocabulary for a position, and this is what makes that literally true
//!      rather than aspirationally true.
//!   3. PURITY (B3, B4). No core file may REACH FOR the clock, the disk, the network, a
//!      syscall, a CSPRNG, or a global allocator. This one was added after B3 was broken in
//!      the session layer and the build said nothing -- see `forbidden_in_core`.
//!   4. THE CLIENT IS AUTHORITATIVE OVER NOTHING (H1). Enforced in protocol.zig itself, at
//!      the definition of the client's message: adding a field fails the build.
//!
//! Adding a source file means registering it below, as core or as shell. That is
//! deliberate: B1 requires every unit be classified, with no third category and nothing
//! unclassified, and this is where the classification is written down.

const std = @import("std");

/// Constructs that must not exist in this codebase. A CellId is a group-by key, not a
/// compressed coordinate (A9). The game has no geometry -- not because we forgot to add
/// it, but because a bearing is a step on the road to a name.
const forbidden = [_][]const u8{
    "fn distance",
    "fn neighbours",
    "fn neighbors",
    "fn toLatLon",
    "fn toLatLng",
    "fn toCoord",
    "fn toPoint",
    "fn bearing",
    "fn heading",
    "fn radius",
    "fn nearby",
    "fn adjacent",
    "fn kRing",
    "fn ring",
    "fn decodeCell",
    "fn unquantize",
};

/// Constructs forbidden by the integrity rules.
///
/// H4: a suspicion score is a soft signal. No automated punitive action may be derived from
/// it, ever. A false positive costs a real player slightly less XP -- never their account.
///
/// H6: we do not enter the attestation arms race. No client attestation, no root detection,
/// no mock-location check, no signature verification. All are bypassable, all break
/// legitimate players' phones, all demand perpetual maintenance we will never sustain, and
/// all are unnecessary, because no location carries a reward worth spoofing toward (H2).
///
/// Both of these will be proposed in good faith by someone tired and reasonable. Neither
/// will compile.
const forbidden_integrity = [_][]const u8{
    "fn ban",
    "fn autoBan",
    "fn suspend",
    "fn punish",
    "fn attest",
    "fn detectRoot",
    "fn isRooted",
    "fn checkMockLocation",
    "fn verifySignature",
    "fn deviceFingerprint",
};

/// THINGS THE CORE MAY NOT REACH FOR (B3, B4).
///
/// The core is pure: no I/O, no clock, no randomness, no network, no GPS, no global allocator.
///
/// THIS LIST EXISTS BECAUSE THE GUARD DID NOT HAVE IT, AND I BROKE B3.
///
/// The session layer minted session ids with the tick's deterministic mixer -- splitmix64, a
/// bijection, seeded from values an attacker can guess. Session ids were forgeable. It was
/// caught by reading another project's security document, not by the build, and that is the
/// wrong way to find it.
///
/// The guard checked what functions were DEFINED. It never checked what the core REACHED FOR.
/// A clock, a socket, a CSPRNG, or a global allocator could have walked into any core file and
/// nothing would have stopped it. Now something does.
///
/// (`std.crypto` is on the list too: the core has no business with secrets. `Io.randomSecure`
/// needs an `Io` handle the core does not have, so the language already agreed -- but a rule
/// enforced by two mechanisms is a rule that survives one of them changing.)
const forbidden_in_core = [_][]const u8{
    "std.Io", // I/O, and the clock and CSPRNG that hang off it
    "std.fs", // the disk
    "std.net", // the network
    "std.posix", // syscalls
    "std.process", // the outside world
    "std.time", // what time is it -- the core never asks (B7)
    "std.crypto", // secrets are not the core's business
    "std.heap.page_allocator", // a hidden allocator is a hidden cost (C1, C2)
    "std.heap.c_allocator",
    "std.heap.smp_allocator",
    "std.debug.print", // the core does not talk to a terminal
    "randomSecure",
};

/// LAYOUT IS A MODULE'S OWN BUSINESS (C4, D3).
///
/// `presences` is the world module's MultiArrayList. Reaching into it from another module
/// means depending on how the world is STORED, and being able to WRITE to memory you do not
/// own. Three modules did exactly that -- the synthetic city, the session layer, and replay --
/// and every one of them worked, which is why nobody noticed.
///
/// Only the world module (world.zig + tick.zig, one module in two files) may name it. Everyone
/// else uses the read-only accessors, or `relocate` to say who is where.
const layout_owner = [_][]const u8{ "world.zig", "tick.zig" };
/// Matched with the leading dot: this is the ACCESS (`world.presences`), not the English word,
/// which appears in comments all over the codebase and is not a violation of anything.
const owned_layout = ".presences";

/// THE PHONE COMPUTES NOTHING (H1), ENFORCED AT THE C ABI.
///
/// `ffi.zig` is the entire surface between the Zig core and the phone. What it must never do is
/// resolve anything: no combat, no tick, no quorum, no XP, no loot, no territory.
///
/// The phone can quantize a coordinate, put bytes on a wire, and read bytes off it. That is the
/// whole vocabulary of a device we have decided to believe nothing from.
///
/// Every request to widen this will be reasonable. "Predict the damage locally so the UI feels
/// instant." "Resolve the fight client-side and reconcile." "Cache the quorum so we can show
/// something offline." Each is latency, or feel, or offline support -- and each hands authority
/// to a device that has none. The answer is no, and it fails the build.
const forbidden_in_ffi = [_][]const u8{
    "combat.resolve",
    "combat.engagementLength",
    "tick.tick",
    "tick_mod.tick",
    "world.award",
    "world_mod.award",
    "world.liveRuns",
    "world_mod.liveRuns",
    "session.tick",
    "session_mod.tick",
    "territory.",
    "integrity.",
};

const ffi_file = "ffi.zig";

const Source = struct { name: []const u8, text: []const u8 };

/// CORE (B1, B2). Pure functions over plain data. A coordinate may not appear here in
/// any form -- no f32, no f64, ever (B6).
const core = [_]Source{
    .{ .name = "root.zig", .text = @embedFile("root.zig") },
    .{ .name = "spatial.zig", .text = @embedFile("spatial.zig") },
    .{ .name = "spatial/cell.zig", .text = @embedFile("spatial/cell.zig") },
    .{ .name = "world.zig", .text = @embedFile("world.zig") },
    .{ .name = "rand.zig", .text = @embedFile("rand.zig") },
    .{ .name = "combat.zig", .text = @embedFile("combat.zig") },
    .{ .name = "tick.zig", .text = @embedFile("tick.zig") },
    .{ .name = "integrity.zig", .text = @embedFile("integrity.zig") },
    .{ .name = "territory.zig", .text = @embedFile("territory.zig") },
    .{ .name = "city.zig", .text = @embedFile("city.zig") },
    .{ .name = "journal.zig", .text = @embedFile("journal.zig") },
    .{ .name = "replay.zig", .text = @embedFile("replay.zig") },
    .{ .name = "protocol.zig", .text = @embedFile("protocol.zig") },
    .{ .name = "session.zig", .text = @embedFile("session.zig") },
    .{ .name = "fuzz_test.zig", .text = @embedFile("fuzz_test.zig") },
    .{ .name = "accounts.zig", .text = @embedFile("accounts.zig") },
};

/// SHELL (B1, B3). Permitted to touch the outside world. Exactly one file here is
/// permitted to hold a coordinate, and only for the duration of one expression (B6).
const shell = [_]Source{
    .{ .name = "spatial/geohash.zig", .text = @embedFile("spatial/geohash.zig") },
    // SHELL because it holds coordinates: the published geohash test vectors are real latitudes
    // and longitudes, and they are the only external check that exists on the one function in
    // the system that touches one. It was UNREGISTERED until the audit found it -- which meant
    // the coordinate wall, the purity check, and the geometry ban had never been applied to the
    // one test file that holds a latitude.
    .{ .name = "spatial/geohash_vectors_test.zig", .text = @embedFile("spatial/geohash_vectors_test.zig") },
    .{ .name = "sim.zig", .text = @embedFile("sim.zig") },
    .{ .name = "store.zig", .text = @embedFile("store.zig") },
    .{ .name = "entropy.zig", .text = @embedFile("entropy.zig") },
    .{ .name = "credential.zig", .text = @embedFile("credential.zig") },
    .{ .name = "transport.zig", .text = @embedFile("transport.zig") },
    .{ .name = "transport_test.zig", .text = @embedFile("transport_test.zig") },
    // SHELL: it holds a coordinate. `outbreak_quantize` is the only function on EITHER side of
    // the network that accepts a latitude, and the float dies before it returns (B6).
    .{ .name = "ffi.zig", .text = @embedFile("ffi.zig") },
};

/// Does `haystack` begin with `needle`? Byte-wise, so that comptime does the least work
/// it possibly can.
fn startsWith(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (needle, haystack[0..needle.len]) |a, b| {
        if (a != b) return false;
    }
    return true;
}

comptime {
    // The first cut of this used std.mem.indexOf once per (file, pattern). It worked, and
    // it cost twenty-two seconds of every cold build -- Boyer-Moore builds a skip table per
    // pattern per file, at comptime, and there are twenty-six patterns and ten files.
    //
    // Measured, then fixed (G1, G2). This version walks each file's bytes once and only
    // consults the forbidden list where a `fn ` actually appears, which is a few dozen
    // places per file rather than every byte. The guard is not negotiable; its price was.
    @setEvalBranchQuota(10_000_000);

    for (core ++ shell, 0..) |src, file_index| {
        const is_core = file_index < core.len;

        var i: usize = 0;
        while (i < src.text.len) : (i += 1) {
            // Every construct we look for -- `fn `, `f64`, `f32` -- begins with an 'f'. One
            // byte comparison rejects the overwhelming majority of the file, and comptime
            // does no further work on it.
            if (src.text[i] != 'f') continue;

            const rest = src.text[i..];

            // A forbidden function definition. Checked only at the handful of positions
            // where a function is actually being declared.
            if (startsWith(rest, "fn ")) {
                for (forbidden) |construct| {
                    if (startsWith(rest, construct)) {
                        @compileError("FORBIDDEN CONSTRUCT: '" ++ construct ++ "' in " ++ src.name ++
                            ". The game has no geometry: no distance, no bearing, no neighbours, " ++
                            "and no inverse quantizer (A9, I2). A CellId is a room, not a point.");
                    }
                }

                for (forbidden_integrity) |construct| {
                    if (startsWith(rest, construct)) {
                        @compileError("FORBIDDEN CONSTRUCT: '" ++ construct ++ "' in " ++ src.name ++
                            ". A suspicion score never becomes a punishment (H4), and we do not " ++
                            "enter the attestation arms race (H6). No location carries a reward " ++
                            "worth spoofing toward, so there is no war here to fight.");
                    }
                }
            }

            // THE COORDINATE WALL (B6). No float in a file classified core, in any form.
            if (is_core and (startsWith(rest, "f64") or startsWith(rest, "f32"))) {
                @compileError("THE COORDINATE WALL (B6): a float appears in " ++ src.name ++
                    ", which is CORE. The raw coordinate dies at the shell boundary. The core " ++
                    "cannot leak a location because it is never given one.");
            }
        }

        // LAYOUT (C4, D3). Does this file reach into the world's storage?
        {
            var owns = false;
            for (layout_owner) |owner| {
                if (std.mem.eql(u8, src.name, owner)) owns = true;
            }

            if (!owns) {
                var j: usize = 0;
                while (j < src.text.len) : (j += 1) {
                    if (src.text[j] != owned_layout[0]) continue;
                    if (startsWith(src.text[j..], owned_layout)) {
                        @compileError("LAYOUT VIOLATION (C4, D3): '" ++ owned_layout ++ "' appears in " ++
                            src.name ++ ", which does not own it. Reaching into the world's " ++
                            "storage means depending on how the world is stored, and being able " ++
                            "to write to memory you do not own. Use the read-only accessors " ++
                            "(world.cellsOf, playerIds, factions, hitPoints), or relocate() to " ++
                            "say who is where and let the world do its own writing.");
                    }
                }
            }
        }

        // THE PHONE COMPUTES NOTHING (H1). What does the C ABI reach for?
        if (std.mem.eql(u8, src.name, ffi_file)) {
            for (forbidden_in_ffi) |reached| {
                var j: usize = 0;
                while (j < src.text.len) : (j += 1) {
                    if (src.text[j] != reached[0]) continue;
                    if (startsWith(src.text[j..], reached)) {
                        @compileError("H1 VIOLATION at the client boundary: '" ++ reached ++
                            "' is reachable from " ++ ffi_file ++ ". THE PHONE COMPUTES NOTHING. " ++
                            "It quantizes a coordinate, puts bytes on a wire, and reads bytes off " ++
                            "it. It does not resolve a fight, award XP, test quorum, or decide an " ++
                            "outcome -- every outcome is computed server-side from data the client " ++
                            "cannot influence. Whatever this is for -- latency, feel, offline -- " ++
                            "the answer is no.");
                    }
                }
            }
        }

        // PURITY (B3, B4). What does this file REACH FOR?
        //
        // Scanned separately, because these do not start with 'f' and the fast path above skips
        // them. The cost is one pass per core file over a handful of needles; the alternative
        // was the bug that shipped a forgeable session id.
        if (is_core) {
            for (forbidden_in_core) |reached| {
                var j: usize = 0;
                while (j < src.text.len) : (j += 1) {
                    if (src.text[j] != reached[0]) continue;
                    if (startsWith(src.text[j..], reached)) {
                        @compileError("PURITY VIOLATION (B3, B4): '" ++ reached ++ "' appears in " ++
                            src.name ++ ", which is CORE. The core is pure: no I/O, no clock, no " ++
                            "randomness, no network, no GPS, no global allocator. If this file " ++
                            "needs one of those, it is SHELL and must be classified as shell -- " ++
                            "and if it needs a secret, note that a deterministic mixer is not a " ++
                            "CSPRNG, however similar they look at the call site.");
                    }
                }
            }
        }
    }
}
