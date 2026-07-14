//! SHELL (B1). One texture's worth of coverage: every glyph the game has drawn, packed.
//!
//! A single-channel 8-bit bitmap and a shelf packer. It knows nothing about GL -- it produces a
//! byte array and a rectangle per glyph, and `gles.zig` uploads it. It is therefore testable, in
//! full, with no phone and no GPU, which is where every bug in it will actually be found.
//!
//! ============================================================================
//! THE WHITE TEXEL, AND WHY THERE IS ONLY ONE DRAW CALL
//!
//! A rectangle and a letter are the same thing to this renderer: a quad, a colour, and a coverage
//! value sampled from this texture. A letter samples its glyph. A rectangle samples a single
//! reserved texel that is pure white -- coverage 1.0, everywhere, always.
//!
//! So the fragment shader has no branch, the vertex has no mode flag, and the whole screen -- the
//! background, the faction cards, the condition bar, every letter of every sentence -- is ONE
//! `glDrawArrays` over ONE buffer. The alternative is a mode attribute and a branch per fragment,
//! to express something a texel already expresses.

const std = @import("std");
const text = @import("text.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Error = error{AtlasFull} || text.Error;

/// Where one glyph landed, and how to place it against the pen.
pub const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    advance: i16,
    bear_x: i16,
    bear_y: i16,
    _pad: u16 = 0,

    comptime {
        // Budget: 4 x u16 (the rect) + 3 x i16 (the metrics) + 2 pad = 16 bytes, exact. One per
        // distinct glyph in the game's copy, looked up once per character per frame (A7.1).
        assert(@sizeOf(Rect) == 16);
    }
};

/// The texture, square, single channel.
///
/// 1024 is generous to the point of absurdity for a game whose entire vocabulary is a few dozen
/// fixed sentences at four sizes -- a few hundred glyphs, a few tens of thousands of pixels. It is
/// one megabyte and it will never fill. Sizing it tightly would buy nothing and add a failure mode.
///
/// A7.2: cold struct, size guard waived -- there is exactly one, for the life of the process.
pub const Atlas = struct {
    coverage: []u8,
    dim: u32,

    /// Shelf packer: the pen, and the tallest thing on the current shelf.
    pen_x: u32 = 0,
    pen_y: u32 = 0,
    shelf_h: u32 = 0,

    rects: std.AutoHashMapUnmanaged(u64, Rect) = .empty,

    /// The bitmap changed and the GPU has an old copy. The shell re-uploads and clears this.
    /// Starts true: the white texel alone is a change worth uploading.
    dirty: bool = true,
};

pub const dim = 1024;

/// The reserved white texel, in pixels. A 2x2 block rather than a single pixel so that a sampler
/// set to LINEAR cannot possibly interpolate an edge into it.
const white_px = 2;

pub fn init(gpa: Allocator) Allocator.Error!Atlas {
    const coverage = try gpa.alloc(u8, dim * dim);
    @memset(coverage, 0);

    var atlas: Atlas = .{ .coverage = coverage, .dim = dim };

    // The white block, first, at the origin. Everything else packs after it.
    var y: u32 = 0;
    while (y < white_px) : (y += 1) {
        @memset(atlas.coverage[y * dim ..][0..white_px], 255);
    }
    atlas.pen_x = white_px + 1;
    atlas.shelf_h = white_px;

    return atlas;
}

pub fn deinit(atlas: *Atlas, gpa: Allocator) void {
    gpa.free(atlas.coverage);
    atlas.rects.deinit(gpa);
    atlas.* = undefined;
}

/// The centre of the white texel, in texture coordinates.
///
/// The CENTRE, not a corner. All four corners of a rectangle's quad get this identical value, so
/// every fragment across that quad interpolates to exactly this point and samples exactly this
/// texel -- full coverage, no bleeding from the neighbour, whatever the filter is doing.
pub fn whiteUv() [2]f32 {
    const half: f32 = @as(f32, white_px) / 2.0;
    return .{ half / @as(f32, dim), half / @as(f32, dim) };
}

/// SHELL. Where is this glyph in the texture? Rasterize and pack it if this is the first time.
///
/// The coverage bytes borrowed from the engine are consumed IN THIS FUNCTION, before anything
/// else can invalidate them. That lifetime is the reason this is one function and not two.
pub fn ensure(
    atlas: *Atlas,
    engine: *text.Engine,
    gpa: Allocator,
    face: text.Face,
    px: u16,
    codepoint: u21,
) Error!Rect {
    const key = (@as(u64, @intFromEnum(face)) << 40) | (@as(u64, px) << 21) | @as(u64, codepoint);

    if (atlas.rects.get(key)) |rect| return rect;

    const g, const coverage = try text.glyph(engine, gpa, face, px, codepoint);

    // No ink: a space, or a glyph the face draws as nothing. It still advances the pen, and it
    // still gets an entry, so we do not rasterize it again on every frame forever.
    if (g.w == 0 or g.h == 0) {
        const blank: Rect = .{
            .x = 0,
            .y = 0,
            .w = 0,
            .h = 0,
            .advance = g.advance,
            .bear_x = g.bear_x,
            .bear_y = g.bear_y,
        };
        try atlas.rects.put(gpa, key, blank);
        return blank;
    }

    // Shelf packing, with a one-pixel gutter so a LINEAR sampler cannot drag a neighbour's ink
    // into this glyph's edge.
    if (atlas.pen_x + g.w > atlas.dim) {
        atlas.pen_y += atlas.shelf_h + 1;
        atlas.pen_x = 0;
        atlas.shelf_h = 0;
    }
    if (atlas.pen_x + g.w > atlas.dim or atlas.pen_y + g.h > atlas.dim) {
        // Explicit, not silent (E3). At this size it cannot happen with the game's copy -- but a
        // renderer that quietly drops a letter is a renderer that lies about what it showed.
        return Error.AtlasFull;
    }

    const x = atlas.pen_x;
    const y = atlas.pen_y;

    var row: u32 = 0;
    while (row < g.h) : (row += 1) {
        const from = coverage[row * g.w ..][0..g.w];
        const into = atlas.coverage[(y + row) * atlas.dim + x ..][0..g.w];
        @memcpy(into, from);
    }

    atlas.pen_x += g.w + 1;
    if (g.h > atlas.shelf_h) atlas.shelf_h = g.h;
    atlas.dirty = true;

    const rect: Rect = .{
        .x = @intCast(x),
        .y = @intCast(y),
        .w = g.w,
        .h = g.h,
        .advance = g.advance,
        .bear_x = g.bear_x,
        .bear_y = g.bear_y,
    };
    try atlas.rects.put(gpa, key, rect);
    return rect;
}

