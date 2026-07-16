//! SHELL (B1). The draw list, turned into triangles. No GL, no EGL, no phone.
//!
//!     ui.Draw[]  ->  Vertex[]
//!
//! ============================================================================
//! WHY THIS IS SHELL, AND WHY IT IS PURE ANYWAY
//!
//! Same list in, same triangles out. No I/O, no clock. By B2's definition it would qualify as core.
//!
//! It is classified SHELL because it speaks the GPU's vocabulary, and that vocabulary is floats.
//! The coordinate wall (B6) is enforced by a guard that forbids a float from appearing in any file
//! classified core -- bluntly, textually, by design. These floats are SCREEN PIXELS and could not
//! be a latitude if they tried; but the guard does not read intent, and it is not to be weakened to
//! accommodate mine. When in doubt, obey the stricter reading. So: shell.
//!
//! Being pure anyway is not a loophole, it is the point. The colour unpacking, the winding order,
//! the pixel geometry, the baseline arithmetic -- all of it is tested on a laptop, with no phone
//! plugged in. What is left in `gles.zig` is only what genuinely cannot be tested without a GPU.
//!
//! ============================================================================
//! A LETTER AND A RECTANGLE ARE THE SAME THING
//!
//! Both are a quad, a colour, and a coverage value sampled from the atlas. A letter samples its
//! glyph. A rectangle samples the one reserved white texel -- coverage 1.0, everywhere.
//!
//! So there is no mode flag on the vertex, no branch in the fragment shader, and the entire screen
//! is ONE draw call: the background, the cards, the condition bar, and every letter of every
//! sentence, in one buffer, in one pass.
//!
//! ============================================================================
//! THIS MODULE KNOWS NOTHING ABOUT THE GAME
//!
//! It consumes `ui.Draw` -- a plain value -- and produces vertices. It imports no game state, it
//! writes no game state, and nothing in the game imports it (D7). It has never heard of a cell.

const std = @import("std");
const ui = @import("../ui.zig");
const text = @import("text.zig");
const atlas_mod = @import("atlas.zig");

const Allocator = std.mem.Allocator;

pub const Error = atlas_mod.Error;

/// One corner of one triangle, in the layout the vertex shader expects.
///
/// `extern` because the GPU reads this memory directly: the field order IS the attribute layout,
/// and `gles.zig` derives its offsets from it with `@offsetOf`. Zig's default layout makes no such
/// promise, and a reordered field would silently paint the screen wrong.
///
/// Positions are pixels, top-left origin, y down. The vertex shader projects to clip space; there
/// is no matrix anywhere in this renderer.
pub const Vertex = extern struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    comptime {
        // Budget: 8 x f32 = 32 bytes, exact.
        //
        // A7.1 -- RAISED FROM 24, DELIBERATELY, AND HERE IS THE JUSTIFICATION.
        //
        // M.2's vertex carried position and colour. M.3 adds (u, v): the point in the glyph atlas
        // this corner samples. It is not an optimisation and it is not convenience -- without it
        // there is no way to say WHICH glyph a quad draws, and there is no text.
        //
        // The same pair is what lets a rectangle and a letter share one shader and one draw call:
        // a rectangle points at the atlas's white texel. So this eight-byte increase REMOVES a
        // mode attribute and a per-fragment branch rather than adding to them.
        //
        // The predicted pressure was recorded in this comment before the field existed, at 32
        // bytes exactly. It came in at 32.
        std.debug.assert(@sizeOf(Vertex) == 32);
    }
};

/// Six vertices per quad: two triangles, no index buffer.
///
/// An index buffer would save eight bytes per quad on a list a few hundred quads long. The stop
/// rule (G3): the cost is already nothing, so the complexity buys nothing.
pub const vertices_per_quad = 6;

