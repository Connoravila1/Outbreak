//! THE FORBIDDEN-CONSTRUCT GUARD — comptime. Fails the build, not the review.
//!
//! THE RULESET lists constructs that "will be produced helpfully and wrongly". A distance
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

/// A BUSY-WAIT ON THE PHONE IS A DEAD BATTERY (G5).
///
/// THIS LIST EXISTS BECAUSE THE RENDER THREAD SPUN, AND THE COMMENT ABOVE IT SAID IT DID NOT.
///
/// The idle paths of the render loop called the thread-yield function under a comment reading
/// "Do not spin. Sleep and cost nothing (G5)." That function is `sched_yield`. It surrenders the
/// timeslice and returns IMMEDIATELY -- it is a busy-wait, not a sleep. The loop around it pegged
/// a core for the entire time the app was backgrounded, which for an ambient location game is
/// nearly all of its life. BATTERY.md claims 0.50% over eight hours. A spinning core does not do
/// 0.50% over eight hours.
///
/// It looked like a sleep at the call site. That is the whole trap, and it is the same trap as the
/// deterministic mixer that looked like a CSPRNG: the rule was about a CATEGORY (do not burn the
/// battery), the code was about a PROPERTY (it yields), and they did not visibly collide.
///
/// So the category is mechanised. The phone sleeps in the kernel, via `idle()`, or it does not
/// sleep at all.
const forbidden_on_the_phone = [_][]const u8{
    "Thread.yield",
};

const phone_file = "android.zig";

/// THE RENDERER IS QUARANTINED (D7).
///
/// "The map/rendering module is quarantined absolutely. It may consume a CellId and produce
/// pixels. NO GAME-STATE MODULE MAY IMPORT IT, and it may not write to game state. If the map SDK
/// vanished tomorrow, only the map module would fail to compile."
///
/// That was true, and it was true by luck: nothing enforced it. Now the directory says it and the
/// build means it -- a core file that reaches into `render/` does not compile.
///
/// The renderer is also where the ONE sanctioned rendering dependency lives (stb_truetype, F1/F6).
/// The quarantine is what bounds it: a dependency you can delete by deleting a directory is a
/// dependency you can actually remove.
const render_dir = "@import(\"render/";

/// THE INTEGER UI CORE DOES NOT IMPORT SPUNKY.
///
/// `spunky/` is the interaction-feel module -- float, shell, pure. It animates presentation
/// values (a drawer fraction, a scroll offset, the war-globe's spin) and hit-tests screen rects.
/// It is legitimately imported by the shell (the frame loop, the renderer) when a screen is
/// wired to it. It must NOT be imported by a CORE file.
///
/// The coordinate wall (B6) already bans a float TOKEN from a core file, but an inferred-type
/// float slips past a textual scan: `const v = spunky.gesture.velocity(&ring);` puts no `f32` in
/// the file yet pulls float motion into the pure integer core. So the import itself is what the
/// build forbids -- the same shape as the renderer quarantine above, and the same lesson as the
/// deterministic mixer that looked like a CSPRNG: bind the CATEGORY, not the token.
///
/// This was a boundary written only in prose (`src/spunky/spunky.zig`) until this guard bound it.
const spunky_dir = "@import(\"spunky/";

