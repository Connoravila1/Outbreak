//! SHELL (B1). The draw list, turned into triangles. No GL, no EGL, no phone.
//!
//!     ui.Draw[]  ->  Vertex[]
//!
//! ============================================================================
//! WHY THIS IS SHELL, AND WHY IT IS PURE ANYWAY
//!
//! This module is a pure function. Same list in, same triangles out, no I/O, no clock. By B2's
//! definition it would qualify as core.
//!
//! It is classified SHELL because it speaks the GPU's vocabulary, and the GPU's vocabulary is
//! floats. The coordinate wall (B6) is enforced by a guard that forbids a float from appearing in
//! any file classified core -- bluntly, textually, by design. These floats are SCREEN PIXELS and
//! could not be a latitude if they tried; but the guard does not read intent, and it is not to be
//! weakened to accommodate mine. When in doubt, obey the stricter reading. So: shell.
//!
//! Being pure anyway is not a loophole, it is the point. It means the entire transform -- the
//! colour unpacking, the winding order, the pixel geometry -- is tested on a laptop, with no
//! phone plugged in, exactly like the tick and exactly like ui.zig. What is left in `gles.zig` is
//! only the part that genuinely cannot be tested without a GPU.
//!
//! ============================================================================
//! THIS MODULE KNOWS NOTHING ABOUT THE GAME
//!
//! It consumes `ui.Draw` -- a plain value -- and produces vertices. It imports no game state, it
//! writes no game state, and nothing in the game imports it (D7). It has never heard of a cell.

const std = @import("std");
const ui = @import("ui.zig");

const Allocator = std.mem.Allocator;

/// One corner of one triangle, in the layout the vertex shader expects.
///
/// `extern` because the GPU reads this memory directly: the field order IS the attribute layout,
/// and `gles.zig` computes its attribute offsets from it with `@offsetOf`. Zig's default layout
/// makes no such promise, and a reordered field would silently paint the screen wrong.
///
/// Positions are pixels, top-left origin, y down. The vertex shader does the projection to clip
/// space; there is no matrix anywhere in this renderer.
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    comptime {
        // Budget: 6 x f32 = 24 bytes, exact. Six of these per rectangle.
        //
        // Raising this requires a recorded justification (A7.1). The obvious future pressure is
        // M.3's glyphs, which want a (u, v) pair -- that is a real field genuinely needed, and it
        // is a deliberate bump to 32, not a quiet one.
        std.debug.assert(@sizeOf(Vertex) == 24);
    }
};

/// Six vertices per rectangle: two triangles, no index buffer.
///
/// An index buffer would save eight bytes per quad on a list that is a few hundred quads long.
/// That is the stop rule (G3): the cost is already nothing, so the complexity buys nothing.
pub const vertices_per_rect = 6;

/// SHELL, pure. Append the triangles for a draw list. Allocates into the caller's list (C1, C2).
///
/// `Draw.text` is SKIPPED, deliberately and silently. M.2 is the quad pass; glyphs are M.3. The
/// text is in the list, it is simply not yet on the screen, and the day M.3 lands it appears with
/// no change to this signature.
pub fn build(draws: []const ui.Draw, out: *std.ArrayList(Vertex), gpa: Allocator) Allocator.Error!void {
    out.clearRetainingCapacity();

    for (draws) |item| switch (item) {
        .rect => |it| {
            // A rectangle with no area is not a rectangle. It is six degenerate triangles and a
            // waste of the bus.
            if (it.w <= 0 or it.h <= 0) continue;
            try pushRect(out, gpa, it.x, it.y, it.w, it.h, rgba(it.color));
        },

        // M.3. The glyph pass. Not a gap -- a phase.
        .text => {},
    };
}

fn pushRect(
    out: *std.ArrayList(Vertex),
    gpa: Allocator,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    colour: [4]f32,
) Allocator.Error!void {
    const x0: f32 = @floatFromInt(x);
    const y0: f32 = @floatFromInt(y);
    const x1: f32 = @floatFromInt(x + w);
    const y1: f32 = @floatFromInt(y + h);

    // Clockwise from the top-left, because the projection is y-down. Two triangles: 0-1-2, 0-2-3.
    const corner = [4][2]f32{
        .{ x0, y0 }, // 0  top-left
        .{ x1, y0 }, // 1  top-right
        .{ x1, y1 }, // 2  bottom-right
        .{ x0, y1 }, // 3  bottom-left
    };

    const order = [vertices_per_rect]usize{ 0, 1, 2, 0, 2, 3 };

    try out.ensureUnusedCapacity(gpa, vertices_per_rect);
    for (order) |i| {
        out.appendAssumeCapacity(.{
            .x = corner[i][0],
            .y = corner[i][1],
            .r = colour[0],
            .g = colour[1],
            .b = colour[2],
            .a = colour[3],
        });
    }
}

