//! SHELL (B1, B3). The desktop host.
//!
//! An SDL3 window and a DVUI frame loop around the pure interface in `ui.zig`: the core hands
//! back a list of things to draw, and the player's presses go in as plain integer pixels.
//! Iteration happens on a laptop, not a phone (CURRENT.md).
//!
//! F1 justification — DVUI is a sanctioned dependency, recorded here at the import site:
//! what it does is immediate-mode widgets, text, input, and rendering over SDL. We do not write
//! it ourselves because a GUI toolkit is precisely the thing the WebView was, badly; this file
//! replaces a browser engine with a Zig library. Cost to remove: delete the dep, this file, and
//! its guard.zig registration. The core never imports it (D7).

const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");
const ui = @import("ui.zig");

const icon_png = @embedFile("icon_png");

var state: ui.State = .{};
var backend: SDLBackend = undefined;
var win: dvui.Window = undefined;
var fonts_ready = false;
var io: std.Io = undefined;

/// Desktop iteration aid: `--shot=path.png --ms=N` renders the frame at N milliseconds since
/// open into a PNG and exits. The whole animation is a pure function of the millisecond, so the
/// screenshot is the test (ui.zig, boot_ms).
var shot_path: ?[]const u8 = null;
var shot_ms: u32 = 12_000;
var shot_done = false;
var dump_ops = false;
var only_op: ?[]const u8 = null;

/// The four procedural sprites, baked once at startup. Same coverage functions the GLES atlas
/// baked — recovered verbatim from git history (first-party code, no dependency).
var sprites: [@typeInfo(ui.Sprite).@"enum".fields.len]dvui.Texture = undefined;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--shot=")) shot_path = arg["--shot=".len..];
        if (std.mem.startsWith(u8, arg, "--ms=")) shot_ms = try std.fmt.parseInt(u32, arg["--ms=".len..], 10);
        if (std.mem.eql(u8, arg, "--dump")) dump_ops = true;
        if (std.mem.startsWith(u8, arg, "--only=")) only_op = arg["--only=".len..];
    }

    SDLBackend.enableSDLLogging();

    backend = try SDLBackend.initWindow(.{
        .io = init.io,
        .environ_map = init.environ_map,
        .allocator = init.gpa,
        .size = .{ .w = 430, .h = 860 },
        .min_size = .{ .w = 320, .h = 560 },
        .vsync = true,
        .title = "Outbreak",
        .icon = icon_png,
    });
    defer backend.deinit();

    win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .theme = dvui.Theme.builtin.adwaita_dark,
    });
    defer win.deinit();

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();

    var interrupted = false;
    main_loop: while (true) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);
        _ = arena_state.reset(.{ .retain_with_limit = 1 << 20 });

        if (!fonts_ready) {
            try registerFonts();
            try bakeSprites();
            fonts_ready = true;
        }

        try backend.addAllEvents(&win);

        _ = SDLBackend.c.SDL_SetRenderDrawColor(backend.renderer, 8, 8, 10, 255);
        _ = SDLBackend.c.SDL_RenderClear(backend.renderer);

        if (!frame(arena_state.allocator())) break :main_loop;

        const end_micros = try win.end(.{});
        try backend.setCursor(win.cursorRequested());
        try backend.textInputRect(win.textInputRequested());
        try backend.renderPresent();

        if (shot_path != null and !shot_done and
            SDLBackend.c.SDL_GetTicks() >= shot_ms)
        {
            writeShot(shot_path.?);
            shot_done = true;
            break :main_loop;
        }

        interrupted = try backend.waitEventTimeout(win.waitTime(end_micros));
    }
}

/// Read back the presented frame -- what a player actually sees, not a re-render.
fn writeShot(path: []const u8) void {
    const c = SDLBackend.c;
    const surface = c.SDL_RenderReadPixels(backend.renderer, null) orelse {
        dvui.log.err("--shot: SDL_RenderReadPixels failed", .{});
        return;
    };
    defer c.SDL_DestroySurface(surface);
    const rgba = c.SDL_ConvertSurface(surface, c.SDL_PIXELFORMAT_RGBA32) orelse surface;
    defer if (rgba != surface) c.SDL_DestroySurface(rgba);

    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        dvui.log.err("--shot could not create {s}: {any}", .{ path, err });
        return;
    };
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var w = file.writer(io, &buf);
    const surf: *c.SDL_Surface = @ptrCast(rgba);
    const pixels: [*]u8 = @ptrCast(surf.pixels);
    dvui.PNGEncoder.writeWithResolution(&w.interface, pixels[0..@intCast(surf.w * surf.h * 4)], @intCast(surf.w), @intCast(surf.h), 2835) catch |err| {
        dvui.log.err("--shot could not encode {s}: {any}", .{ path, err });
    };
    w.interface.flush() catch {};
}

fn registerFonts() !void {
    try dvui.addFont("Inter", @embedFile("font_body"), null);
    try dvui.addFont("Oxanium SemiBold", @embedFile("font_label"), null);
    try dvui.addFont("Oxanium Bold", @embedFile("font_heading"), null);
    try dvui.addFont("Oxanium ExtraBold", @embedFile("font_alarm"), null);
}