/// SHELL. Append the triangles for a draw list. Allocates into the caller's list (C1, C2).
///
/// The engine and the atlas are MUTABLE because a glyph the game has never drawn before is
/// rasterized and packed on first sight. After the first few frames of a screen, that stops
/// happening and this function only reads.
/// ============================================================================
/// THE DRAW LIST IS IN DP. THE SCREEN IS IN PIXELS. `scale` IS THE ONLY BRIDGE.
///
/// `ui.zig` lays out at `pad = 22`, `line = 26`, body text at 17 -- density-independent pixels,
/// the unit Android defines as one pixel at 160dpi. On a ~440dpi phone, taken literally, that body
/// text is a millimetre and a half tall. It renders perfectly. It cannot be read.
///
/// The interface is not the place to fix that. `ui.zig` is pure, integer, and has never heard of a
/// phone, and keeping it that way is worth more than the convenience of scaling it there. So the
/// conversion happens HERE, at the last moment before the pixels exist, and the core never learns
/// the density.
///
/// Glyphs are rasterized at `style.px * scale` -- the PHYSICAL size -- so the type is genuinely
/// sharp. Scaling a 17px raster up by 2.75 would be a blur, and it is the difference between text
/// that reads like a message and text that reads like a scanned fax.
pub fn build(
    draws: []const ui.Draw,
    engine: *text.Engine,
    atlas: *atlas_mod.Atlas,
    scale: f32,
    origin: Origin,
    out: *std.ArrayList(Vertex),
    gpa: Allocator,
) Error!void {
    out.clearRetainingCapacity();

    for (draws) |item| switch (item) {
        .rect => |it| {
            // A rectangle with no area is not a rectangle. It is six degenerate triangles and a
            // waste of the bus.
            if (it.w <= 0 or it.h <= 0) continue;

            // Snapped to whole pixels. A rectangle edge on a half-pixel is a rectangle with a
            // blurry grey line down one side.
            const x = px(it.x, scale) + origin.x;
            const y = px(it.y, scale) + origin.y;
            const white = atlas_mod.whiteUv();

            try pushQuad(
                out,
                gpa,
                x,
                y,
                px(it.x + it.w, scale) - px(it.x, scale),
                px(it.y + it.h, scale) - px(it.y, scale),
                // Every corner samples the SAME point. The uv is therefore constant across the
                // whole quad, so every fragment lands exactly on the white texel's centre -- no
                // interpolation, no bleeding from a neighbour, whatever the sampler is doing.
                white,
                white,
                rgba(it.color),
            );
        },

        .text => |it| try pushString(out, engine, atlas, gpa, scale, origin, it.x, it.y, it.text, it.weight, it.alignment, it.burn, rgba(it.color)),

        // A PROCEDURAL SHAPE, SAMPLED FROM THE SAME ATLAS AS THE LETTERS.
        //
        // This is the whole of the gradient support in this renderer: a quad, a tint, and a soft
        // coverage bitmap that was written into the texture at startup. A spore, a bloom, a wipe.
        // No second shader, no second pass, no gradient code.
        .sprite => |it| {
            if (it.w <= 0 or it.h <= 0) continue;

            const shape = atlas_mod.spriteRect(atlas, it.sprite);
            if (shape.w == 0) continue;

            const inv: f32 = 1.0 / @as(f32, @floatFromInt(atlas.dim));

            // HALF A TEXEL IN FROM EVERY EDGE. Sampling exactly on the boundary lets a LINEAR
            // filter reach into the gutter -- and the neighbour of a soft disc is whatever glyph
            // was packed next to it, which would ring the glow with a faint letter.
            const left = (@as(f32, @floatFromInt(shape.x)) + 0.5) * inv;
            const top = (@as(f32, @floatFromInt(shape.y)) + 0.5) * inv;
            const right = (@as(f32, @floatFromInt(shape.x + shape.w)) - 0.5) * inv;
            const bottom = (@as(f32, @floatFromInt(shape.y + shape.h)) - 0.5) * inv;

            const x = px(it.x, scale) + origin.x;
            const y = px(it.y, scale) + origin.y;
            const w = px(it.x + it.w, scale) - px(it.x, scale);
            const h = px(it.y + it.h, scale) - px(it.y, scale);

            if (it.angle == 0) {
                try pushQuad(out, gpa, x, y, w, h, .{ left, top }, .{ right, bottom }, rgba(it.color));
            } else {
                // THE SHELL TURNS THE QUAD. The core named an angle -- a 65536th of a turn -- and
                // here it becomes radians and rotates the four corners about the sprite's centre.
                // The trig lives in the shell, never the core (B6). The uv is untouched: we spin the
                // geometry the texture is stretched over, not the lookup into the texture.
                const theta = @as(f32, @floatFromInt(it.angle)) / 65536.0 * std.math.tau;
                try pushQuadRotated(out, gpa, x + w * 0.5, y + h * 0.5, w * 0.5, h * 0.5, @cos(theta), @sin(theta), .{ left, top }, .{ right, bottom }, rgba(it.color));
            }
        },
    };
}

