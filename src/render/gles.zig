//! SHELL (B1, B3). The GLES2 backend: shaders, one texture, one vertex buffer, one draw call.
//!
//! This is the whole of what needs a GPU to run, and therefore the whole of what cannot be tested
//! without one. Everything that CAN be tested on a laptop -- colour unpacking, winding, pixel
//! geometry, baselines, glyph packing -- lives in `quads.zig`, `text.zig` and `atlas.zig`, and is
//! tested there. What is left here is irreducible: hand it triangles, it puts them on a screen.
//!
//! ============================================================================
//! THE RENDERING BACKEND IS A SEALED DECISION (D1)
//!
//! GLES2 is a choice, and one day it will be Vulkan, or Metal via ANGLE. So it is a module with a
//! small interface over a substantial implementation (D2): `init`, `upload`, `draw`, `deinit`.
//!
//! No GL type, no shader, no attribute location, and no `GLuint` appears in any other module's
//! signatures (D3). `android.zig` hands over a slice of vertices, a coverage bitmap, and a viewport
//! size, and learns nothing else. If GLES vanished tomorrow, this file would fail to compile and
//! no other.
//!
//! ============================================================================
//! NO HEADERS, NO BINDINGS, NO @cImport (F1)
//!
//! The entry points are declared here, locally, as `extern fn` -- exactly as `android.zig` declares
//! the NDK and `text.zig` declares the font shim. `libGLESv2.so` ships on every Android device that
//! can run this game; it is the platform, not a dependency, and the APK's linker resolves it.
//!
//! ============================================================================
//! ONE PASS. RECTANGLES AND LETTERS ARE THE SAME THING.
//!
//! Every quad samples a coverage value from the glyph atlas and multiplies its colour's alpha by
//! it. A letter samples its glyph. A rectangle samples a reserved white texel and gets 1.0.
//!
//! So the fragment shader has no branch and the vertex has no mode flag, and the whole screen --
//! background, cards, condition bar, and every letter of every sentence -- is ONE `glDrawArrays`.

const std = @import("std");
const quads = @import("quads.zig");

const Vertex = quads.Vertex;

// ============================================================================ the ABI

const GLuint = c_uint;
const GLint = c_int;
const GLsizei = c_int;
const GLenum = c_uint;
const GLchar = u8;
const GLboolean = u8;
const GLsizeiptr = isize;

extern fn glCreateShader(GLenum) GLuint;
extern fn glShaderSource(GLuint, GLsizei, [*]const [*:0]const GLchar, ?[*]const GLint) void;
extern fn glCompileShader(GLuint) void;
extern fn glGetShaderiv(GLuint, GLenum, *GLint) void;
extern fn glDeleteShader(GLuint) void;

extern fn glCreateProgram() GLuint;
extern fn glAttachShader(GLuint, GLuint) void;
extern fn glLinkProgram(GLuint) void;
extern fn glGetProgramiv(GLuint, GLenum, *GLint) void;
extern fn glUseProgram(GLuint) void;
extern fn glDeleteProgram(GLuint) void;

extern fn glGenBuffers(GLsizei, [*]GLuint) void;
extern fn glBindBuffer(GLenum, GLuint) void;
extern fn glBufferData(GLenum, GLsizeiptr, ?*const anyopaque, GLenum) void;
extern fn glDeleteBuffers(GLsizei, [*]const GLuint) void;

extern fn glGenTextures(GLsizei, [*]GLuint) void;
extern fn glBindTexture(GLenum, GLuint) void;
extern fn glTexImage2D(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, ?*const anyopaque) void;
extern fn glTexParameteri(GLenum, GLenum, GLint) void;
extern fn glPixelStorei(GLenum, GLint) void;
extern fn glActiveTexture(GLenum) void;
extern fn glDeleteTextures(GLsizei, [*]const GLuint) void;