fn frame(arena: std.mem.Allocator) bool {
    const rs = win.rectScale();
    const s = rs.s;
    const size: ui.Size = .{
        .w = @intFromFloat(@round(rs.r.w / s)),
        .h = @intFromFloat(@round(rs.r.h / s)),
    };

    const ms: u32 = @intCast(SDLBackend.c.SDL_GetTicks());
    state = ui.advance(state, ms);

    for (dvui.events()) |*e| {
        switch (e.evt) {
            .mouse => |m| {
                const at: ui.Touch = .{
                    .x = @intFromFloat(@round(m.p.x / s)),
                    .y = @intFromFloat(@round(m.p.y / s)),
                };
                switch (m.action) {
                    .press => if (m.button == .left) {
                        state = ui.press(state, at, size);
                    },
                    .release => if (m.button == .left) {
                        state = ui.touch(state, at, size);
                    },
                    else => {},
                }
            },
            .window => |w| if (w.action == .close) return false,
            .app => |a| if (a.action == .quit) return false,
            else => {},
        }
    }

    var out: std.ArrayList(ui.Draw) = .empty;
    ui.draw(state, size, .{}, &out, arena) catch return true;
    for (out.items) |op| drawOp(op, s);

    // The instrument animates every frame; never let the loop sleep.
    dvui.refresh(null, @src(), null);
    return true;
}

fn drawOp(op: ui.Draw, s: f32) void {
    if (only_op) |only| if (!std.mem.eql(u8, @tagName(op), only)) return;
    if (dump_ops) switch (op) {
        .rect => |r| std.debug.print("  rect {d},{d} {d}x{d} #{x:0>8}\n", .{ r.x, r.y, r.w, r.h, @intFromEnum(r.color) }),
        .text => |t| std.debug.print("  text {d},{d} burn={d} #{x:0>8} \"{s}\"\n", .{ t.x, t.y, t.burn, @intFromEnum(t.color), t.text }),
        .sprite => |sp| std.debug.print("  sprite {s} {d},{d} {d}x{d} a={d} #{x:0>8}\n", .{ @tagName(sp.sprite), sp.x, sp.y, sp.w, sp.h, sp.angle, @intFromEnum(sp.color) }),
    };
    switch (op) {
        .rect => |r| {
            var b = dvui.Path.Builder.init(dvui.currentWindow().arena());
            defer b.deinit();
            b.addRect(.{
                .x = @as(f32, @floatFromInt(r.x)) * s,
                .y = @as(f32, @floatFromInt(r.y)) * s,
                .w = @as(f32, @floatFromInt(r.w)) * s,
                .h = @as(f32, @floatFromInt(r.h)) * s,
            }, .{});
            b.build().fillConvex(.{ .color = toColor(r.color) });
        },
        .sprite => |sp| {
            dvui.renderTexture(sprites[@intFromEnum(sp.sprite)], .{
                .r = .{
                    .x = @as(f32, @floatFromInt(sp.x)) * s,
                    .y = @as(f32, @floatFromInt(sp.y)) * s,
                    .w = @as(f32, @floatFromInt(sp.w)) * s,
                    .h = @as(f32, @floatFromInt(sp.h)) * s,
                },
                .s = s,
            }, .{
                .rotation = @as(f32, @floatFromInt(sp.angle)) * (std.math.tau / 65536.0),
                .colormod = toColor(sp.color),
            }) catch {};
        },
        .text => |t| drawText(t, s),
    }
}

fn drawText(t: anytype, s: f32) void {
    const font = fontFor(t.weight);
    const measured = font.textSize(t.text);

    var x: f32 = @as(f32, @floatFromInt(t.x)) * s;
    switch (t.alignment) {
        .left => {},
        .center => x -= measured.w * s / 2.0,
        .right => x -= measured.w * s,
    }

    // Burn-in: the core cannot measure a string, so it says how far through arriving the line is
    // and we clip at that fraction of the measured width. Hot-edge glow is polish for later.
    const clip_w = measured.w * s * @as(f32, @floatFromInt(t.burn)) / 255.0;
    const clip = dvui.Rect.Physical{ .x = 0, .y = 0, .w = x + clip_w, .h = win.rectScale().r.h };

    dvui.renderText(.{
        .font = font,
        .text = t.text,
        .rs = .{ .r = clip, .s = s },
        .p = .{ .x = x, .y = @as(f32, @floatFromInt(t.y)) * s },
        .color = toColor(t.color),
    }) catch {};
}

fn fontFor(weight: ui.Weight) dvui.Font {
    return switch (weight) {
        .label => dvui.Font.find(.{ .family = "Oxanium SemiBold", .size = 13 }),
        .body => dvui.Font.find(.{ .family = "Inter", .size = 17 }),
        .heading => dvui.Font.find(.{ .family = "Oxanium Bold", .size = 22 }),
        .alarm => dvui.Font.find(.{ .family = "Oxanium ExtraBold", .size = 22 }),
        .wordmark => dvui.Font.find(.{ .family = "Oxanium ExtraBold", .size = 64 }),
    };
}