/// One quad, rotated about its centre by (cos, sin). Same winding and uv layout as `pushQuad`; only
/// the corner positions differ, so the rotated sweep samples its atlas shape exactly as an
/// unrotated sprite would.
fn pushQuadRotated(
    out: *std.ArrayList(Vertex),
    gpa: Allocator,
    cx: f32,
    cy: f32,
    hw: f32,
    hh: f32,
    co: f32,
    si: f32,
    uv0: [2]f32,
    uv1: [2]f32,
    colour: [4]f32,
) Allocator.Error!void {
    // Local corners, clockwise from top-left, then rotated and offset to the centre.
    const lx = [4]f32{ -hw, hw, hw, -hw };
    const ly = [4]f32{ -hh, -hh, hh, hh };
    var corner: [4][2]f32 = undefined;
    for (0..4) |i| {
        corner[i] = .{ cx + lx[i] * co - ly[i] * si, cy + lx[i] * si + ly[i] * co };
    }
    const uv = [4][2]f32{ .{ uv0[0], uv0[1] }, .{ uv1[0], uv0[1] }, .{ uv1[0], uv1[1] }, .{ uv0[0], uv1[1] } };
    const order = [vertices_per_quad]usize{ 0, 1, 2, 0, 2, 3 };

    try out.ensureUnusedCapacity(gpa, vertices_per_quad);
    for (order) |i| {
        out.appendAssumeCapacity(.{
            .x = corner[i][0],
            .y = corner[i][1],
            .u = uv[i][0],
            .v = uv[i][1],
            .r = colour[0],
            .g = colour[1],
            .b = colour[2],
            .a = colour[3],
        });
    }
}

/// WHERE THE SAFE AREA STARTS, in physical pixels.
///
/// A modern phone is not a rectangle of pixels we own. There is a status bar, a gesture bar, and a
/// camera cutout. `ui.zig` is handed the SIZE of what is left and never learns it has an origin --
/// so the origin is added here, at the same moment the dp become pixels.
///
/// `{0, 0}` on a device with no insets, which is what a test uses.
pub const Origin = struct { x: f32 = 0, y: f32 = 0 };

fn countGlyphs(string: []const u8) usize {
    var n: usize = 0;
    var it = text.codepoints(string);
    while (it.next()) |_| n += 1;
    return n;
}

/// dp -> physical pixels, snapped to the grid.
fn px(dp: i32, scale: f32) f32 {
    return @round(@as(f32, @floatFromInt(dp)) * scale);
}

/// One string, one pen, left to right.
///
/// `ui.Draw.text.y` is the TOP of the line, because that is how `ui.zig` lays out -- it places
/// text at y=40, y=110, y=206 and thinks in boxes. Glyphs are positioned from a BASELINE. The
/// conversion is this one line, and it is the single easiest thing in a text renderer to get
/// wrong: every sentence lands a line-height off, it looks like a layout bug, and it is not.
fn pushString(
    out: *std.ArrayList(Vertex),
    engine: *text.Engine,
    atlas: *atlas_mod.Atlas,
    gpa: Allocator,
    scale: f32,
    origin: Origin,
    x: i32,
    y: i32,
    string: []const u8,
    weight: ui.Weight,
    alignment: ui.Align,
    burn: u8,
    colour: [4]f32,
) Error!void {
    const style = text.styleOf(weight);

    // THE GLYPHS ARE RASTERIZED AT THE PHYSICAL SIZE, not the dp size scaled up afterwards. A 17px
    // raster magnified 2.75x is a blur; a 47px raster is type. This is the entire reason the scale
    // is threaded down here rather than applied to the vertices at the end.
    const physical_px: u16 = @intFromFloat(@max(1.0, @round(@as(f32, @floatFromInt(style.px)) * scale)));

    // And the line metrics come from the size actually being drawn, or the baseline is computed
    // for a font nobody is looking at.
    const line = text.lineOf(engine, style.face, physical_px);

    // Everything from here down is in PHYSICAL pixels.
    const baseline: i32 = @as(i32, @intFromFloat(px(y, scale) + origin.y)) + line.ascent;

    // THE CORE ASKED FOR AN ALIGNMENT; THE RENDERER HAS THE FONT, SO THE RENDERER DOES THE SUM.
    // This is the only place in the system that knows how wide a sentence is.
    const width = text.measure(engine, style.face, physical_px, string);
    const anchor: i32 = @intFromFloat(px(x, scale) + origin.x);
    var pen: i32 = switch (alignment) {
        .left => anchor,
        .center => anchor - @divTrunc(width, 2),
        .right => anchor - width,
    };

    // ============================================================================
    // THE BURN. The renderer stages it, because the renderer is the only thing that knows where
    // the second letter begins.
    //
    // Each letter has its own window: it starts igniting a little after the one to its left, and
    // takes a moment to arrive. While it is arriving it is HOT -- brighter than its final colour,
    // the way something that is catching light is brighter than something that has caught -- and it
    // cools to red as it settles.
    //
    // The last letter must be fully lit by the time the burn reaches 255, so the stagger is derived
    // from the length of the string rather than being a magic number that only suits eight letters.
    const glyphs: f32 = @floatFromInt(@max(1, countGlyphs(string)));
    const progress: f32 = @as(f32, @floatFromInt(burn)) / 255.0;
    const dwell: f32 = 0.45; // how long one letter takes to arrive, as a fraction of the whole
    const stagger: f32 = (1.0 - dwell) / glyphs;

    var index: f32 = 0;

    var it = text.codepoints(string);
    while (it.next()) |codepoint| {
        const glyph = try atlas_mod.ensure(atlas, engine, gpa, style.face, physical_px, codepoint);

        // How lit is THIS letter, right now?
        const began = index * stagger;
        const lit: f32 = std.math.clamp((progress - began) / dwell, 0.0, 1.0);
        index += 1;

        // A space. It moves the pen and puts no ink on the page (E4).
        if (glyph.w > 0 and glyph.h > 0 and lit > 0.0) {
            // `bear_y` is the top of the bitmap relative to the baseline, y DOWN -- so it is
            // normally negative and this SUBTRACTS from the baseline. Adding it here would draw
            // every line of text below where it belongs.
            const gx: f32 = @floatFromInt(pen + glyph.bear_x);
            const gy: f32 = @floatFromInt(baseline + glyph.bear_y);

            const inv: f32 = 1.0 / @as(f32, @floatFromInt(atlas.dim));
            const left: f32 = @as(f32, @floatFromInt(glyph.x)) * inv;
            const top: f32 = @as(f32, @floatFromInt(glyph.y)) * inv;
            const right: f32 = @as(f32, @floatFromInt(glyph.x + glyph.w)) * inv;
            const bottom: f32 = @as(f32, @floatFromInt(glyph.y + glyph.h)) * inv;

            // Hot while it is arriving, its own colour once it has. The overshoot is what makes it
            // read as IGNITING rather than fading in -- a letter that merely fades looks like a
            // slow label; a letter that flares and cools looks like it caught fire.
            const heat = 1.0 + (1.0 - lit) * 1.4;
            const burning: [4]f32 = .{
                @min(1.0, colour[0] * heat),
                @min(1.0, colour[1] * heat + (1.0 - lit) * 0.35),
                @min(1.0, colour[2] * heat + (1.0 - lit) * 0.30),
                colour[3] * lit,
            };

            try pushQuad(
                out,
                gpa,
                gx,
                gy,
                @floatFromInt(glyph.w),
                @floatFromInt(glyph.h),
                .{ left, top },
                .{ right, bottom },
                if (burn == 255) colour else burning,
            );
        }

        pen += glyph.advance;
    }
}