extern fn glGetAttribLocation(GLuint, [*:0]const GLchar) GLint;
extern fn glGetUniformLocation(GLuint, [*:0]const GLchar) GLint;
extern fn glEnableVertexAttribArray(GLuint) void;
extern fn glVertexAttribPointer(GLuint, GLint, GLenum, GLboolean, GLsizei, ?*const anyopaque) void;
extern fn glUniform2f(GLint, f32, f32) void;
extern fn glUniform1i(GLint, GLint) void;

extern fn glEnable(GLenum) void;
extern fn glBlendFunc(GLenum, GLenum) void;
extern fn glDrawArrays(GLenum, GLint, GLsizei) void;

const GL_FRAGMENT_SHADER: GLenum = 0x8B30;
const GL_VERTEX_SHADER: GLenum = 0x8B31;
const GL_COMPILE_STATUS: GLenum = 0x8B81;
const GL_LINK_STATUS: GLenum = 0x8B82;
const GL_ARRAY_BUFFER: GLenum = 0x8892;
const GL_DYNAMIC_DRAW: GLenum = 0x88E8;
const GL_FLOAT: GLenum = 0x1406;
const GL_TRIANGLES: GLenum = 0x0004;
const GL_BLEND: GLenum = 0x0BE2;
const GL_SRC_ALPHA: GLenum = 0x0302;
const GL_ONE_MINUS_SRC_ALPHA: GLenum = 0x0303;

const GL_TEXTURE_2D: GLenum = 0x0DE1;
const GL_TEXTURE0: GLenum = 0x84C0;
const GL_UNSIGNED_BYTE: GLenum = 0x1401;
const GL_UNPACK_ALIGNMENT: GLenum = 0x0CF5;
const GL_TEXTURE_MIN_FILTER: GLenum = 0x2801;
const GL_TEXTURE_MAG_FILTER: GLenum = 0x2800;
const GL_TEXTURE_WRAP_S: GLenum = 0x2802;
const GL_TEXTURE_WRAP_T: GLenum = 0x2803;
const GL_LINEAR: GLint = 0x2601;
const GL_CLAMP_TO_EDGE: GLint = 0x812F;

/// GL_LUMINANCE. Single channel, and it replicates into `.rgb` when sampled.
///
/// NOT `GL_R8`/`GL_RED`. Those are core-profile desktop formats and are not GLES2. This is a GLES2
/// context on an Android phone, `GL_LUMINANCE` is the correct single-channel format here, and the
/// fragment shader below reads `.r` from it accordingly. Getting this pair out of step is the
/// single most likely way to render black text on the first run.
const GL_LUMINANCE: GLenum = 0x1909;

// ============================================================================ the shaders

/// GLSL ES 100. No `#version` line -- that IS version 100, the ES2 default, and it is what every
/// Android device made this century runs. `attribute`/`varying` rather than `in`/`out` for the same
/// reason.
///
/// The projection, in full: `aPos` is a pixel, `uViewport` is the surface in pixels. Divide,
/// double, subtract one -- and flip y, because the screen counts downward and clip space counts up.
/// That is the entire coordinate system of this renderer, and there is no matrix in it.
const vertex_shader: [:0]const GLchar =
    \\attribute vec2 aPos;
    \\attribute vec2 aUV;
    \\attribute vec4 aColor;
    \\uniform vec2 uViewport;
    \\varying vec2 vUV;
    \\varying vec4 vColor;
    \\void main() {
    \\  vUV = aUV;
    \\  vColor = aColor;
    \\  vec2 clip = vec2(aPos.x / uViewport.x * 2.0 - 1.0,
    \\                   1.0 - aPos.y / uViewport.y * 2.0);
    \\  gl_Position = vec4(clip, 0.0, 1.0);
    \\}
;

