//! SHELL (B1, B3). The disk. Four functions.
//!
//! Everything interesting about persistence is in `journal.zig`, which is pure and knows
//! nothing about files. This is the part that touches the world: it opens, it writes, it
//! reads, it deletes. It is deliberately this thin (D2 -- a module is deep or it is
//! collapsed; this one is a boundary, not a design).
//!
//! It handles bytes. It has no idea what is in them, and it cannot: the format lives behind
//! the journal's boundary (D3). That is why the retention policy (I7) cannot be quietly
//! subverted here -- there is nothing here that understands a record well enough to keep one.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

/// A journal will not exceed this. Ten thousand players at 12 bytes a report, for a week of
/// 30-second ticks, is about 24 GB -- which is exactly why retention (I7) is not optional and
/// why `prune` exists in the first version of the journal.
pub const max_journal_bytes: Io.Limit = .limited(1 << 30);

/// SHELL. Write bytes atomically, replacing whatever was there.
///
/// The old implementation truncated the destination before writing. A process kill or power loss
/// in that interval turned the only good state into a corrupt partial file. This writes a private
/// temporary file, flushes it, and atomically renames it over the destination.
pub fn save(io: Io, path: []const u8, bytes: []const u8) !void {
    var atomic = try Dir.cwd().createFileAtomic(io, path, .{
        .permissions = .fromMode(0o600),
        .replace = true,
    });
    defer atomic.deinit(io);

    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
}

/// SHELL. Read a journal back. The caller owns the bytes (C1, C5).
pub fn load(io: Io, gpa: Allocator, path: []const u8) ![]u8 {
    return Dir.cwd().readFileAlloc(io, path, gpa, max_journal_bytes);
}

/// SHELL. RETENTION DELETION, THE PART THAT TOUCHES THE DISK (I7).
///
/// Rule I7 is not a policy document. It is a thing that runs, and it deletes a file.
pub fn remove(io: Io, path: []const u8) !void {
    Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {}, // already gone is the state we wanted (E4)
        else => return err,
    };
}