/// One quad. `uv0` is the top-left of the source rectangle, `uv1` the bottom-right; pass the same
/// point for both to sample a single texel across the whole quad.
fn pushQuad(
    out: *std.ArrayList(Vertex),
    gpa: Allocator,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    uv0: [2]f32,
    uv1: [2]f32,
    colour: [4]f32,
) Allocator.Error!void {
    // Clockwise from the top-left, because the projection is y-down. Two triangles: 0-1-2, 0-2-3.
    const corner = [4][2]f32{
        .{ x, y },
        .{ x + w, y },
        .{ x + w, y + h },
        .{ x, y + h },
    };
    const uv = [4][2]f32{
        .{ uv0[0], uv0[1] },
        .{ uv1[0], uv0[1] },
        .{ uv1[0], uv1[1] },
        .{ uv0[0], uv1[1] },
    };

    const order = [vertices_per_quad]usize{ 0, 1, 2, 0, 2, 3 };

    try out.ensureUnusedCapacity(gpa, vertices_per_quad);
    for (order) |i| {
        out.appendAssumeCapacity(.{
            .x = corner[i][0],
            .y = corner[i][1],
            .u = uv[i][0],
            .v = uv[i][1],
            .r = colour[0],
            .g = colour[1],
            .b = colour[2],
            .a = colour[3],
        });
    }
}

/// A `ui.Color` is `0xRRGGBBAA`. THE ALPHA IS LAST.
///
/// Worth a sentence because the obvious mistake does not crash, does not fail to compile, and does
/// not look wrong in a diff -- it paints the wrong colour on a phone you are not holding. The prior
/// art this was ported from packs `0xAARRGGBB`, the other way round. `void_black = 0x08080AFF` is a
/// nearly-black with FULL alpha, and it is only nearly-black if it is unpacked in this order.
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

/// Everything a test needs to rasterise a screen, with no GPU anywhere.
const Rig = struct {
    engine: text.Engine,
    atlas: atlas_mod.Atlas,
    draws: std.ArrayList(ui.Draw),
    verts: std.ArrayList(Vertex),
    /// 1:1 by default -- dp and pixels coincide, so a test asserting "x is 10" still means it.
    /// The scaling tests set this explicitly.
    scale: f32 = 1.0,

    fn init(gpa: Allocator) !Rig {
        return .{
            .engine = try text.init(gpa),
            .atlas = try atlas_mod.init(gpa),
            .draws = .empty,
            .verts = .empty,
        };
    }

    fn deinit(rig: *Rig, gpa: Allocator) void {
        text.deinit(&rig.engine, gpa);
        atlas_mod.deinit(&rig.atlas, gpa);
        rig.draws.deinit(gpa);
        rig.verts.deinit(gpa);
    }

    fn rasterise(rig: *Rig, gpa: Allocator, state: ui.State, size: ui.Size) !void {
        try ui.draw(state, size, .{}, &rig.draws, gpa);
        try build(rig.draws.items, &rig.engine, &rig.atlas, rig.scale, .{}, &rig.verts, gpa);
    }
};

