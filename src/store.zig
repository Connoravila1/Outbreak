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

/// SHELL. Write a journal to disk, replacing whatever was there.
pub fn save(io: Io, path: []const u8, bytes: []const u8) !void {
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
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
