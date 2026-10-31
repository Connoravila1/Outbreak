//! The pure game core: no I/O, no clock, no globals. Import as `@import("game")`.

pub const data = @import("data.zig");
pub const rng = @import("rng.zig");
pub const stats = @import("stats.zig");
pub const progression = @import("progression.zig");
pub const combat = @import("combat.zig");
pub const geo = @import("geo.zig");
pub const loot = @import("loot.zig");
pub const spawns = @import("spawns.zig");
pub const missions = @import("missions.zig");
pub const war = @import("war.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