test "0xRRGGBBAA: the alpha is last, and getting this backwards is invisible until it is on a phone" {
    const black = rgba(.void_black);
    try testing.expectApproxEqAbs(@as(f32, 8.0 / 255.0), black[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 8.0 / 255.0), black[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10.0 / 255.0), black[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), black[3], 0.001); // FULL alpha. Not 0.03.

    for ([_]ui.Color{ .void_black, .carrion, .ash, .bone, .smoke, .dust, .grave, .wound, .clot, .scab, .serum }) |colour| {
        try testing.expectApproxEqAbs(@as(f32, 1.0), rgba(colour)[3], 0.001);
    }
}

test "a rectangle is six vertices, wound clockwise, sampling the white texel at every corner" {
    const gpa = testing.allocator;

    var rig = try Rig.init(gpa);
    defer rig.deinit(gpa);

    const draws = [_]ui.Draw{
        .{ .rect = .{ .x = 10, .y = 20, .w = 30, .h = 40, .color = .bone } },
    };
    try build(&draws, &rig.engine, &rig.atlas, rig.scale, .{}, &rig.verts, gpa);

    try testing.expectEqual(@as(usize, 6), rig.verts.items.len);

    try testing.expectEqual(@as(f32, 10), rig.verts.items[0].x);
    try testing.expectEqual(@as(f32, 20), rig.verts.items[0].y);
    try testing.expectEqual(@as(f32, 40), rig.verts.items[2].x);
    try testing.expectEqual(@as(f32, 60), rig.verts.items[2].y);

    // EVERY corner samples the identical point. If these ever differ, the uv interpolates across
    // the quad, wanders off the white texel, and every solid colour on the screen gets a gradient
    // of whatever glyph happens to be packed next door.
    const white = atlas_mod.whiteUv();
    for (rig.verts.items) |vertex| {
        try testing.expectEqual(white[0], vertex.u);
        try testing.expectEqual(white[1], vertex.v);
    }
}

test "a string becomes one quad per inked glyph, and spaces are not quads" {
    const gpa = testing.allocator;

    var rig = try Rig.init(gpa);
    defer rig.deinit(gpa);

    const draws = [_]ui.Draw{
        .{ .text = .{ .x = 0, .y = 0, .text = "AB", .color = .bone, .weight = .body } },
    };
    try build(&draws, &rig.engine, &rig.atlas, rig.scale, .{}, &rig.verts, gpa);
    try testing.expectEqual(@as(usize, 2 * vertices_per_quad), rig.verts.items.len);

    // A space advances the pen and emits nothing. "A B" is three characters and still two quads.
    const spaced = [_]ui.Draw{
        .{ .text = .{ .x = 0, .y = 0, .text = "A B", .color = .bone, .weight = .body } },
    };
    try build(&spaced, &rig.engine, &rig.atlas, rig.scale, .{}, &rig.verts, gpa);
    try testing.expectEqual(@as(usize, 2 * vertices_per_quad), rig.verts.items.len);
}

test "text advances to the right, and the pen does not run backwards" {
    const gpa = testing.allocator;

    var rig = try Rig.init(gpa);
    defer rig.deinit(gpa);

    const draws = [_]ui.Draw{
        .{ .text = .{ .x = 100, .y = 50, .text = "Hi", .color = .bone, .weight = .body } },
    };
    try build(&draws, &rig.engine, &rig.atlas, rig.scale, .{}, &rig.verts, gpa);

    // First glyph starts at or near the requested x; the second is to the RIGHT of the first.
    const first_x = rig.verts.items[0].x;
    const second_x = rig.verts.items[vertices_per_quad].x;
    try testing.expect(second_x > first_x);
    try testing.expect(first_x >= 100 - 4); // bear_x can nudge left a hair, never a lot
}

