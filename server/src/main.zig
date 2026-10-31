//! outbreak-server: flags, data directory, database, tick thread, listener.

const std = @import("std");
const server = @import("server");
const game = @import("game");

const log = std.log.scoped(.main);

const Config = struct {
    port: u16 = 8080,
    bind: []const u8 = "0.0.0.0",
    data: []const u8 = "./data",
    dev: bool = false,
    google_client_ids: []const u8 = "",
    apple_audiences: []const u8 = "",
    google_jwks_url: ?[]const u8 = null,
    apple_jwks_url: ?[]const u8 = null,
};

const usage =
    \\usage: outbreak-server [--port 8080] [--bind 0.0.0.0] [--data ./data] [--dev]
    \\                       [--google-client-ids ID,ID,...] [--apple-audiences ID,ID,...]
    \\       outbreak-server admin [--data ./data] <command>    (moderation; "admin help" lists the commands)
    \\environment: OUTBREAK_PORT, OUTBREAK_BIND, OUTBREAK_DATA, OUTBREAK_DEV (1 or true),
    \\             OUTBREAK_GOOGLE_CLIENT_IDS, OUTBREAK_APPLE_AUDIENCES
    \\Sign-in: the Google client IDs are the web, Android and iOS OAuth clients (web first); the Apple
    \\audiences are the iOS bundle id (com.outbreak.game) and the web Services ID. A provider with no
    \\IDs answers 503 provider_not_configured. --google-jwks-url / --apple-jwks-url exist for testing.
    \\
;

fn truthy(v: []const u8) bool {
    return std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "yes");
}

/// Split a comma list, trimming blanks and dropping empty entries. The slices point into `text`.
fn splitList(gpa: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |item| {
        const t = std.mem.trim(u8, item, " \t");
        if (t.len > 0) try out.append(gpa, t);
    }
    return out.toOwnedSlice(gpa);
}

fn parseConfig(init: std.process.Init) !Config {
    var cfg = Config{};
    const env = init.environ_map;
    if (env.get("OUTBREAK_PORT")) |v| cfg.port = try std.fmt.parseInt(u16, v, 10);
    if (env.get("OUTBREAK_BIND")) |v| cfg.bind = v;
    if (env.get("OUTBREAK_DATA")) |v| cfg.data = v;
    if (env.get("OUTBREAK_DEV")) |v| cfg.dev = truthy(v);
    if (env.get("OUTBREAK_GOOGLE_CLIENT_IDS")) |v| cfg.google_client_ids = v;
    if (env.get("OUTBREAK_APPLE_AUDIENCES")) |v| cfg.apple_audiences = v;

    var args = init.minimal.args.iterate();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            cfg.port = try std.fmt.parseInt(u16, args.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--bind")) {
            cfg.bind = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--data")) {
            cfg.data = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--dev")) {
            cfg.dev = true;
        } else if (std.mem.eql(u8, arg, "--google-client-ids")) {
            cfg.google_client_ids = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--apple-audiences")) {
            cfg.apple_audiences = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--google-jwks-url")) {
            cfg.google_jwks_url = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--apple-jwks-url")) {
            cfg.apple_jwks_url = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.Io.File.stdout().writeStreamingAll(init.io, usage);
            std.process.exit(0);
        } else return error.UnknownArgument;
    }
    return cfg;
}

/// `outbreak-server admin [--data DIR] <command> ...`: moderation on the database directly.
fn adminMain(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var data_dir: []const u8 = init.environ_map.get("OUTBREAK_DATA") orelse "./data";
    var rest: std.ArrayList([]const u8) = .empty;
    defer rest.deinit(gpa);
    var args = init.minimal.args.iterate();
    _ = args.next();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--data")) {
            data_dir = args.next() orelse return error.MissingValue;
        } else try rest.append(gpa, arg);
    }

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const stdout = std.Io.File.stdout();
    const stdout_err = std.Io.File.stderr();
    if (rest.items.len == 0 or std.mem.eql(u8, rest.items[0], "help") or std.mem.eql(u8, rest.items[0], "--help")) {
        try stdout.writeStreamingAll(io, server.admin.usage);
        return;
    }

    const db_path = try std.fmt.allocPrintSentinel(gpa, "{s}/outbreak.db", .{data_dir}, 0);
    defer gpa.free(db_path);
    // Opening would create an empty database; a wrong --data should say so instead.
    std.Io.Dir.cwd().access(io, db_path, .{}) catch {
        const msg = try std.fmt.allocPrint(gpa, "No database at {s}. Pass --data with the folder the server uses.\n", .{db_path});
        defer gpa.free(msg);
        try stdout_err.writeStreamingAll(io, msg);
        std.process.exit(1);
    };
    var db = try server.db.Db.open(db_path);
    defer db.close();

    var seed_bytes: [8]u8 = undefined;
    io.random(&seed_bytes);
    var rng = game.rng.Rng.init(std.mem.readInt(u64, &seed_bytes, .little));
    const now = std.Io.Clock.real.now(io).toMilliseconds();
    var failed = false;
    server.admin.run(gpa, &db, now, &rng, rest.items, &aw.writer) catch |e| switch (e) {
        error.Failed => failed = true,
        else => return e,
    };
    try stdout.writeStreamingAll(io, aw.written());
    if (failed) std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    {
        var probe = init.minimal.args.iterate();
        _ = probe.next();
        if (probe.next()) |first| {
            if (std.mem.eql(u8, first, "admin")) return adminMain(init);
        }
    }
    const cfg = parseConfig(init) catch |e| {
        std.debug.print("{s}\n{s}", .{ @errorName(e), usage });
        std.process.exit(2);
    };
    const io = init.io;
    const gpa = init.gpa;

    try std.Io.Dir.cwd().createDirPath(io, cfg.data);
    const db_path = try std.fmt.allocPrintSentinel(gpa, "{s}/outbreak.db", .{cfg.data}, 0);
    defer gpa.free(db_path);

    // The lists live as long as the process.
    var auth = server.auth.Config{
        .google_client_ids = try splitList(gpa, cfg.google_client_ids),
        .apple_audiences = try splitList(gpa, cfg.apple_audiences),
    };
    if (cfg.google_jwks_url) |u| auth.google_jwks_url = u;
    if (cfg.apple_jwks_url) |u| auth.apple_jwks_url = u;

    var ctx = try server.ctx.Ctx.init(gpa, io, db_path, .{ .dev = cfg.dev, .limits = !cfg.dev, .auth = auth });
    defer ctx.deinit();
    log.info("data in {s}{s}", .{ cfg.data, if (cfg.dev) " (dev endpoints enabled)" else "" });
    log.info("sign-in: google {s}, apple {s}{s}", .{
        if (ctx.auth.configured(.google)) "on" else "off",
        if (ctx.auth.configured(.apple)) "on" else "off",
        if (cfg.dev) ", dev" else "",
    });

    const ticker = try std.Thread.spawn(.{}, tickLoop, .{&ctx});
    ticker.detach();

    const address = try std.Io.net.IpAddress.parse(cfg.bind, cfg.port);
    try server.http.serve(&ctx, address);
}

fn tickLoop(ctx: *server.ctx.Ctx) void {
    while (true) {
        ctx.io.sleep(.fromMilliseconds(@intCast(server.tick.interval_ms)), .awake) catch return;
        server.tick.run(ctx);
    }
}