/// ui.Color packs RGBA into a u32, R in the top byte.
fn toColor(c: ui.Color) dvui.Color {
    const v = @intFromEnum(c);
    return .{
        .r = @intCast((v >> 24) & 0xff),
        .g = @intCast((v >> 16) & 0xff),
        .b = @intCast((v >> 8) & 0xff),
        .a = @intCast(v & 0xff),
    };
}

fn bakeSprites() !void {
    sprites[@intFromEnum(ui.Sprite.disc)] = try bake(64, discCoverage);
    sprites[@intFromEnum(ui.Sprite.vignette)] = try bake(128, vignetteCoverage);
    sprites[@intFromEnum(ui.Sprite.ring)] = try bake(128, annulusCoverage);
    sprites[@intFromEnum(ui.Sprite.beam)] = try bake(128, beamCoverage);
}

fn bake(dim: u32, comptime coverage: fn (f32, f32) u8) !dvui.Texture {
    var pixels: [128 * 128 * 4]u8 = undefined;
    const half: f32 = @as(f32, @floatFromInt(dim)) / 2.0;
    var row: u32 = 0;
    while (row < dim) : (row += 1) {
        var col: u32 = 0;
        while (col < dim) : (col += 1) {
            const dx = (@as(f32, @floatFromInt(col)) + 0.5 - half) / half;
            const dy = (@as(f32, @floatFromInt(row)) + 0.5 - half) / half;
            const a = coverage(dx, dy);
            const i = (row * dim + col) * 4;
            // Premultiplied: DVUI blends PMA, so the coverage lives in all four channels.
            pixels[i] = a;
            pixels[i + 1] = a;
            pixels[i + 2] = a;
            pixels[i + 3] = a;
        }
    }
    // Not backend.textureCreate: that route goes through SDL_CreateTextureFromSurface, which
    // flattens alpha and turns every sprite's transparent rim into an opaque square.
    const c = SDLBackend.c;
    const tex = c.SDL_CreateTexture(backend.renderer, c.SDL_PIXELFORMAT_RGBA32, c.SDL_TEXTUREACCESS_STATIC, @intCast(dim), @intCast(dim)) orelse {
        dvui.log.err("sprite bake: SDL_CreateTexture failed: {s}", .{c.SDL_GetError()});
        return error.TextureCreate;
    };
    errdefer c.SDL_DestroyTexture(tex);
    if (!c.SDL_UpdateTexture(tex, null, &pixels, @intCast(dim * 4)))
        dvui.log.err("sprite bake: SDL_UpdateTexture failed: {s}", .{c.SDL_GetError()});
    _ = c.SDL_SetTextureScaleMode(tex, c.SDL_SCALEMODE_LINEAR);
    const pma = c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD);
    if (!c.SDL_SetTextureBlendMode(tex, pma))
        dvui.log.err("sprite bake: SDL_SetTextureBlendMode failed: {s}", .{c.SDL_GetError()});
    return dvui.Texture{ .ptr = tex, .width = dim, .height = dim, .format = .rgba_32 };
}

// The four coverage functions, recovered verbatim from the deleted render/atlas.zig.

fn discCoverage(dx: f32, dy: f32) u8 {
    const r = @sqrt(dx * dx + dy * dy);
    if (r >= 1.0) return 0;
    const t = 1.0 - r;
    const smooth = t * t * (3.0 - 2.0 * t);
    return @intFromFloat(@round(smooth * 255.0));
}

fn vignetteCoverage(dx: f32, dy: f32) u8 {
    const r = @sqrt(dx * dx + dy * dy);
    if (r >= 1.0) return 255;
    const smooth = r * r * (3.0 - 2.0 * r);
    return @intFromFloat(@round(smooth * 255.0));
}

fn annulusCoverage(dx: f32, dy: f32) u8 {
    const r = @sqrt(dx * dx + dy * dy);
    const r0: f32 = 0.92;
    const half_w: f32 = 0.09;
    const d = @abs(r - r0);
    if (d >= half_w) return 0;
    const t = 1.0 - d / half_w;
    const smooth = t * t * (3.0 - 2.0 * t);
    return @intFromFloat(@round(smooth * 255.0));
}

fn beamCoverage(dx: f32, dy: f32) u8 {
    const r = @sqrt(dx * dx + dy * dy);
    if (r >= 1.0 or r < 0.06) return 0;

    const ang = std.math.atan2(dy, dx); // -pi .. pi
    const lead: f32 = 0.05;
    const wake: f32 = 2.1;
    if (ang > lead or ang < -wake) return 0;

    const along = if (ang >= 0.0) 1.0 else 1.0 - (-ang) / wake;
    const glow = along * along * along;
    const radial = if (r > 0.94) (1.0 - r) / 0.06 else 0.35 + 0.65 * r;

    return @intFromFloat(@max(0.0, @min(255.0, glow * radial * 255.0)));
}