test "THE BASELINE: text sits inside the line box it was given, not below it" {
    // The single easiest thing in a text renderer to get wrong. `ui.zig` hands a TOP edge; glyphs
    // are placed from a BASELINE. Get the sign of bear_y wrong, or forget the ascent, and every
    // sentence in the game renders one line-height too low. It looks exactly like a layout bug and
    // it is not one -- and nobody notices until it is on a phone, in a cafe, in front of a player.
    const gpa = testing.allocator;

    var rig = try Rig.init(gpa);
    defer rig.deinit(gpa);

    const top: i32 = 200;
    const draws = [_]ui.Draw{
        .{ .text = .{ .x = 0, .y = top, .text = "Hxg", .color = .bone, .weight = .body } },
    };
    try build(&draws, &rig.engine, &rig.atlas, rig.scale, .{}, &rig.verts, gpa);

    const style = text.styleOf(.body);
    const line = text.lineOf(&rig.engine, style.face, style.px);

    var highest: f32 = 1e9;
    var lowest: f32 = -1e9;
    for (rig.verts.items) |vertex| {
        highest = @min(highest, vertex.y);
        lowest = @max(lowest, vertex.y);
    }

    // Nothing pokes out above the top of the line box. The cap of the 'H' may touch it.
    try testing.expect(highest >= @as(f32, @floatFromInt(top)));

    // And nothing falls below the bottom of it -- 'g' has a descender, and it must fit.
    const bottom: f32 = @floatFromInt(top + line.height);
    try testing.expect(lowest <= bottom);

    // The text is actually in the box, not collapsed to a point at the top of it.
    try testing.expect(lowest > @as(f32, @floatFromInt(top)));
}

test "DENSITY: the same layout is physically the same size on a cheap phone and a flagship" {
    // THE BUG THIS EXISTS TO PREVENT, AND IT IS NOT A CRASH.
    //
    // `ui.zig` lays out in dp -- pad 22, body text 17. Taken as physical pixels on a ~440dpi phone,
    // that body text is about a millimetre and a half tall. It renders PERFECTLY. Every test passes.
    // Every rectangle is where it should be. And no human being can read a word of it.
    //
    // No assertion in this codebase catches "too small to read", so this one catches the thing
    // underneath it: at 3x density, everything must be three times as many pixels.
    const gpa = testing.allocator;

    var rig = try Rig.init(gpa);
    defer rig.deinit(gpa);

    const draws = [_]ui.Draw{
        .{ .rect = .{ .x = 10, .y = 20, .w = 30, .h = 40, .color = .bone } },
    };

    rig.scale = 1.0;
    try build(&draws, &rig.engine, &rig.atlas, rig.scale, .{}, &rig.verts, gpa);
    const mdpi_x = rig.verts.items[0].x;
    const mdpi_w = rig.verts.items[2].x - rig.verts.items[0].x;

    var big: std.ArrayList(Vertex) = .empty;
    defer big.deinit(gpa);

    try build(&draws, &rig.engine, &rig.atlas, 3.0, .{}, &big, gpa);
    const xxhdpi_x = big.items[0].x;
    const xxhdpi_w = big.items[2].x - big.items[0].x;

    // Three times the density, three times the pixels -- so the SAME PHYSICAL SIZE in the hand.
    try testing.expectApproxEqAbs(mdpi_x * 3.0, xxhdpi_x, 0.001);
    try testing.expectApproxEqAbs(mdpi_w * 3.0, xxhdpi_w, 0.001);
}

test "DENSITY: the type is rasterized at the physical size, not magnified from a small one" {
    // The difference between text that reads like a message and text that reads like a fax.
    //
    // A 17px glyph blown up 3x is a blur with the same 17px of detail in it. A 51px glyph is type.
    // So at 3x density the GLYPH ITSELF must be bigger in the atlas -- not just its quad.
    const gpa = testing.allocator;

    var rig = try Rig.init(gpa);
    defer rig.deinit(gpa);

    const style = text.styleOf(.body);

    const small = try atlas_mod.ensure(&rig.atlas, &rig.engine, gpa, style.face, style.px, 'H');
    const large = try atlas_mod.ensure(&rig.atlas, &rig.engine, gpa, style.face, style.px * 3, 'H');

    // Not the same rectangle scaled -- a genuinely larger raster, with more ink in it.
    try testing.expect(large.h > small.h * 2);
    try testing.expect(large.w > small.w * 2);

    // And the renderer asks for the big one when the density is high. Same draw, two densities:
    // the quads must differ in size, which can only happen if the glyph did.
    const draws = [_]ui.Draw{
        .{ .text = .{ .x = 0, .y = 0, .text = "H", .color = .bone, .weight = .body } },
    };

    try build(&draws, &rig.engine, &rig.atlas, 1.0, .{}, &rig.verts, gpa);
    const small_h = rig.verts.items[2].y - rig.verts.items[0].y;

    var big: std.ArrayList(Vertex) = .empty;
    defer big.deinit(gpa);

    try build(&draws, &rig.engine, &rig.atlas, 3.0, .{}, &big, gpa);
    const large_h = big.items[2].y - big.items[0].y;

    try testing.expect(large_h > small_h * 2.0);
}