/// `root.zig` is the module manifest, not a unit of logic -- it re-exports everything so the test
/// binary can reach it, and it imports the shell too. It is the one file permitted to name the
/// renderer (and spunky), and it is named here rather than left as an unexplained hole.
const render_importer_exempt = "root.zig";

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
    .{ .name = "ui.zig", .text = @embedFile("ui.zig") },
    .{ .name = "gps.zig", .text = @embedFile("gps.zig") },
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
    // SHELL: the Android host. It holds the NDK, EGL, threads, and the OS lifecycle -- every
    // impure thing on the phone, in one file, so that nothing else on the phone is impure.
    .{ .name = "android.zig", .text = @embedFile("android.zig") },
    // SHELL, and PURE ANYWAY -- the one classification in this list that needs a sentence.
    //
    // `quads.zig` turns a draw list into triangles. It has no I/O and no clock, so by B2 it could
    // be core. It is shell because it speaks the GPU's vocabulary, and that vocabulary is floats:
    // the coordinate wall forbids a float in a core file, bluntly and textually, and it is not to
    // be weakened because THESE floats happen to be screen pixels rather than latitudes. The
    // guard does not read intent. Obey the stricter reading.
    //
    // Being pure regardless is the point, not a loophole: the whole transform is tested on a
    // laptop, and only `gles.zig` needs a GPU.
    .{ .name = "render/quads.zig", .text = @embedFile("render/quads.zig") },
    // SHELL: the GLES2 backend. Shaders, a vertex buffer, and one draw call. This is the whole of
    // what needs a GPU to run, which is why it is the whole of what cannot be tested without one.
    .{ .name = "render/gles.zig", .text = @embedFile("render/gles.zig") },
    // SHELL: the glyph engine. The one file that knows what a font is, and the only one that
    // reaches for the second sanctioned dependency (F1, F6 -- justified in vendor/stb_impl.c).
    .{ .name = "render/text.zig", .text = @embedFile("render/text.zig") },
    // SHELL: the glyph atlas. Pure, and tested without a GPU -- it makes a byte array, not pixels.
    .{ .name = "render/atlas.zig", .text = @embedFile("render/atlas.zig") },
    // SHELL, AND THE HIGHEST-STAKES FILE IN THE CLIENT. The coordinate dies here, in one function,
    // in one expression. The phone is the only place in the system where a latitude ever exists,
    // and this is that place in its entirety.
    .{ .name = "location.zig", .text = @embedFile("location.zig") },
    // SHELL. The server, as a runnable program: bind a socket, accept connections, beat a tick.
    // Everything under it was built and tested in Phase 2; this only assembles it.
    .{ .name = "server.zig", .text = @embedFile("server.zig") },
    // SHELL. The client socket: room up, tell down. Sends a session token and a u64, never a
    // coordinate -- the coordinate died in location.zig (H1, B6).
    .{ .name = "client.zig", .text = @embedFile("client.zig") },
    // SHELL. Governs the GPS radio by the pure policy in gps.zig: builds a Sense from live counts
    // and seconds, calls plan(), turns the radio on and off. It touches the clock and the radio, so
    // it is shell -- but it holds no coordinate (it works in counters, not places), and the guard
    // pins the f64 out of it just the same.
    .{ .name = "governor.zig", .text = @embedFile("governor.zig") },
    // SHELL: spunky, the interaction-feel module (spring physics, gesture feel, hit testing).
    // Vendored by copy from our own side-project; first-party, so not an F1 dependency. It is
    // SHELL for the same reason quads.zig is: it speaks in floats (spring positions, scroll
    // offsets, screen-pixel rects), and the coordinate wall keeps floats out of core textually,
    // pixels or not. Pure regardless -- dt and timestamps are parameters, no clock/RNG/I/O -- so
    // it is fully tested on a laptop. It holds NO f64 (all f32), sees no CellId, and is inert with
    // respect to Section I. It is not imported by ui.zig (the integer UI core); see the boundary
    // note in src/spunky/spunky.zig. Unwired today, adopted ahead of the war-globe/menu work.
    .{ .name = "spunky/spunky.zig", .text = @embedFile("spunky/spunky.zig") },
    .{ .name = "spunky/spring.zig", .text = @embedFile("spunky/spring.zig") },
    .{ .name = "spunky/gesture.zig", .text = @embedFile("spunky/gesture.zig") },
    .{ .name = "spunky/hit.zig", .text = @embedFile("spunky/hit.zig") },
};