/// A `ui.Color` is `0xRRGGBBAA`. THE ALPHA IS LAST.
///
/// This is worth a sentence because the obvious mistake here does not crash, does not fail to
/// compile, and does not look wrong in a diff -- it just paints the wrong colour on a phone you
/// are not holding. The prior art this renderer was ported from packs `0xAARRGGBB`, the other way
/// round. Read `ui.Color`: `void_black = 0x08080AFF` is a nearly-black with FULL alpha, and it is
/// only nearly-black if you unpack it in this order. There is a test below that pins exactly that.
fn rgba(colour: ui.Color) [4]f32 {
    const c = @intFromEnum(colour);
    return .{
        @as(f32, @floatFromInt((c >> 24) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((c >> 16) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((c >> 8) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt(c & 0xFF)) / 255.0,
    };
}

const testing = std.testing;

test "0xRRGGBBAA: the alpha is last, and getting this backwards is invisible until it is on a phone" {
    // void_black = 0x08080AFF. If this were unpacked as AARRGGBB, the alpha would be 0x08 -- a
    // 3%-opaque background -- and the screen would be transparent rather than black. That bug
    // renders, compiles, and passes every other test in this file.
    const black = rgba(.void_black);
    try testing.expectApproxEqAbs(@as(f32, 8.0 / 255.0), black[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 8.0 / 255.0), black[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10.0 / 255.0), black[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), black[3], 0.001); // FULL alpha. Not 0.03.

    // bone = 0xF0EFECFF -- the brightest thing on the screen, and opaque.
    const bone = rgba(.bone);
    try testing.expectApproxEqAbs(@as(f32, 240.0 / 255.0), bone[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 239.0 / 255.0), bone[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 236.0 / 255.0), bone[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), bone[3], 0.001);

    // Every colour in the palette is fully opaque. If one is not, it was mistyped.
    for ([_]ui.Color{ .void_black, .carrion, .ash, .bone, .smoke, .dust, .grave, .wound, .clot, .scab, .serum }) |colour| {
        try testing.expectApproxEqAbs(@as(f32, 1.0), rgba(colour)[3], 0.001);
    }
}

test "a rectangle is six vertices, wound clockwise from the top-left" {
    const gpa = testing.allocator;

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(gpa);

    const draws = [_]ui.Draw{
        .{ .rect = .{ .x = 10, .y = 20, .w = 30, .h = 40, .color = .bone } },
    };

    try build(&draws, &verts, gpa);
    try testing.expectEqual(@as(usize, 6), verts.items.len);

    // The corners, in pixels, y down. x spans 10..40, y spans 20..60.
    try testing.expectEqual(@as(f32, 10), verts.items[0].x);
    try testing.expectEqual(@as(f32, 20), verts.items[0].y);
    try testing.expectEqual(@as(f32, 40), verts.items[1].x);
    try testing.expectEqual(@as(f32, 20), verts.items[1].y);
    try testing.expectEqual(@as(f32, 40), verts.items[2].x);
    try testing.expectEqual(@as(f32, 60), verts.items[2].y);

    // Second triangle shares corner 0 and corner 2, and closes at the bottom-left.
    try testing.expectEqual(verts.items[0].x, verts.items[3].x);
    try testing.expectEqual(verts.items[0].y, verts.items[3].y);
    try testing.expectEqual(verts.items[2].x, verts.items[4].x);
    try testing.expectEqual(verts.items[2].y, verts.items[4].y);
    try testing.expectEqual(@as(f32, 10), verts.items[5].x);
    try testing.expectEqual(@as(f32, 60), verts.items[5].y);

    // Every vertex of a rect carries that rect's colour.
    for (verts.items) |v| {
        try testing.expectApproxEqAbs(@as(f32, 240.0 / 255.0), v.r, 0.001);
        try testing.expectApproxEqAbs(@as(f32, 1.0), v.a, 0.001);
    }
}

test "text is skipped, not dropped -- M.2 is the quad pass" {
    const gpa = testing.allocator;

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(gpa);

    const draws = [_]ui.Draw{
        .{ .text = .{ .x = 0, .y = 0, .text = "OUTBREAK", .color = .bone, .weight = .label } },
        .{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10, .color = .ash } },
        .{ .text = .{ .x = 0, .y = 0, .text = "Nothing here.", .color = .dust, .weight = .body } },
    };

    try build(&draws, &verts, gpa);

    // One rect among three draws. The text is in the list; it is simply not yet on the screen.
    try testing.expectEqual(@as(usize, 6), verts.items.len);
}

test "an empty rectangle is not drawn" {
    const gpa = testing.allocator;

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(gpa);

    const draws = [_]ui.Draw{
        .{ .rect = .{ .x = 0, .y = 0, .w = 0, .h = 40, .color = .bone } },
        .{ .rect = .{ .x = 0, .y = 0, .w = 40, .h = 0, .color = .bone } },
        .{ .rect = .{ .x = 0, .y = 0, .w = -5, .h = 40, .color = .bone } },
    };

    try build(&draws, &verts, gpa);
    try testing.expectEqual(@as(usize, 0), verts.items.len);
}

test "THE SHAPE OF THE SCREEN IS NOT A HEADCOUNT: six people and six thousand draw the same rectangles" {
    // I5, at the glass.
    //
    // `ui.zig` already proves no SENTENCE contains a digit. That test guards the words. This one
    // guards the GEOMETRY, which nothing else does -- and geometry is the easier place to leak,
    // because a leak there does not look like a number. It looks like design.
    //
    // The feature that will be requested, in good faith, by someone reasonable, is a crowd meter:
    // a little bar that fills up as the room gets busier. It would be beautiful. It would also be
    // an analogue readout of the occupancy of a room full of real people, and a player could sit
    // in a cafe, watch the bar twitch down, and look up at whoever just stood to leave.
    //
    // So: the rectangles on the live screen must be IDENTICAL across every crowd band. Not
    // similar. Identical. If a future rect ever scales, fills, repeats, or shades with `crowd`,
    // this test fails and the reason is written above it.
    const gpa = testing.allocator;
    const size: ui.Size = .{ .w = 1080, .h = 2400 };

    var draws: std.ArrayList(ui.Draw) = .empty;
    defer draws.deinit(gpa);

    var a_few_of_them: std.ArrayList(Vertex) = .empty;
    defer a_few_of_them.deinit(gpa);

    var thousands_of_them: std.ArrayList(Vertex) = .empty;
    defer thousands_of_them.deinit(gpa);

    const start: ui.State = .{ .screen = .quiet, .faction = .human };

    // The smallest room the game will admit to: at quorum, and no larger.
    const few = ui.told(start, 60, 4, 900, 12, .even, .a_few);
    try ui.draw(few, size, &draws, gpa);
    try build(draws.items, &a_few_of_them, gpa);

    // A stadium. Everything else about the two ticks is identical -- same damage, same hp, same
    // momentum -- so `crowd` is the ONLY difference, and therefore the only thing a difference in
    // the pixels could possibly be reporting.
    const thousands = ui.told(start, 60, 4, 900, 12, .even, .thousands);
    try ui.draw(thousands, size, &draws, gpa);
    try build(draws.items, &thousands_of_them, gpa);

    try testing.expectEqualSlices(Vertex, a_few_of_them.items, thousands_of_them.items);

    // And it is a real screen we are comparing, not two empty lists that trivially match.
    try testing.expect(a_few_of_them.items.len > vertices_per_rect);
}

test "the real screens rasterise, and the background is always first" {
    // The list ui.zig actually emits, through the transform the phone actually runs. If this
    // allocates wrong, leaks, or drops the background, it happens here and not in a cafe.
    const gpa = testing.allocator;

    var draws: std.ArrayList(ui.Draw) = .empty;
    defer draws.deinit(gpa);

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(gpa);

    const size: ui.Size = .{ .w = 1080, .h = 2400 };

    for ([_]ui.State{
        .{},
        .{ .screen = .quiet, .faction = .human },
        .{ .screen = .live, .faction = .zombie, .hp = 40, .crowd = .dozens, .momentum = .zombies_winning },
    }) |state| {
        try ui.draw(state, size, &draws, gpa);
        try build(draws.items, &verts, gpa);

        // Every screen begins with the background, full-bleed. It is the first rect ui.draw emits
        // and therefore the first six vertices here -- and it must cover the whole surface, or the
        // phone shows whatever was in the framebuffer before us.
        try testing.expect(verts.items.len >= vertices_per_rect);
        try testing.expectEqual(@as(f32, 0), verts.items[0].x);
        try testing.expectEqual(@as(f32, 0), verts.items[0].y);
        try testing.expectEqual(@as(f32, 1080), verts.items[2].x);
        try testing.expectEqual(@as(f32, 2400), verts.items[2].y);

        // And it is opaque, or everything behind it shows through.
        try testing.expectApproxEqAbs(@as(f32, 1.0), verts.items[0].a, 0.001);

        // Whatever else is on screen, the vertex count is a whole number of rectangles.
        try testing.expectEqual(@as(usize, 0), verts.items.len % vertices_per_rect);
    }
}