const testing = std.testing;

test "the white texel is white, and its uv lands inside it" {
    const gpa = testing.allocator;

    var atlas = try init(gpa);
    defer deinit(&atlas, gpa);

    // Every rectangle in the game samples this one texel. If it is not 255, every solid colour on
    // the screen renders dimmer than it should -- uniformly, plausibly, and nobody notices for a
    // month because it just looks like the design.
    try testing.expectEqual(@as(u8, 255), atlas.coverage[0]);
    try testing.expectEqual(@as(u8, 255), atlas.coverage[1]);
    try testing.expectEqual(@as(u8, 255), atlas.coverage[dim]);
    try testing.expectEqual(@as(u8, 255), atlas.coverage[dim + 1]);

    // And the uv must point INSIDE the white block, not at its corner.
    const uv = whiteUv();
    const px_x: u32 = @intFromFloat(uv[0] * @as(f32, dim));
    const px_y: u32 = @intFromFloat(uv[1] * @as(f32, dim));
    try testing.expect(px_x < white_px);
    try testing.expect(px_y < white_px);
    try testing.expectEqual(@as(u8, 255), atlas.coverage[px_y * dim + px_x]);
}

test "a glyph is packed once, and the same glyph comes back to the same rectangle" {
    const gpa = testing.allocator;

    var engine = try text.init(gpa);
    defer text.deinit(&engine, gpa);

    var atlas = try init(gpa);
    defer deinit(&atlas, gpa);

    const first = try ensure(&atlas, &engine, gpa, .inter, 17, 'H');
    const again = try ensure(&atlas, &engine, gpa, .inter, 17, 'H');

    try testing.expectEqual(first.x, again.x);
    try testing.expectEqual(first.y, again.y);
    try testing.expect(first.w > 0 and first.h > 0);
    try testing.expectEqual(@as(u32, 1), atlas.rects.count());

    // It did not land on top of the white texel.
    try testing.expect(first.x >= white_px or first.y >= white_px);

    // And there is actually ink there now.
    var ink = false;
    var row: u32 = 0;
    while (row < first.h) : (row += 1) {
        for (atlas.coverage[(first.y + row) * dim + first.x ..][0..first.w]) |c| {
            if (c != 0) ink = true;
        }
    }
    try testing.expect(ink);
}

test "two glyphs do not overlap, and the gutter between them is clean" {
    const gpa = testing.allocator;

    var engine = try text.init(gpa);
    defer text.deinit(&engine, gpa);

    var atlas = try init(gpa);
    defer deinit(&atlas, gpa);

    const h = try ensure(&atlas, &engine, gpa, .inter, 17, 'H');
    const i = try ensure(&atlas, &engine, gpa, .inter, 17, 'I');

    // On the same shelf, side by side, with at least one pixel between them. Without that gutter a
    // LINEAR sampler drags the neighbour's ink into this glyph's edge, and every letter grows a
    // faint ghost of the letter packed next to it.
    try testing.expectEqual(h.y, i.y);
    try testing.expect(i.x >= h.x + h.w + 1);
}

test "the whole game's copy fits in the atlas, at every size it is drawn at" {
    // The failure this prevents: the atlas fills mid-sentence, in a cafe, and `ensure` returns
    // AtlasFull for the letter 'y' in "You are surrounded by thousands."
    const gpa = testing.allocator;

    var engine = try text.init(gpa);
    defer text.deinit(&engine, gpa);

    var atlas = try init(gpa);
    defer deinit(&atlas, gpa);

    // Every printable ASCII character -- a superset of the game's copy -- at all four styles.
    for ([_]text.Face{ .inter, .oxanium_semibold, .oxanium_bold, .oxanium_extrabold }) |face| {
        for ([_]u16{ 13, 17, 22 }) |px| {
            var codepoint: u21 = 32;
            while (codepoint < 127) : (codepoint += 1) {
                _ = try ensure(&atlas, &engine, gpa, face, px, codepoint);
            }
        }
    }

    // It fits, and it fits with room to spare -- the pen has not even reached the bottom.
    try testing.expect(atlas.pen_y + atlas.shelf_h < dim);
    // 95 printable ASCII, four faces, three sizes. If this number changes, a face or a size was
    // added and the atlas budget deserves a fresh look rather than a nudged constant.
    try testing.expectEqual(@as(u32, 95 * 4 * 3), atlas.rects.count());
}
