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
}
