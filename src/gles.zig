//! SHELL (B1, B3). The GLES2 backend: shaders, one vertex buffer, one draw call.
//!
//! This is the whole of what needs a GPU to run, and therefore the whole of what cannot be tested
//! without one. Everything that CAN be tested on a laptop -- the colour unpacking, the winding,
//! the pixel geometry -- lives in `quads.zig` and is tested there. What is left here is the
//! irreducible part: hand it triangles, it puts them on a screen.
//!
//! ============================================================================
//! THE RENDERING BACKEND IS A SEALED DECISION (D1)
//!
//! GLES2 is a choice, and one day it will be Vulkan, or Metal via ANGLE, or something not yet
//! written. So it is a module with a small interface over a substantial implementation (D2):
//! `init`, `draw`, `deinit`, and a `Renderer` handle whose fields are nobody else's business.
//!
//! No GL type, no shader, no attribute location, and no `GLuint` appears in any other module's
//! signatures (D3). `android.zig` hands this module a slice of vertices and a viewport size and
//! learns nothing else. If GLES vanished tomorrow, this file would fail to compile and no other.
//!
//! ============================================================================
//! NO DEPENDENCY, NO HEADERS, NO BINDINGS (F1)
//!
//! The two dozen entry points we use are declared here, locally, as `extern fn` -- exactly as
//! `android.zig` declares the NDK. There is no `@cImport`, no generated binding, and no package.
//! `libGLESv2.so` ships on every Android device that can run this game; it is the platform, not a
//! dependency, and the APK's linker resolves it. Nothing to vendor and nothing to remove.
//!
//! ============================================================================
//! WHY THERE IS NO MATRIX
//!
//! The projection is two lines of the vertex shader against a single `uViewport` uniform. Pixels
//! in, clip space out, y down, origin top-left. A 4x4 matrix would be sixteen floats and a library
//! to build them, to express what a divide and a subtract already express. (G3: the stop rule.)

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

extern fn glGetAttribLocation(GLuint, [*:0]const GLchar) GLint;
extern fn glGetUniformLocation(GLuint, [*:0]const GLchar) GLint;
extern fn glEnableVertexAttribArray(GLuint) void;
extern fn glVertexAttribPointer(GLuint, GLint, GLenum, GLboolean, GLsizei, ?*const anyopaque) void;
extern fn glUniform2f(GLint, f32, f32) void;

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

// ============================================================================ the shaders

/// GLSL ES 100. No `#version` line: that IS version 100, the ES2 default, and it is what every
/// Android device made this century runs. `attribute`/`varying` rather than `in`/`out` for the
/// same reason.
///
/// The projection, in full. `aPos` is a pixel; `uViewport` is the surface in pixels. Divide,
/// double, subtract one -- and flip y, because the screen counts downward and clip space counts
/// up. That is the entire coordinate system of this renderer.
const vertex_shader: [:0]const GLchar =
    \\attribute vec2 aPos;
    \\attribute vec4 aColor;
    \\uniform vec2 uViewport;
    \\varying vec4 vColor;
    \\void main() {
    \\  vColor = aColor;
    \\  vec2 clip = vec2(aPos.x / uViewport.x * 2.0 - 1.0,
    \\                   1.0 - aPos.y / uViewport.y * 2.0);
    \\  gl_Position = vec4(clip, 0.0, 1.0);
    \\}
;

/// Solid fill. The colour arrives interpolated and leaves unchanged.
///
/// `mediump` is a promise about precision, and it is enough: these are 8-bit colours on their way
/// to an 8-bit framebuffer. `highp` is not guaranteed to exist in a fragment shader on ES2.
const fragment_shader: [:0]const GLchar =
    \\precision mediump float;
    \\varying vec4 vColor;
    \\void main() {
    \\  gl_FragColor = vColor;
    \\}
;

// ============================================================================ the renderer

/// A compiled program and the buffer it draws from.
///
/// A7.2: cold struct, size guard waived -- there is exactly one of these for the life of the
/// process, and it never sits in a loop.
pub const Renderer = struct {
    program: GLuint,
    vbo: GLuint,
    a_pos: GLint,
    a_color: GLint,
    u_viewport: GLint,
};

/// SHELL. Compile the program and make a buffer. Null if the GPU refused.
///
/// Returns an optional rather than an error union on purpose (E4): there is exactly one thing the
/// caller can do about a GPU that will not compile a fifteen-line shader, and that is to not draw.
/// A failed renderer is an absent renderer, not an exception to unwind.
pub fn init() ?Renderer {
    const vs = compile(GL_VERTEX_SHADER, vertex_shader) orelse return null;
    defer glDeleteShader(vs);

    const fs = compile(GL_FRAGMENT_SHADER, fragment_shader) orelse {
        return null;
    };
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
    if (vbo == 0) {
        glDeleteProgram(program);
        return null;
    }

    return .{
        .program = program,
        .vbo = vbo,
        .a_pos = glGetAttribLocation(program, "aPos"),
        .a_color = glGetAttribLocation(program, "aColor"),
        .u_viewport = glGetUniformLocation(program, "uViewport"),
    };
}

pub fn deinit(renderer: *Renderer) void {
    glDeleteBuffers(1, @ptrCast(&renderer.vbo));
    glDeleteProgram(renderer.program);
    renderer.* = .{ .program = 0, .vbo = 0, .a_pos = -1, .a_color = -1, .u_viewport = -1 };
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

/// SHELL. Upload the frame and draw it. ONE `glBufferData`, ONE `glDrawArrays`, whole screen.
///
/// Batched because the alternative -- a draw call per rectangle -- is a few hundred round trips to
/// the driver per frame, on a battery. This is not premature optimisation; it is the shape the API
/// was built for, and the unbatched version would be the odd choice needing defence.
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

    // The attribute offsets come from `@offsetOf`, not from a hand-counted byte table. A hand
    // counted table is a second copy of the struct layout that nothing checks, and it goes stale
    // the day someone adds a field -- silently, because the GPU will happily read garbage.
    bindAttribute(renderer.a_pos, 2, @offsetOf(Vertex, "x"));
    bindAttribute(renderer.a_color, 4, @offsetOf(Vertex, "r"));

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
    // memory, and the GPU reads colour out of the position slot. It does not crash. It does not
    // fail to compile. It paints garbage on a phone nobody is holding.
    //
    // Using @offsetOf makes that impossible, and this test asserts the layout it depends on is the
    // one the shader is told to expect: position first, colour immediately after it.
    try testing.expectEqual(@as(usize, 0), @offsetOf(Vertex, "x"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(Vertex, "y"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(Vertex, "r"));
    try testing.expectEqual(@as(usize, 12), @offsetOf(Vertex, "g"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Vertex, "b"));
    try testing.expectEqual(@as(usize, 20), @offsetOf(Vertex, "a"));

    // The colour is four contiguous floats starting where the position ends. If that ever stops
    // being true, `bindAttribute(a_color, 4, ...)` is reading past the end of the colour.
    try testing.expectEqual(@offsetOf(Vertex, "r") + 4 * @sizeOf(f32), @sizeOf(Vertex));
}