test "DENSITY: a touch in physical pixels finds the button that was laid out in dp" {
    // The other half, and the half that makes the game look BROKEN rather than merely small: the
    // touch arrives in physical pixels and the buttons were placed in dp. Forget to divide, and on
    // a 3x phone every tap lands three times too far down -- the Confirm button does nothing, and
    // the game appears not to respond to touch at all.
    //
    // `android.zig` does the division. This pins the arithmetic it relies on.
    const size_physical: ui.Size = .{ .w = 1080, .h = 2400 };
    const scale: f32 = 3.0;

    const size_dp: ui.Size = .{
        .w = @intFromFloat(@round(@as(f32, @floatFromInt(size_physical.w)) / scale)),
        .h = @intFromFloat(@round(@as(f32, @floatFromInt(size_physical.h)) / scale)),
    };
    try testing.expectEqual(@as(i32, 360), size_dp.w);
    try testing.expectEqual(@as(i32, 800), size_dp.h);

    // A player taps the middle of the Confirm button. `ui.zig` decides where that is, in dp.
    var state: ui.State = .{ .screen = .choose_side };
    state = ui.touch(state, .{ .x = 60, .y = 300 }, size_dp); // a faction card
    try testing.expect(state.hovering != null);

    // Now the same tap as the OS delivers it -- in physical pixels -- divided back into dp. It must
    // land on the same thing. If the division were missing, y would be 900 in a screen 800 tall.
    const physical_x: i32 = 60 * 3;
    const physical_y: i32 = 300 * 3;

    const back_to_dp: ui.Touch = .{
        .x = @intFromFloat(@round(@as(f32, @floatFromInt(physical_x)) / scale)),
        .y = @intFromFloat(@round(@as(f32, @floatFromInt(physical_y)) / scale)),
    };

    var same: ui.State = .{ .screen = .choose_side };
    same = ui.touch(same, back_to_dp, size_dp);
    try testing.expectEqual(state.hovering, same.hovering);
    try testing.expect(same.hovering != null);
}

test "THE SHAPE OF THE SCREEN IS NOT A HEADCOUNT: six people and six thousand draw the same pixels" {
    // I5, at the glass.
    //
    // `ui.zig` proves no SENTENCE contains a digit. That guards the words. This guards the
    // GEOMETRY, which nothing else does -- and geometry is the easier place to leak, because a leak
    // there does not look like a number. It looks like design.
    //
    // The feature this forbids will be requested, in good faith, by someone reasonable: a crowd
    // meter, a little bar that fills as the room gets busier. It would be beautiful. It would also
    // be an analogue readout of how many real people are in a room -- sit in a cafe, watch the bar
    // twitch down, look up at whoever just stood to leave.
    //
    // Now that text renders, this covers the words too: the SENTENCE differs between crowd bands
    // ("You are not alone" vs "You are surrounded by thousands"), so the vertex COUNT differs. What
    // must not differ is anything else -- so the comparison is on the rectangles, which are the
    // part a player could measure with a ruler and read a number out of.
    const gpa = testing.allocator;
    const size: ui.Size = .{ .w = 1080, .h = 2400 };

    var rig = try Rig.init(gpa);
    defer rig.deinit(gpa);

    const start: ui.State = .{ .screen = .quiet, .faction = .human };

    var few_rects: std.ArrayList(Vertex) = .empty;
    defer few_rects.deinit(gpa);

    try rig.rasterise(gpa, ui.told(start, 60, 4, 900, 12, .even, .a_few), size);
    for (rig.draws.items, 0..) |item, i| {
        _ = i;
        if (item != .rect) continue;
    }
    // Collect the rect vertices only -- rebuild from the draw list so text is excluded.
    try collectRects(&few_rects, rig.draws.items, &rig.engine, &rig.atlas, gpa);

    var many_rects: std.ArrayList(Vertex) = .empty;
    defer many_rects.deinit(gpa);

    try rig.rasterise(gpa, ui.told(start, 60, 4, 900, 12, .even, .thousands), size);
    try collectRects(&many_rects, rig.draws.items, &rig.engine, &rig.atlas, gpa);

    // Not similar. IDENTICAL, to the last float.
    try testing.expectEqualSlices(Vertex, few_rects.items, many_rects.items);
    try testing.expect(few_rects.items.len > vertices_per_quad);
}

fn collectRects(
    out: *std.ArrayList(Vertex),
    draws: []const ui.Draw,
    engine: *text.Engine,
    atlas: *atlas_mod.Atlas,
    gpa: Allocator,
) !void {
    var only_rects: std.ArrayList(ui.Draw) = .empty;
    defer only_rects.deinit(gpa);

    for (draws) |item| {
        if (item == .rect) try only_rects.append(gpa, item);
    }
    try build(only_rects.items, engine, atlas, 1.0, .{}, out, gpa);
}

