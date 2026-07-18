//! CORE (pure). Hit testing — point-in-rectangle, back to front.
//!
//! The layout solver produces a flat array of rectangles. This module
//! answers "which one did the finger land on?" by walking the array in
//! reverse (last drawn = topmost = first hit). No allocation, no tree
//! traversal. The caller provides the rectangles and the point; the
//! module returns an index or null.

const std = @import("std");
const assert = std.debug.assert;

/// A positioned rectangle — the output of layout, the input of hit testing
/// and drawing. Origin is top-left.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    comptime {
        assert(@sizeOf(Rect) == 16);
    }
};

/// Point-in-rect, half-open (left/top inclusive, right/bottom exclusive). A
/// free function, not a method: a Rect is plain data and behaviour lives
/// outside it.
pub fn contains(r: Rect, px: f32, py: f32) bool {
    return px >= r.x and px < r.x + r.w and
        py >= r.y and py < r.y + r.h;
}

/// Walk `rects` back to front (last = topmost), return the index of the
/// first rectangle containing `(px, py)`, or `null` if nothing was hit.
/// Only rectangles where the corresponding `hittable` entry is true are
/// considered — decorative backgrounds and spacers are skipped.
pub fn test_hit(rects: []const Rect, hittable: []const bool, px: f32, py: f32) ?usize {
    assert(rects.len == hittable.len);
    var i: usize = rects.len;
    while (i > 0) {
        i -= 1;
        if (hittable[i] and contains(rects[i], px, py)) return i;
    }
    return null;
}

/// Simplified version when every rectangle is hittable.
pub fn test_hit_all(rects: []const Rect, px: f32, py: f32) ?usize {
    var i: usize = rects.len;
    while (i > 0) {
        i -= 1;
        if (contains(rects[i], px, py)) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "hit: topmost rectangle wins" {
    const rects = [_]Rect{
        .{ .x = 0, .y = 0, .w = 100, .h = 100 }, // background
        .{ .x = 10, .y = 10, .w = 50, .h = 50 }, // button on top
    };
    // Point inside the overlap: the topmost (index 1) wins.
    try testing.expectEqual(@as(?usize, 1), test_hit_all(&rects, 20, 20));
    // Point outside the button but inside the background.
    try testing.expectEqual(@as(?usize, 0), test_hit_all(&rects, 80, 80));
    // Point outside everything.
    try testing.expectEqual(@as(?usize, null), test_hit_all(&rects, 200, 200));
}

test "hit: hittable mask skips decorative elements" {
    const rects = [_]Rect{
        .{ .x = 0, .y = 0, .w = 100, .h = 100 }, // background (not hittable)
        .{ .x = 10, .y = 10, .w = 50, .h = 50 }, // button
    };
    const hittable = [_]bool{ false, true };
    // Point on the background: skipped because not hittable.
    try testing.expectEqual(@as(?usize, null), test_hit(&rects, &hittable, 80, 80));
    // Point on the button: hit.
    try testing.expectEqual(@as(?usize, 1), test_hit(&rects, &hittable, 20, 20));
}

test "hit: empty array returns null" {
    const rects = [_]Rect{};
    try testing.expectEqual(@as(?usize, null), test_hit_all(&rects, 0, 0));
}

test "hit: edge inclusivity — left and top edges are inside" {
    const r = [_]Rect{.{ .x = 10, .y = 20, .w = 30, .h = 40 }};
    // Left edge and top edge: inside.
    try testing.expectEqual(@as(?usize, 0), test_hit_all(&r, 10, 20));
    // Right edge and bottom edge: outside (half-open interval).
    try testing.expectEqual(@as(?usize, null), test_hit_all(&r, 40, 20));
    try testing.expectEqual(@as(?usize, null), test_hit_all(&r, 10, 60));
}
