//! Outbreak — module root.
//!
//! Phase 0: the whole game runs as a test suite. There is no executable, no server, no
//! network, and no map. `zig build test` is the entire product.

/// Spatial quantization: the cell, the coarsening rule, and k (D1).
pub const spatial = @import("spatial.zig");

/// The world, as columns of plain data (A1, A3).
pub const world = @import("world.zig");

/// Combat and progression rules: tuned forever, so sealed behind one boundary (D1).
pub const combat = @import("combat.zig");

/// Deterministic mixing. Pinned by us, so a replay never drifts (B8).
pub const rand = @import("rand.zig");

/// The tick: (world, seed, index) -> (world', tells). Pure (B7).
pub const tick = @import("tick.zig");

/// Integrity heuristics: plausibility and farm detection, as pure transforms (D1, H4, H5).
pub const integrity = @import("integrity.zig");

/// Territory: sustained clan presence, decaying. Confers nothing (H2).
pub const territory = @import("territory.zig");

/// The synthetic city: a pure generator of plausible people in plausible rooms (0.10).
pub const city = @import("city.zig");

/// The journal: what the world writes down (CellId only), and when it deletes it (I7).
pub const journal = @import("journal.zig");

/// Replay: rebuild a world from its journal and assert it is the same world (1.4, B8).
pub const replay = @import("replay.zig");

/// The disk. Four functions, and it does not know what a record is (1.2).
pub const store = @import("store.zig");

/// The wire protocol: a session and a cell in, sixteen constant bytes out (2.1, H1, I3).
pub const protocol = @import("protocol.zig");

/// Sessions: the whole server, minus the socket (2.4, E5).
pub const session = @import("session.zig");

/// SHELL. The OS CSPRNG. The only source of unguessable values (B3).
pub const entropy = @import("entropy.zig");

/// Accounts: one contact point, one account; rate limits at the farm's front door (H5).
pub const accounts = @import("accounts.zig");

/// SHELL. Passwords and contact fingerprints. The only file that touches crypto.
pub const credential = @import("credential.zig");

/// SHELL. The socket. Loopback only; TLS terminates in front (2.3).
pub const transport = @import("transport.zig");

/// SHELL. The C ABI: what the phone may ask the core to do, and nothing else (3.1, H1).
pub const ffi = @import("ffi.zig");

/// The interface, as a pure function: (told, touched) -> a list of things to draw (3.4).
pub const ui = @import("ui.zig");

/// When to turn the GPS on. Battery is a hard constraint, not an optimization (3.3, G5).
pub const gps = @import("gps.zig");

/// SHELL, and pure anyway: the draw list, turned into triangles. Tested with no phone (M.2).
///
/// `gles.zig` -- the GL calls themselves -- is deliberately NOT here. It is reachable only from
/// `android.zig`, because its `extern fn`s are resolved by the APK's linker and there is no
/// libGLESv2 on a laptop. Everything about the renderer that can be tested without a GPU was put
/// in `quads.zig` precisely so that this line could exist.
pub const quads = @import("render/quads.zig");

comptime {
    // The forbidden-construct guard runs at compile time, so a distance function or a
    // coordinate in the core fails the build rather than the review. Referencing it here
    // is what forces its comptime block to be analysed.
    _ = @import("guard.zig");
}

test {
    _ = @import("spatial.zig");
    _ = @import("spatial/cell.zig");
    _ = @import("spatial/geohash.zig");
    _ = @import("spatial/geohash_vectors_test.zig");
    _ = @import("world.zig");
    _ = @import("combat.zig");
    _ = @import("rand.zig");
    _ = @import("tick.zig");
    _ = @import("integrity.zig");
    _ = @import("territory.zig");
    _ = @import("city.zig");
    _ = @import("journal.zig");
    _ = @import("replay.zig");
    _ = @import("store.zig");
    _ = @import("protocol.zig");
    _ = @import("session.zig");
    _ = @import("entropy.zig");
    _ = @import("fuzz_test.zig");
    _ = @import("accounts.zig");
    _ = @import("credential.zig");
    _ = @import("transport.zig");
    _ = @import("transport_test.zig");
    _ = @import("ffi.zig");
    _ = @import("ui.zig");
    _ = @import("gps.zig");
    _ = @import("render/quads.zig");
    _ = @import("render/gles.zig");
}
