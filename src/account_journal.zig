//! CORE. Durable authentication state.
//!
//! This format stores keyed contact fingerprints, salts, and password verifiers. It never stores a
//! contact point or password. The server pepper deliberately lives in a separate, private secret
//! file: stealing the state database alone must not make enumerable contact points matchable. The
//! account bytes are embedded in the same atomic server-state bundle as the world, so an identity
//! can never advance without the progress row it owns advancing with it.

const std = @import("std");
const accounts_mod = @import("accounts.zig");

const Allocator = std.mem.Allocator;

pub const magic: u32 = 0x4341_424F; // "OBAC", little-endian
pub const version: u32 = 1;
const header_size: usize = 16;
const entry_size: usize = 85;

pub const Error = error{ BadMagic, BadVersion, Truncated, BadValue };

pub const Restored = struct {
    accounts: accounts_mod.Accounts,
};

pub fn encode(
    gpa: Allocator,
    accounts: *const accounts_mod.Accounts,
) Allocator.Error![]u8 {
    const entries = try accounts_mod.storedSorted(accounts, gpa);
    defer gpa.free(entries);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, header_size + entries.len * entry_size);
    try appendInt(&out, gpa, u32, magic);
    try appendInt(&out, gpa, u32, version);
    try appendInt(&out, gpa, u32, accounts_mod.nextPlayer(accounts));
    try appendInt(&out, gpa, u32, @intCast(entries.len));

    for (entries) |entry| {
        try out.appendSlice(gpa, &entry.contact);
        try appendInt(&out, gpa, u32, @intFromEnum(entry.account.player));
        try out.append(gpa, @intFromEnum(entry.account.faction));
        try out.appendSlice(gpa, &entry.account.salt);
        try out.appendSlice(gpa, &entry.account.verifier);
    }
    return out.toOwnedSlice(gpa);
}

pub fn decode(gpa: Allocator, bytes: []const u8) (Allocator.Error || Error || accounts_mod.RestoreError)!Restored {
    if (bytes.len < header_size) return error.Truncated;
    if (readInt(bytes, 0, u32) != magic) return error.BadMagic;
    if (readInt(bytes, 4, u32) != version) return error.BadVersion;

    const count = readInt(bytes, 12, u32);
    const payload_size = std.math.mul(usize, count, entry_size) catch return error.BadValue;
    if (bytes.len != header_size + payload_size) return error.Truncated;

    const entries = try gpa.alloc(accounts_mod.Stored, count);
    defer gpa.free(entries);
    var offset: usize = header_size;
    for (entries) |*entry| {
        @memcpy(&entry.contact, bytes[offset .. offset + 32]);
        offset += 32;
        const player_value = readInt(bytes, offset, u32);
        offset += 4;
        if (player_value == 0) return error.BadValue;
        const faction: @import("world.zig").Faction = switch (bytes[offset]) {
            0 => .human,
            1 => .zombie,
            else => return error.BadValue,
        };
        offset += 1;
        entry.account = .{
            .player = @enumFromInt(player_value),
            .faction = faction,
            .salt = undefined,
            .verifier = undefined,
        };
        @memcpy(&entry.account.salt, bytes[offset .. offset + 16]);
        offset += 16;
        @memcpy(&entry.account.verifier, bytes[offset .. offset + 32]);
        offset += 32;
    }

    return .{
        .accounts = try accounts_mod.restore(gpa, entries, readInt(bytes, 8, u32)),
    };
}

fn appendInt(out: *std.ArrayList(u8), gpa: Allocator, comptime T: type, value: T) Allocator.Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try out.appendSlice(gpa, &bytes);
}

fn readInt(bytes: []const u8, offset: usize, comptime T: type) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

test "account authentication material survives a byte round trip without plaintext identity" {
    const gpa = std.testing.allocator;
    var accounts: accounts_mod.Accounts = .empty;
    defer accounts_mod.deinit(&accounts, gpa);
    const contact: accounts_mod.ContactHash = @splat(0x17);
    _ = try accounts_mod.register(&accounts, gpa, contact, @splat(0x28), @splat(0x39), .zombie, 4, 0, .default);
    const bytes = try encode(gpa, &accounts);
    defer gpa.free(bytes);
    var restored = try decode(gpa, bytes);
    defer accounts_mod.deinit(&restored.accounts, gpa);

    const account = restored.accounts.by_contact.get(contact).?;
    try std.testing.expectEqual(@import("world.zig").Faction.zombie, account.faction);
    try std.testing.expectEqual(@as(u32, 2), accounts_mod.nextPlayer(&restored.accounts));
}

test "a corrupt faction is rejected before it can become an enum" {
    const gpa = std.testing.allocator;
    var accounts: accounts_mod.Accounts = .empty;
    defer accounts_mod.deinit(&accounts, gpa);
    _ = try accounts_mod.register(&accounts, gpa, @splat(1), @splat(2), @splat(3), .human, 1, 0, .default);
    const bytes = try encode(gpa, &accounts);
    defer gpa.free(bytes);
    bytes[header_size + 36] = 9;
    try std.testing.expectError(error.BadValue, decode(gpa, bytes));
}
