//! The HTTP transport: accept loop, a thread per connection, keep-alive, CORS. Everything that is
//! not sockets lives in api.zig.

const std = @import("std");
const ctx_mod = @import("ctx.zig");
const api = @import("api.zig");

const Ctx = ctx_mod.Ctx;
const http = std.http;
const net = std.Io.net;

const log = std.log.scoped(.http);

pub const max_connections = 512;
const read_buffer_bytes = 16 * 1024;
const write_buffer_bytes = 16 * 1024;
const thread_stack_bytes = 512 * 1024;

const cors_headers = [_]http.Header{
    .{ .name = "access-control-allow-origin", .value = "*" },
    .{ .name = "access-control-allow-headers", .value = "Authorization, Content-Type" },
    .{ .name = "access-control-allow-methods", .value = "GET, POST, OPTIONS" },
    .{ .name = "access-control-max-age", .value = "86400" },
    .{ .name = "content-type", .value = "application/json; charset=utf-8" },
    .{ .name = "cache-control", .value = "no-store" },
};

const Server = struct {
    ctx: *Ctx,
    active: std.atomic.Value(u32) = .init(0),
};

/// Listen and serve forever. Returns only on a listen/accept failure.
pub fn serve(ctx: *Ctx, address: net.IpAddress) !void {
    var listener = try address.listen(ctx.io, .{ .reuse_address = true });
    defer listener.deinit(ctx.io);
    var server = Server{ .ctx = ctx };
    log.info("listening on port {d}", .{address.getPort()});
    while (true) {
        const stream = listener.accept(ctx.io) catch |e| switch (e) {
            error.ConnectionAborted, error.WouldBlock, error.ProtocolFailure, error.BlockedByFirewall => continue,
            else => return e,
        };
        if (server.active.load(.acquire) >= max_connections) {
            stream.close(ctx.io);
            continue;
        }
        _ = server.active.fetchAdd(1, .acq_rel);
        const t = std.Thread.spawn(.{ .stack_size = thread_stack_bytes }, connection, .{ &server, stream }) catch {
            _ = server.active.fetchSub(1, .acq_rel);
            stream.close(ctx.io);
            continue;
        };
        t.detach();
    }
}

fn connection(server: *Server, stream: net.Stream) void {
    defer _ = server.active.fetchSub(1, .acq_rel);
    const ctx = server.ctx;
    defer stream.close(ctx.io);
    serveConnection(ctx, stream) catch |e| log.debug("connection ended: {s}", .{@errorName(e)});
}

fn serveConnection(ctx: *Ctx, stream: net.Stream) !void {
    var rbuf: [read_buffer_bytes]u8 = undefined;
    var wbuf: [write_buffer_bytes]u8 = undefined;
    var reader = stream.reader(ctx.io, &rbuf);
    var writer = stream.writer(ctx.io, &wbuf);
    var server = http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var request = server.receiveHead() catch |e| switch (e) {
            error.HttpConnectionClosing => return,
            else => return e,
        };
        const start = std.Io.Clock.awake.now(ctx.io).toMilliseconds();
        const keep = try handleRequest(ctx, &request);
        const ms = std.Io.Clock.awake.now(ctx.io).toMilliseconds() - start;
        _ = ms;
        if (!keep) return;
    }
}

/// Answer one request. Returns whether the connection can be reused.
fn handleRequest(ctx: *Ctx, request: *http.Server.Request) !bool {
    const start = std.Io.Clock.awake.now(ctx.io).toMilliseconds();
    const target = request.head.target;
    const q = std.mem.indexOfScalar(u8, target, '?');
    const path = if (q) |i| target[0..i] else target;
    const query = if (q) |i| target[i + 1 ..] else "";
    const method = @tagName(request.head.method);
    var keep = request.head.keep_alive;

    // The bearer token, if any (never logged).
    var token: ?[]const u8 = null;
    var it = request.iterateHeaders();
    while (it.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
            const prefix = "Bearer ";
            if (h.value.len > prefix.len and std.ascii.eqlIgnoreCase(h.value[0..prefix.len], prefix)) token = h.value[prefix.len..];
        }
    }
    // Copy it: the header buffer is invalidated when the body is read.
    var token_buf: [128]u8 = undefined;
    if (token) |t| {
        if (t.len > token_buf.len) token = null else {
            @memcpy(token_buf[0..t.len], t);
            token = token_buf[0..t.len];
        }
    }

    var status: u16 = 0;
    var body: []u8 = &.{};
    defer ctx.gpa.free(body);

    if (request.head.content_length) |len| {
        if (len > api.max_body_bytes) {
            keep = false;
            status = try respondError(request, 413, "too_large", "The request body is too large.", false);
            logRequest(ctx, method, path, status, start);
            return false;
        }
    }
    if (request.head.method.requestHasBody()) {
        var tmp: [1024]u8 = undefined;
        const body_reader = request.readerExpectContinue(&tmp) catch return false;
        body = body_reader.allocRemaining(ctx.gpa, .limited(api.max_body_bytes)) catch |e| switch (e) {
            error.StreamTooLong => {
                status = try respondError(request, 413, "too_large", "The request body is too large.", false);
                logRequest(ctx, method, path, status, start);
                return false;
            },
            else => return false,
        };
    }

    const resp = api.handle(ctx, method, path, query, token, body);
    defer resp.deinit(ctx.gpa);
    status = resp.status;
    try request.respond(resp.json, .{
        .status = @enumFromInt(resp.status),
        .keep_alive = keep,
        .extra_headers = &cors_headers,
    });
    logRequest(ctx, method, path, status, start);
    return keep;
}

fn respondError(request: *http.Server.Request, status: u16, code: []const u8, message: []const u8, keep: bool) !u16 {
    var buf: [256]u8 = undefined;
    const json = try std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\",\"message\":\"{s}\"}}", .{ code, message });
    try request.respond(json, .{ .status = @enumFromInt(status), .keep_alive = keep, .extra_headers = &cors_headers });
    return status;
}

/// One line per request: method, path, status, milliseconds. No query, body, token or position.
fn logRequest(ctx: *Ctx, method: []const u8, path: []const u8, status: u16, start: i64) void {
    const ms = std.Io.Clock.awake.now(ctx.io).toMilliseconds() - start;
    log.info("{s} {s} {d} {d}ms", .{ method, path, status, ms });
}
