//! CORE. One atomic envelope for authentication identity and the world it owns.
//!
//! Saving these as two independently replaced files creates a crash window where an account points
//! at a world version that was never written (or a world row has no account). One envelope gives
//! the filesystem one rename and therefore one truth.

const std = @import("std");

pub const magic: u32 = 0x5453_424F; // "OBST", little-endian
pub const version: u32 = 1;
const header_size: usize = 16;

pub const Error = error{ BadMagic, BadVersion, Truncated, BadValue };

pub const Parts = struct {
    accounts: []const u8,
    world: []const u8,
};

pub fn encode(gpa: std.mem.Allocator, accounts: []const u8, world: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, header_size + accounts.len + world.len);
    try appendInt(&out, gpa, u32, magic);
    try appendInt(&out, gpa, u32, version);
    try appendInt(&out, gpa, u32, @intCast(accounts.len));
    try appendInt(&out, gpa, u32, @intCast(world.len));
    try out.appendSlice(gpa, accounts);
    try out.appendSlice(gpa, world);
    return out.toOwnedSlice(gpa);
}

pub fn decode(bytes: []const u8) Error!Parts {
    if (bytes.len < header_size) return error.Truncated;
    if (readInt(bytes, 0, u32) != magic) return error.BadMagic;
    if (readInt(bytes, 4, u32) != version) return error.BadVersion;
    const accounts_len: usize = readInt(bytes, 8, u32);
    const world_len: usize = readInt(bytes, 12, u32);
    const payload_len = std.math.add(usize, accounts_len, world_len) catch return error.BadValue;
    if (bytes.len != header_size + payload_len) return error.Truncated;
    return .{
        .accounts = bytes[header_size .. header_size + accounts_len],
        .world = bytes[header_size + accounts_len ..],
    };
}

fn appendInt(out: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime T: type, value: T) std.mem.Allocator.Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try out.appendSlice(gpa, &bytes);
}

fn readInt(bytes: []const u8, offset: usize, comptime T: type) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

test "account and world payloads share one exact envelope" {
    const gpa = std.testing.allocator;
    const bytes = try encode(gpa, "accounts", "world");
    defer gpa.free(bytes);
    const parts = try decode(bytes);
    try std.testing.expectEqualStrings("accounts", parts.accounts);
    try std.testing.expectEqualStrings("world", parts.world);
    try std.testing.expectError(error.Truncated, decode(bytes[0 .. bytes.len - 1]));
}
