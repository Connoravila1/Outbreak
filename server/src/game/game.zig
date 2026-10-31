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
pub const daynight = @import("daynight.zig");
pub const stance = @import("stance.zig");
pub const landmarks = @import("landmarks.zig");
pub const notes = @import("notes.zig");
pub const achievements = @import("achievements.zig");
pub const cosmetics = @import("cosmetics.zig");
pub const transit = @import("transit.zig");
pub const events = @import("events.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