test "the real screens rasterise, the background is first, and every screen has words on it" {
    const gpa = testing.allocator;

    var rig = try Rig.init(gpa);
    defer rig.deinit(gpa);

    const size: ui.Size = .{ .w = 1080, .h = 2400 };

    for ([_]ui.State{
        .{ .screen = .choose_side },
        .{ .screen = .quiet, .faction = .human },
        .{ .screen = .live, .faction = .zombie, .hp = 40, .crowd = .dozens, .momentum = .zombies_winning },
    }) |state| {
        try rig.rasterise(gpa, state, size);

        // The background is the first rect ui.draw emits, so the first six vertices -- and it must
        // cover the whole surface, or the phone shows whatever the compositor last left there.
        try testing.expectEqual(@as(f32, 0), rig.verts.items[0].x);
        try testing.expectEqual(@as(f32, 0), rig.verts.items[0].y);
        try testing.expectEqual(@as(f32, 1080), rig.verts.items[2].x);
        try testing.expectEqual(@as(f32, 2400), rig.verts.items[2].y);
        try testing.expectApproxEqAbs(@as(f32, 1.0), rig.verts.items[0].a, 0.001);

        // A whole number of quads, always.
        try testing.expectEqual(@as(usize, 0), rig.verts.items.len % vertices_per_quad);

        // AND THERE ARE WORDS. Before M.3 this screen was rectangles and silence -- the game was
        // on the glass but it could not speak. Every screen has more quads than it has rects,
        // which is only true if glyphs are being emitted.
        var rects: usize = 0;
        for (rig.draws.items) |item| {
            if (item == .rect) rects += 1;
        }
        const quads = rig.verts.items.len / vertices_per_quad;
        try testing.expect(quads > rects);
    }
}

test "a rotated sprite turns the quad: a wide beam becomes tall at a quarter turn" {
    // The renderer rotation the smooth sonar sweep depends on. The core cannot turn a quad (no
    // floats, B6); the shell does, and this pins the arithmetic. A 40x10 sprite rotated a quarter
    // turn about its centre must come out ~10 wide and ~40 tall -- width and height swapped.
    const gpa = testing.allocator;

    var rig = try Rig.init(gpa);
    defer rig.deinit(gpa);

    const bbox = struct {
        fn wh(v: []const Vertex) [2]f32 {
            var minx: f32 = 1e9;
            var miny: f32 = 1e9;
            var maxx: f32 = -1e9;
            var maxy: f32 = -1e9;
            for (v) |vt| {
                minx = @min(minx, vt.x);
                miny = @min(miny, vt.y);
                maxx = @max(maxx, vt.x);
                maxy = @max(maxy, vt.y);
            }
            return .{ maxx - minx, maxy - miny };
        }
    }.wh;

    const flat = [_]ui.Draw{.{ .sprite = .{ .x = 0, .y = 0, .w = 40, .h = 10, .color = .bone, .sprite = .beam } }};
    try build(&flat, &rig.engine, &rig.atlas, 1.0, .{}, &rig.verts, gpa);
    const unrotated = bbox(rig.verts.items);

    var rot: std.ArrayList(Vertex) = .empty;
    defer rot.deinit(gpa);
    const turned = [_]ui.Draw{.{ .sprite = .{ .x = 0, .y = 0, .w = 40, .h = 10, .color = .bone, .sprite = .beam, .angle = 16384 } }};
    try build(&turned, &rig.engine, &rig.atlas, 1.0, .{}, &rot, gpa);
    const rotated = bbox(rot.items);

    try testing.expectEqual(@as(usize, vertices_per_quad), rot.items.len);
    // A quarter turn swaps the extents.
    try testing.expectApproxEqAbs(unrotated[0], rotated[1], 1.0);
    try testing.expectApproxEqAbs(unrotated[1], rotated[0], 1.0);
    // And it is genuinely turned, not merely the same box: the rotated width is much less than flat.
    try testing.expect(rotated[0] < unrotated[0] - 5.0);
}

test "angle zero takes the fast axis-aligned path, unchanged from a plain sprite" {
    const gpa = testing.allocator;

    var rig = try Rig.init(gpa);
    defer rig.deinit(gpa);

    const a = [_]ui.Draw{.{ .sprite = .{ .x = 5, .y = 7, .w = 30, .h = 20, .color = .bone, .sprite = .disc } }};
    try build(&a, &rig.engine, &rig.atlas, 1.0, .{}, &rig.verts, gpa);

    var b: std.ArrayList(Vertex) = .empty;
    defer b.deinit(gpa);
    const c = [_]ui.Draw{.{ .sprite = .{ .x = 5, .y = 7, .w = 30, .h = 20, .color = .bone, .sprite = .disc, .angle = 0 } }};
    try build(&c, &rig.engine, &rig.atlas, 1.0, .{}, &b, gpa);

    try testing.expectEqualSlices(Vertex, rig.verts.items, b.items);
}
