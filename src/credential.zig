//! SHELL (B1, B3). Passwords and contact points. The only file that touches crypto.
//!
//! It is shell because it must be: `Argon2.kdf` and the CSPRNG both require an `Io` handle,
//! which the core does not have. The guard forbids `std.crypto` in any core file, so this
//! cannot drift inward even by accident.
//!
//! ============================================================================
//! WHAT WE STORE, AND WHAT WE REFUSE TO
//!
//! A contact point (email or phone) is collected for exactly one reason: to know whether we
//! have SEEN IT BEFORE. That is the anti-farm property -- the real attack on this game is k
//! sock-puppet accounts spoofed into one cell, and free unlimited account creation is the
//! farm's front door (H5).
//!
//! Duplicate detection does not require holding the address. It requires holding a fingerprint
//! of it. So:
//!
//!   VERIFY CONTROL, THEN HASH. WE DO NOT KEEP A DIRECTORY OF WHO IS WHO.
//!
//! This matters more here than in most systems, and it is worth being exact about why. Today, a
//! total breach of the game server yields "opaque player ids, and which rooms they were in for
//! the last two hours" -- which is nothing, because nobody can tell who those ids are. The
//! moment we store `player_id -> email` in plaintext, that same breach becomes:
//!
//!   "THIS NAMED PERSON WAS IN THESE ROOMS."
//!
//! One table turns a meaningless dump into a list of people and where they were. The location
//! guarantee (B6, I7) is not weakened by an email; it is weakened by an email that can be
//! JOINED to a cell history. So we never store the join key in the clear.
//!
//! THE PEPPER. A hash alone is not enough: the space of email addresses is enumerable, so an
//! attacker with the table can hash a list of addresses and match them. The contact hash is
//! therefore keyed (HMAC) with a server-side secret -- the pepper -- which lives outside the
//! database. A breach of the table without the pepper yields nothing to match against.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Argon2id parameters.
///
/// VALIDATED AT THE CALL SITE, NOT TRUSTED TO THE LIBRARY. std's Argon2 checks very little
/// about these -- a silently-weak Argon2 is a silently-weak defence, and it looks exactly like
/// a strong one.
///
/// 19 MiB / 2 iterations / 1 lane is the OWASP minimum for Argon2id. We assert it rather than
/// hope for it.
pub const argon = struct {
    pub const memory_kib: u32 = 19_456; // 19 MiB
    pub const iterations: u32 = 2;
    pub const lanes: u24 = 1;

    pub const params: std.crypto.pwhash.argon2.Params = .{
        .t = iterations,
        .m = memory_kib,
        .p = lanes,
    };

    comptime {
        // The OWASP floor. If someone lowers these to make a test faster, the build stops.
        std.debug.assert(memory_kib >= 19_456);
        std.debug.assert(iterations >= 2);
        std.debug.assert(lanes >= 1);
    }
};

pub const Salt = [16]u8;
pub const Verifier = [32]u8;
pub const ContactHash = [32]u8;

pub const Error = Io.RandomSecureError || Allocator.Error || error{WeakParameters};

/// SHELL. A fingerprint of a contact point, keyed with the server's pepper.
///
/// Keyed, not plain: email addresses are enumerable, so an unkeyed hash of one is barely better
/// than the address itself. With the pepper held outside the database, a stolen table cannot be
/// matched against a list of addresses.
///
/// The address itself is consumed here and is not returned, stored, or logged -- the same
/// discipline the quantizer applies to a coordinate.
pub fn hashContact(pepper: []const u8, contact: []const u8) ContactHash {
    var out: ContactHash = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&out, contact, pepper);
    return out;
}

/// SHELL. A fresh salt. From the OS, never from a deterministic mixer (B3).
pub fn newSalt(io: Io) Io.RandomSecureError!Salt {
    var salt: Salt = undefined;
    try io.randomSecure(&salt);
    return salt;
}

/// SHELL. Turn a password into a verifier. Argon2id, deliberately expensive.
pub fn derive(io: Io, gpa: Allocator, password: []const u8, salt: Salt) Error!Verifier {
    var verifier: Verifier = undefined;
    std.crypto.pwhash.argon2.kdf(
        gpa,
        &verifier,
        password,
        &salt,
        argon.params,
        .argon2id,
        io,
    ) catch return Error.WeakParameters;
    return verifier;
}

/// SHELL. Does this password match? CONSTANT TIME.
///
/// Never a byte-by-byte compare, and never an early return on the first differing byte: a
/// compare that exits early leaks, through its own duration, how much of the secret the
/// attacker guessed correctly. `timing_safe.eql` compares every byte, every time.
pub fn verify(io: Io, gpa: Allocator, password: []const u8, salt: Salt, expected: Verifier) bool {
    const actual = derive(io, gpa, password, salt) catch return false;
    return std.crypto.timing_safe.eql(Verifier, actual, expected);
}

/// SHELL. A verification code to prove control of a contact point. Six digits, from the OS.
///
/// Short-lived and single-use -- the account layer enforces that; this only mints it.
pub fn newVerificationCode(io: Io) Io.RandomSecureError!u32 {
    var bytes: [4]u8 = undefined;
    try io.randomSecure(&bytes);
    return std.mem.readInt(u32, &bytes, .little) % 1_000_000;
}

const testing = std.testing;

test "a password verifies, and a wrong one does not" {
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const salt = try newSalt(io);
    const verifier = try derive(io, gpa, "correct horse battery staple", salt);

    try testing.expect(verify(io, gpa, "correct horse battery staple", salt, verifier));
    try testing.expect(!verify(io, gpa, "correct horse battery stapl", salt, verifier));
    try testing.expect(!verify(io, gpa, "", salt, verifier));
}

test "the same password under a different salt is a different verifier" {
    // Otherwise a stolen table tells an attacker which accounts share a password, and one
    // cracked password cracks every account that shares it.
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const a = try derive(io, gpa, "hunter2", try newSalt(io));
    const b = try derive(io, gpa, "hunter2", try newSalt(io));

    try testing.expect(!std.mem.eql(u8, &a, &b));
}

test "the contact hash is keyed, so a stolen table cannot be matched against a list of emails" {
    // Email addresses are enumerable. An UNKEYED hash of one is barely better than the address:
    // an attacker with the table hashes a list of candidate addresses and matches. The pepper
    // lives outside the database, so a stolen table has nothing to match against.
    const address = "someone@example.com";

    const with_our_pepper = hashContact("the server's secret pepper", address);
    const with_another = hashContact("a different pepper", address);

    try testing.expect(!std.mem.eql(u8, &with_our_pepper, &with_another));

    // And it is stable: the same address under the same pepper is the same fingerprint, which is
    // the entire point -- duplicate detection without a directory of who is who.
    try testing.expectEqualSlices(
        u8,
        &with_our_pepper,
        &hashContact("the server's secret pepper", address),
    );
}

test "a verification code is in range and comes from the OS" {
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const code = try newVerificationCode(io);
        try testing.expect(code < 1_000_000);
    }
}
