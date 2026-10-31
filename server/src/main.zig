//! outbreak-server: flags, data directory, database, tick thread, listener.

const std = @import("std");
const server = @import("server");

const log = std.log.scoped(.main);

const Config = struct {
    port: u16 = 8080,
    bind: []const u8 = "0.0.0.0",
    data: []const u8 = "./data",
    dev: bool = false,
};

const usage =
    \\usage: outbreak-server [--port 8080] [--bind 0.0.0.0] [--data ./data] [--dev]
    \\environment: OUTBREAK_PORT, OUTBREAK_BIND, OUTBREAK_DATA, OUTBREAK_DEV (1 or true)
    \\
;

fn truthy(v: []const u8) bool {
    return std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "yes");
}

fn parseConfig(init: std.process.Init) !Config {
    var cfg = Config{};
    const env = init.environ_map;
    if (env.get("OUTBREAK_PORT")) |v| cfg.port = try std.fmt.parseInt(u16, v, 10);
    if (env.get("OUTBREAK_BIND")) |v| cfg.bind = v;
    if (env.get("OUTBREAK_DATA")) |v| cfg.data = v;
    if (env.get("OUTBREAK_DEV")) |v| cfg.dev = truthy(v);

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

    var ctx = try server.ctx.Ctx.init(gpa, io, db_path, .{ .dev = cfg.dev, .limits = !cfg.dev });
    defer ctx.deinit();
    log.info("data in {s}{s}", .{ cfg.data, if (cfg.dev) " (dev endpoints enabled)" else "" });

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
