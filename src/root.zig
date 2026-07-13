//! Outbreak — module root.
//!
//! Phase 0: the whole game runs as a test suite. There is no executable, no server, no
//! network, and no map. `zig build test` is the entire product.

/// Spatial quantization: the cell, the coarsening rule, and k (D1).
pub const spatial = @import("spatial.zig");

/// The world, as columns of plain data (A1, A3).
pub const world = @import("world.zig");

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
}