/// Colour, multiplied by coverage. No branch, no mode, no second pass.
///
/// A letter's coverage is its anti-aliased edge; a rectangle's is the white texel's 1.0. The same
/// three lines draw the whole game.
///
/// `mediump` is enough: these are 8-bit colours bound for an 8-bit framebuffer, and `highp` is not
/// guaranteed to exist in a fragment shader on ES2.
const fragment_shader: [:0]const GLchar =
    \\precision mediump float;
    \\uniform sampler2D uAtlas;
    \\varying vec2 vUV;
    \\varying vec4 vColor;
    \\void main() {
    \\  float coverage = texture2D(uAtlas, vUV).r;
    \\  gl_FragColor = vec4(vColor.rgb, vColor.a * coverage);
    \\}
;

// ============================================================================ the renderer

/// A compiled program, the buffer it draws from, and the atlas it samples.
///
/// A7.2: cold struct, size guard waived -- there is exactly one for the life of the process, and it
/// never sits in a loop.
pub const Renderer = struct {
    program: GLuint,
    vbo: GLuint,
    texture: GLuint,
    a_pos: GLint,
    a_uv: GLint,
    a_color: GLint,
    u_viewport: GLint,
    u_atlas: GLint,
};

/// SHELL. Compile the program, make a buffer and a texture. Null if the GPU refused.
///
/// An optional rather than an error union, on purpose (E4): there is exactly one thing a caller can
/// do about a GPU that will not compile a fifteen-line shader, and that is to not draw. A failed
/// renderer is an absent renderer, not an exception to unwind.
pub fn init() ?Renderer {
    const vs = compile(GL_VERTEX_SHADER, vertex_shader) orelse return null;
    defer glDeleteShader(vs);

    const fs = compile(GL_FRAGMENT_SHADER, fragment_shader) orelse return null;
    defer glDeleteShader(fs);

    const program = glCreateProgram();
    if (program == 0) return null;

    glAttachShader(program, vs);
    glAttachShader(program, fs);
    glLinkProgram(program);

    var linked: GLint = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (linked == 0) {
        glDeleteProgram(program);
        return null;
    }

    var vbo: GLuint = 0;
    glGenBuffers(1, @ptrCast(&vbo));

    var texture: GLuint = 0;
    glGenTextures(1, @ptrCast(&texture));

    if (vbo == 0 or texture == 0) {
        glDeleteProgram(program);
        return null;
    }

    return .{
        .program = program,
        .vbo = vbo,
        .texture = texture,
        .a_pos = glGetAttribLocation(program, "aPos"),
        .a_uv = glGetAttribLocation(program, "aUV"),
        .a_color = glGetAttribLocation(program, "aColor"),
        .u_viewport = glGetUniformLocation(program, "uViewport"),
        .u_atlas = glGetUniformLocation(program, "uAtlas"),
    };
}

pub fn deinit(renderer: *Renderer) void {
    glDeleteTextures(1, @ptrCast(&renderer.texture));
    glDeleteBuffers(1, @ptrCast(&renderer.vbo));
    glDeleteProgram(renderer.program);
    renderer.* = .{
        .program = 0,
        .vbo = 0,
        .texture = 0,
        .a_pos = -1,
        .a_uv = -1,
        .a_color = -1,
        .u_viewport = -1,
        .u_atlas = -1,
    };
}

fn compile(kind: GLenum, source: [:0]const GLchar) ?GLuint {
    const shader = glCreateShader(kind);
    if (shader == 0) return null;

    var pointer: [*:0]const GLchar = source.ptr;
    glShaderSource(shader, 1, @ptrCast(&pointer), null);
    glCompileShader(shader);

    var ok: GLint = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        glDeleteShader(shader);
        return null;
    }

    return shader;
}