/// ============================================================================
/// WHERE A COORDINATE IS ALLOWED TO EXIST. FIVE FILES. NOT SIX.
///
/// B6 already bans a float from any file classified CORE, and that is what makes the server
/// structurally incapable of leaking a location: it was never given one.
///
/// But the SHELL is allowed floats -- the renderer is full of them -- and "screen pixel" and
/// "latitude" are both f64-shaped. Nothing stopped a coordinate from being carried into a fifth
/// shell file, or a sixth, and each one would be a new place it could leak from.
///
/// So the coordinate is pinned. An `f64` may appear in exactly these files and nowhere else:
///
///   spatial/geohash.zig   the quantizer. The one function that turns a place into a room.
///   spatial/geohash_vectors_test.zig   the published test vectors. Real latitudes, checked.
///   ffi.zig               `outbreak_quantize`, the C ABI's one coordinate-shaped door.
///   location.zig          the Android callback. Where the coordinate dies.
///   sim.zig               the synthetic city, which invents coordinates to feed the quantizer.
///
/// Add a sixth and the build stops. If a new file genuinely needs one, that is a decision worth
/// making out loud -- which is the entire point of making the compiler ask.
const coordinate_bearers = [_][]const u8{
    "spatial/geohash.zig",
    "spatial/geohash_vectors_test.zig",
    "ffi.zig",
    "location.zig",
    "sim.zig",
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

        // THE PHONE DOES NOT SPIN (G5). What does the render thread do when it has nothing to do?
        if (std.mem.eql(u8, src.name, phone_file)) {
            for (forbidden_on_the_phone) |reached| {
                var j: usize = 0;
                while (j < src.text.len) : (j += 1) {
                    if (src.text[j] != reached[0]) continue;
                    if (startsWith(src.text[j..], reached)) {
                        @compileError("BATTERY VIOLATION (G5): '" ++ reached ++ "' appears in " ++
                            phone_file ++ ". IT IS NOT A SLEEP. It is `sched_yield`: it gives up " ++
                            "the timeslice and returns immediately, so a loop around it is a " ++
                            "busy-wait that pegs a core. This shipped once, under a comment " ++
                            "promising it did not burn battery, on the thread that runs for the " ++
                            "whole time the app is backgrounded -- which for an ambient game is " ++
                            "nearly always. Battery is a hard constraint and the exit criterion " ++
                            "for this phase is a real number on real hardware. Sleep with " ++
                            "`idle()`, which sleeps in the kernel and stops counting while the " ++
                            "phone is suspended.");
                    }
                }
            }
        }

        // THE COORDINATE IS PINNED (B6). Which files are allowed to hold one?
        {
            var bearer = false;
            for (coordinate_bearers) |name| {
                if (std.mem.eql(u8, src.name, name)) bearer = true;
            }

            if (!bearer) {
                var j: usize = 0;
                while (j < src.text.len) : (j += 1) {
                    if (src.text[j] != 'f') continue;
                    if (startsWith(src.text[j..], "f64")) {
                        @compileError("THE COORDINATE WALL (B6): an f64 appears in " ++ src.name ++
                            ", which is not one of the five files permitted to hold a coordinate. " ++
                            "A latitude and a screen pixel are both f64-shaped, and the difference " ++
                            "between them is the entire privacy guarantee. The quantizer, the test " ++
                            "vectors, the C ABI, the Android callback and the synthetic city may " ++
                            "hold one. Nothing else may. If this file genuinely needs a coordinate, " ++
                            "that is a decision to make out loud -- which is why the compiler is " ++
                            "asking.");
                    }
                }
            }
        }

        // THE RENDERER IS QUARANTINED (D7). Does a game-state file reach into it?
        if (is_core and !std.mem.eql(u8, src.name, render_importer_exempt)) {
            var j: usize = 0;
            while (j < src.text.len) : (j += 1) {
                if (src.text[j] != render_dir[0]) continue;
                if (startsWith(src.text[j..], render_dir)) {
                    @compileError("D7 VIOLATION: " ++ src.name ++ " imports the renderer. " ++
                        "The rendering module is quarantined ABSOLUTELY: it may consume a CellId " ++
                        "and produce pixels, and no game-state module may import it or be written " ++
                        "to by it. If the renderer vanished tomorrow, only the renderer should " ++
                        "fail to compile. It is also where the one sanctioned rendering dependency " ++
                        "lives, and the quarantine is what makes that dependency removable at all.");
                }
                if (startsWith(src.text[j..], spunky_dir)) {
                    @compileError("SPUNKY IN CORE: " ++ src.name ++ " imports spunky, and it is " ++
                        "CORE. Spunky is float, shell interaction-feel -- springs, gesture " ++
                        "momentum, screen-rect hit testing. It belongs to the shell (the frame " ++
                        "loop, the renderer), never the pure integer core. The coordinate wall " ++
                        "catches a float TOKEN in a core file; an inferred-type float from spunky " ++
                        "would not carry one, so the import itself is what fails here. Animate view " ++
                        "state in the shell and hand the core plain integer results.");
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
