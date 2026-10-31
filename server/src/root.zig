//! The server library; main.zig is the thin executable around it.

pub const db = @import("db.zig");
pub const live = @import("live.zig");
pub const auth = @import("auth.zig");
pub const jwt = @import("jwt.zig");
pub const snapshot = @import("snapshot.zig");
pub const ctx = @import("ctx.zig");
pub const api = @import("api.zig");
pub const tick = @import("tick.zig");
pub const http = @import("http.zig");
pub const admin = @import("admin.zig");
pub const names = @import("names.zig");
pub const client_version = @import("client_version.zig");

test {
    _ = @import("api_tests.zig");
    _ = @import("api/account.zig");
    _ = @import("admin.zig");
    _ = @import("names.zig");
    _ = @import("jwt.zig");
    _ = @import("auth.zig");
    _ = @import("fight.zig");
    _ = @import("raids.zig");
    _ = @import("warstate.zig");
}

test {
    @import("std").testing.refAllDecls(@This());
}
