//! SPATIAL QUANTIZATION — a sealed module (D1).
//!
//! Behind this boundary live the decisions most likely to change: the geohash bit
//! layout, the precision, the coarsening rule, and k. They are named here and nowhere
//! else. No other module learns the bit layout or the encoding (D3) -- outside this
//! module a CellId is an opaque value you can compare, sort, and hash, and that is all
//! anyone needs to know about a place.
//!
//! The roadmap is explicit that k, tick interval, and cell size are cheap to change now
//! and expensive later. This boundary is what keeps that true.
//!
//! The module straddles the core/shell wall on purpose, and the wall is named at each
//! function: `quantize` is SHELL (it holds a coordinate for one expression), everything
//! else is CORE (pure functions over a u64). Nothing here converts a CellId back toward
//! a coordinate; that function does not exist.

const cell = @import("spatial/cell.zig");
const geohash = @import("spatial/geohash.zig");

/// A place. A room, not a point (A9).
pub const CellId = cell.CellId;

/// Quorum. Below k occupants a cell reports nothing at all -- not a count, not a hint,
/// not "quiet". It is indistinguishable from an empty field (I3).
///
/// k is a floor. Sparse regions are solved by growing the cell, never by lowering this
/// number (I8). It does not bend for engagement, retention, or rural playability.
pub const quorum: u32 = 3;

/// Default precision: 39 bits -> 20 longitude bits, 19 latitude bits.
///
/// At the equator that is a ~38 m square (~125 ft): 360/2^20 degrees of longitude by
/// 180/2^19 degrees of latitude. The odd bit count is deliberate. Longitude spans twice
/// the range of latitude, so the extra longitude bit is exactly what makes the room
/// square; an even precision would give a room twice as wide as it is tall.
///
/// The design target is ~150 ft and 39 bits is the nearest square room to it. Cells
/// narrow with cos(latitude), as in any geohash -- a room in London is about 24 m wide
/// and 38 m tall. This is acceptable: a cell is a room, and rooms need not be identical
/// to be rooms.
pub const default_precision: u6 = 39;

/// The ceiling imposed by the sentinel encoding: one of the 64 bits is always the tag.
pub const max_precision = cell.max_precision;

/// SHELL (B6). Raw coordinate in, CellId out, coordinate discarded in the same
/// expression. Returns null for a reading we will not accept, which the shell drops
/// before the core ever sees it (E5).
pub const quantize = geohash.quantize;

/// CORE. Grow the room until quorum is reachable (I8).
pub const coarsen = cell.coarsen;

/// CORE. Total order on cells: a group-by key, not an adjacency (A9).
pub const lessThan = cell.lessThan;

/// CORE. Stable per-cell entropy for the tick. Mixed, so it is useful as a hash and
/// useless as a location.
pub const hash = cell.hash;

/// CORE. A distinct room from an arbitrary key, with no coordinate behind it. How the
/// core's tests and the synthetic city make places without inventing positions.
pub const cellFromKey = cell.fromKey;

/// CORE. The precision a cell carries, recovered from the value itself.
pub const precisionOf = cell.precisionOf;
