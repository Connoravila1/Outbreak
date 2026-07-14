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
const ui = @import("../ui.zig");

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

    /// The procedural shapes, baked once at init. Indexed by `ui.Sprite`.
    sprites: [2]Rect = @splat(.{ .x = 0, .y = 0, .w = 0, .h = 0, .advance = 0, .bear_x = 0, .bear_y = 0 }),

    /// The bitmap changed and the GPU has an old copy. The shell re-uploads and clears this.
    /// Starts true: the white texel alone is a change worth uploading.
    dirty: bool = true,
};

pub const dim = 1024;

/// The reserved white texel, in pixels. A 2x2 block rather than a single pixel so that a sampler
/// set to LINEAR cannot possibly interpolate an edge into it.
const white_px = 2;

pub fn init(gpa: Allocator) Error!Atlas {
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

    // ============================================================================
    // THE PROCEDURAL SHAPES.
    //
    // The renderer is "colour times a coverage value sampled from a texture", and nothing else. So
    // a radial falloff written into that same texture is a soft dot, and a soft dot -- tinted, and
    // scaled -- is every gradient the boot sequence needs: a spore, the bloom behind the wordmark,
    // and the wipe that opens the screen.
    //
    // No second shader. No gradient code. No extra draw call. The capability was already there;
    // it only needed something in the atlas to point at.
    atlas.sprites[@intFromEnum(ui.Sprite.disc)] = try bake(&atlas, disc_px, discCoverage);
    atlas.sprites[@intFromEnum(ui.Sprite.vignette)] = try bake(&atlas, vignette_px, vignetteCoverage);

    return atlas;
}

const disc_px = 64;
const vignette_px = 128;

/// Opaque at the centre, gone at the rim. Smoothstep rather than linear, because a linear falloff
/// has a visible hard edge where it reaches zero and reads as a circle rather than a glow.
fn discCoverage(dx: f32, dy: f32) u8 {
    const r = @sqrt(dx * dx + dy * dy);
    if (r >= 1.0) return 0;
    const t = 1.0 - r;
    const smooth = t * t * (3.0 - 2.0 * t);
    return @intFromFloat(@round(smooth * 255.0));
}

/// The inverse. A hole in the middle, solid at the edges. Painted in the background colour and
/// scaled up over the screen, the hole grows and the screen opens.
fn vignetteCoverage(dx: f32, dy: f32) u8 {
    const r = @sqrt(dx * dx + dy * dy);
    if (r >= 1.0) return 255;
    const smooth = r * r * (3.0 - 2.0 * r);
    return @intFromFloat(@round(smooth * 255.0));
}

/// Write a procedurally generated square of coverage into the atlas and return where it landed.
fn bake(atlas: *Atlas, size: u32, comptime coverage: fn (f32, f32) u8) Error!Rect {
    if (atlas.pen_x + size > atlas.dim) {
        atlas.pen_y += atlas.shelf_h + 1;
        atlas.pen_x = 0;
        atlas.shelf_h = 0;
    }
    if (atlas.pen_x + size > atlas.dim or atlas.pen_y + size > atlas.dim) return Error.AtlasFull;

    const x = atlas.pen_x;
    const y = atlas.pen_y;
    const half: f32 = @as(f32, @floatFromInt(size)) / 2.0;

    var row: u32 = 0;
    while (row < size) : (row += 1) {
        var col: u32 = 0;
        while (col < size) : (col += 1) {
            // The centre of the texel, not its corner -- otherwise the disc is half a pixel
            // off-centre and the bloom sits crooked behind the wordmark.
            const dx = (@as(f32, @floatFromInt(col)) + 0.5 - half) / half;
            const dy = (@as(f32, @floatFromInt(row)) + 0.5 - half) / half;
            atlas.coverage[(y + row) * atlas.dim + x + col] = coverage(dx, dy);
        }
    }

    atlas.pen_x += size + 1;
    if (size > atlas.shelf_h) atlas.shelf_h = size;
    atlas.dirty = true;

    return .{
        .x = @intCast(x),
        .y = @intCast(y),
        .w = @intCast(size),
        .h = @intCast(size),
        .advance = 0,
        .bear_x = 0,
        .bear_y = 0,
    };
}

/// Where a procedural shape lives in the atlas.
pub fn spriteRect(atlas: *const Atlas, sprite: ui.Sprite) Rect {
    return atlas.sprites[@intFromEnum(sprite)];
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

test "the procedural sprites are baked, and they are actually gradients" {
    const gpa = testing.allocator;

    var atlas = try init(gpa);
    defer deinit(&atlas, gpa);

    const disc = spriteRect(&atlas, .disc);
    try testing.expectEqual(@as(u16, disc_px), disc.w);
    try testing.expectEqual(@as(u16, disc_px), disc.h);

    // A u16 row index times a 1024-wide atlas overflows a u16 long before it is an offset. Widen
    // once, here, rather than sprinkling casts down the expression.
    const at = struct {
        fn coverage(a: *const Atlas, x: u32, y: u32) u8 {
            return a.coverage[@as(usize, y) * a.dim + x];
        }
    }.coverage;

    // Bright in the middle, nothing at the rim. If this is flat, the "glow" is a square.
    const centre = at(&atlas, disc.x + disc_px / 2, disc.y + disc_px / 2);
    const corner = at(&atlas, disc.x, disc.y);
    try testing.expect(centre > 250);
    try testing.expectEqual(@as(u8, 0), corner);

    // And it falls off in between rather than stepping -- a hard edge reads as a circle, not a glow.
    const midway = at(&atlas, disc.x + disc_px / 2 + disc_px / 4, disc.y + disc_px / 2);
    try testing.expect(midway > 0 and midway < centre);

    // The vignette is the inverse: a hole in the middle, solid at the edge. Painted in the
    // background colour, that hole is what opens the screen.
    const vig = spriteRect(&atlas, .vignette);
    const vig_centre = at(&atlas, vig.x + vignette_px / 2, vig.y + vignette_px / 2);
    const vig_corner = at(&atlas, vig.x, vig.y);
    try testing.expect(vig_centre < 5);
    try testing.expectEqual(@as(u8, 255), vig_corner);

    // Neither landed on the white texel that every rectangle in the game samples.
    try testing.expect(disc.x >= white_px or disc.y >= white_px);
    try testing.expectEqual(@as(u8, 255), atlas.coverage[0]);
}