/// SHELL. Push the coverage bitmap to the GPU. Call this when, and only when, it has changed.
///
/// `UNPACK_ALIGNMENT = 1` because the atlas is one byte per pixel and its rows are NOT padded to
/// four. GL's default is 4, and with it every row after the first is read at the wrong offset --
/// the glyphs come out sheared, diagonally, like a broken television. It is one line and it is not
/// optional.
pub fn upload(renderer: *const Renderer, coverage: []const u8, dim: u32) void {
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, renderer.texture);

    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(
        GL_TEXTURE_2D,
        0,
        @intCast(GL_LUMINANCE),
        @intCast(dim),
        @intCast(dim),
        0,
        GL_LUMINANCE,
        GL_UNSIGNED_BYTE,
        coverage.ptr,
    );

    // LINEAR, so the glyph edges stay smooth. CLAMP_TO_EDGE, so a uv on the last row cannot wrap
    // around and sample the first.
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

/// SHELL. Upload the frame and draw it. ONE `glBufferData`, ONE `glDrawArrays`, whole screen.
///
/// No depth buffer and no depth test: the painter's algorithm, in list order. `ui.zig` emits the
/// background first and the foreground last, which is exactly what that requires.
pub fn draw(renderer: *const Renderer, verts: []const Vertex, width: i32, height: i32) void {
    if (verts.len == 0) return;
    if (width <= 0 or height <= 0) return;

    glUseProgram(renderer.program);
    glBindBuffer(GL_ARRAY_BUFFER, renderer.vbo);
    glBufferData(
        GL_ARRAY_BUFFER,
        @intCast(verts.len * @sizeOf(Vertex)),
        verts.ptr,
        GL_DYNAMIC_DRAW,
    );

    // The offsets come from `@offsetOf`, not a hand-counted byte table. A hand-counted table is a
    // second copy of the struct layout that nothing checks, and it goes stale the day someone adds
    // a field -- silently, because the GPU reads garbage rather than complaining.
    bindAttribute(renderer.a_pos, 2, @offsetOf(Vertex, "x"));
    bindAttribute(renderer.a_uv, 2, @offsetOf(Vertex, "u"));
    bindAttribute(renderer.a_color, 4, @offsetOf(Vertex, "r"));

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, renderer.texture);
    glUniform1i(renderer.u_atlas, 0);
    glUniform2f(renderer.u_viewport, @floatFromInt(width), @floatFromInt(height));

    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    glDrawArrays(GL_TRIANGLES, 0, @intCast(verts.len));
}

fn bindAttribute(location: GLint, components: GLint, offset: usize) void {
    // A negative location means the linker optimised the attribute away. Binding it would be an
    // error; skipping it is correct.
    if (location < 0) return;

    const index: GLuint = @intCast(location);
    glEnableVertexAttribArray(index);
    glVertexAttribPointer(
        index,
        components,
        GL_FLOAT,
        0, // not normalised: these are already floats
        @sizeOf(Vertex),
        @ptrFromInt(offset),
    );
}

const testing = std.testing;

test "the attribute offsets follow the struct, not a hand-written table" {
    // The bug this pins: someone adds a field to Vertex, the offsets in `draw` no longer match the
    // memory, and the GPU reads colour out of the uv slot. It does not crash. It does not fail to
    // compile. It paints garbage on a phone nobody is holding.
    //
    // Using @offsetOf makes that impossible. This asserts the layout it depends on is the one the
    // shader is told to expect: position, then uv, then colour, contiguous and in that order.
    try testing.expectEqual(@as(usize, 0), @offsetOf(Vertex, "x"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(Vertex, "y"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Vertex, "u"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(Vertex, "v"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Vertex, "r"));
    try testing.expectEqual(@as(usize, 28), @offsetOf(Vertex, "a"));

    // The colour is four contiguous floats and it ends the struct. If that stops being true,
    // `bindAttribute(a_color, 4, ...)` reads past the end of it.
    try testing.expectEqual(@offsetOf(Vertex, "r") + 4 * @sizeOf(f32), @sizeOf(Vertex));

    // And uv is two floats sitting between them, not overlapping either.
    try testing.expectEqual(@offsetOf(Vertex, "u") + 2 * @sizeOf(f32), @offsetOf(Vertex, "r"));
}
