//! outbreak-server: flags, data directory, database, tick thread, listener.

const std = @import("std");
const server = @import("server");

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
    tiles_file: []const u8 = "",
    tiles_url: []const u8 = "",
    tiles_glyphs: []const u8 = "",
};

const usage =
    \\usage: outbreak-server [--port 8080] [--bind 0.0.0.0] [--data ./data] [--dev]
    \\                       [--tiles FILE.pmtiles | --tiles-url URL] [--tiles-glyphs URL]
    \\                       [--google-client-ids ID,ID,...] [--apple-audiences ID,ID,...]
    \\environment: OUTBREAK_PORT, OUTBREAK_BIND, OUTBREAK_DATA, OUTBREAK_DEV (1 or true),
    \\             OUTBREAK_GOOGLE_CLIENT_IDS, OUTBREAK_APPLE_AUDIENCES, OUTBREAK_TILES,
    \\             OUTBREAK_TILES_URL, OUTBREAK_TILES_GLYPHS
    \\Map tiles: the client uses OpenFreeMap by default. --tiles serves a PMTiles extract from this
    \\binary (GET /tiles/map.pmtiles, range requests); --tiles-url advertises one hosted elsewhere;
    \\--tiles-glyphs overrides the font URL template. See docs/TILES.md.
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

    if (env.get("OUTBREAK_TILES")) |v| cfg.tiles_file = v;
    if (env.get("OUTBREAK_TILES_URL")) |v| cfg.tiles_url = v;
    if (env.get("OUTBREAK_TILES_GLYPHS")) |v| cfg.tiles_glyphs = v;

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
        } else if (std.mem.eql(u8, arg, "--tiles")) {
            cfg.tiles_file = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--tiles-url")) {
            cfg.tiles_url = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--tiles-glyphs")) {
            cfg.tiles_glyphs = args.next() orelse return error.MissingValue;
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

pub fn main(init: std.process.Init) !void {
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

    var ctx = try server.ctx.Ctx.init(gpa, io, db_path, .{ .dev = cfg.dev, .limits = !cfg.dev, .auth = auth, .tiles = .{ .file = cfg.tiles_file, .url = cfg.tiles_url, .glyphs = cfg.tiles_glyphs } });
    if (cfg.tiles_file.len > 0) log.info("serving map tiles from {s}", .{cfg.tiles_file});
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
