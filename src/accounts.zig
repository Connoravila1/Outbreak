//! CORE (B1, B2). Accounts: who exists, and how often they may try.
//!
//! Plain data and pure functions. The crypto lives in `credential.zig`, which is shell because
//! it must be -- Argon2 and the CSPRNG both need an `Io` handle the core does not have. This
//! module never sees a password, never sees an email, and never sees a clock: it is handed
//! fingerprints and a tick index, and it decides things.
//!
//! ============================================================================
//! ACCOUNT CREATION IS THE FARM'S FRONT DOOR (H5)
//!
//! The one attack this design is genuinely vulnerable to is k sock-puppet accounts spoofed into
//! a single cell to manufacture a quorum. Farm DETECTION is built (integrity.zig: a cluster of
//! accounts that only ever appear together and never apart). Farm DETERRENCE is here, and it is
//! two things:
//!
//!   1. ONE CONTACT POINT, ONE ACCOUNT. A duplicate contact fingerprint is refused. This is the
//!      entire reason we collect a contact point at all -- not to know who anyone is, but to
//!      know whether we have seen them before. The address itself is never stored (see
//!      credential.zig on why a plaintext directory would turn a meaningless breach into a list
//!      of named people and the rooms they were in).
//!
//!   2. RATE LIMITS ON CREATION AND LOGIN, INDEPENDENTLY. Account creation is the single most
//!      abuse-prone endpoint in any system, and here it is also the thing a farm needs to do a
//!      hundred times. Login is rate-limited separately, because Argon2 is deliberately
//!      expensive and an unlimited login endpoint is a CPU-exhaustion vector pointed at
//!      ourselves.
//!
//! NOTHING HERE BANS ANYBODY (H4). A rate limit is a "not right now", not a punishment, and
//! there is no function in this codebase that turns a suspicion into an account action.

const std = @import("std");
const combat = @import("combat.zig");
const world_mod = @import("world.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Faction = world_mod.Faction;
const PlayerId = world_mod.PlayerId;

/// A fingerprint of a contact point. Never the contact point itself.
pub const ContactHash = [32]u8;
pub const Salt = [16]u8;
pub const Verifier = [32]u8;

/// One account.
///
/// A7.2: cold struct, size guard waived -- one per player, read at login and never walked in a
/// hot loop. The presences are the hot thing, and they are guarded.
///
/// Note what is NOT here: an email, a phone number, a name, a handle, or an IP address. There is
/// nothing in this record that identifies a human being, and that is deliberate -- a breach of
/// this table yields fingerprints, not people.
pub const Account = struct {
    player: PlayerId,
    /// Chosen once, at registration, permanently (GAME_DESIGN §3.2).
    faction: Faction,
    salt: Salt,
    verifier: Verifier,
};

pub const Error = error{
    ContactAlreadyUsed,
    NoSuchAccount,
    /// Not a punishment. A "not right now" (H4).
    TooManyAttempts,
};

/// PROVISIONAL.
pub const Limits = struct {
    /// Accounts creatable from one source per window. A farm needs many; a human needs one.
    creations_per_window: u32 = 3,
    /// Login attempts per account per window. Argon2 is expensive on purpose, and that cost
    /// points both ways -- an unlimited login endpoint is a CPU-exhaustion vector aimed at us.
    logins_per_window: u32 = 10,
    /// 120 ticks = one hour at a 30-second tick.
    window_ticks: u64 = 120,

    pub const default: Limits = .{};
};

const Counter = struct {
    attempts: u32,
    window_start: u64,
};

pub const Accounts = struct {
    /// Keyed by contact fingerprint: one contact point, one account.
    by_contact: std.AutoHashMapUnmanaged(ContactHash, Account),
    /// Attempts to create an account, keyed by whatever the shell decided a "source" is.
    creations: std.AutoHashMapUnmanaged(u64, Counter),
    /// Login attempts, keyed by contact fingerprint.
    logins: std.AutoHashMapUnmanaged(ContactHash, Counter),

    next_player: u32,

    pub const empty: Accounts = .{
        .by_contact = .empty,
        .creations = .empty,
        .logins = .empty,
        .next_player = 1,
    };
};

/// Stable account material suitable for a durable snapshot. It contains only a keyed contact
/// fingerprint and password-verification material—never the contact point or password itself.
pub const Stored = struct {
    contact: ContactHash,
    account: Account,
};

pub fn deinit(accounts: *Accounts, gpa: Allocator) void {
    accounts.by_contact.deinit(gpa);
    accounts.creations.deinit(gpa);
    accounts.logins.deinit(gpa);
    accounts.* = .empty;
}

/// CORE. Register an account.
///
/// The shell has already verified control of the contact point and hashed it, and has already
/// derived the verifier. This function decides only whether it is allowed.
pub fn register(
    accounts: *Accounts,
    gpa: Allocator,
    contact: ContactHash,
    salt: Salt,
    verifier: Verifier,
    faction: Faction,
    source: u64,
    tick: u64,
    limits: Limits,
) (Allocator.Error || Error)!Account {
    if (!try allow(u64, &accounts.creations, gpa, source, tick, limits.creations_per_window, limits.window_ticks)) {
        return Error.TooManyAttempts;
    }

    // ONE CONTACT POINT, ONE ACCOUNT. The farm's front door, closed.
    if (accounts.by_contact.contains(contact)) return Error.ContactAlreadyUsed;

    const account: Account = .{
        .player = @enumFromInt(accounts.next_player),
        .faction = faction,
        .salt = salt,
        .verifier = verifier,
    };
    accounts.next_player += 1;

    try accounts.by_contact.put(gpa, contact, account);
    return account;
}

/// CORE. Look up an account to log in to, and count the attempt.
///
/// The attempt is counted BEFORE the password is checked, and the account is returned whether
/// or not the password will turn out to be right -- the shell does the constant-time compare.
/// Counting after a successful check would let an attacker make unlimited *failed* guesses.
pub fn beginLogin(
    accounts: *Accounts,
    gpa: Allocator,
    contact: ContactHash,
    tick: u64,
    limits: Limits,
) (Allocator.Error || Error)!Account {
    if (!try allow(ContactHash, &accounts.logins, gpa, contact, tick, limits.logins_per_window, limits.window_ticks)) {
        return Error.TooManyAttempts;
    }

    return accounts.by_contact.get(contact) orelse Error.NoSuchAccount;
}

/// CORE. A successful login clears the attempt counter for that account.
pub fn loginSucceeded(accounts: *Accounts, contact: ContactHash) void {
    _ = accounts.logins.remove(contact);
}

pub fn storedSorted(accounts: *const Accounts, gpa: Allocator) Allocator.Error![]Stored {
    const entries = try gpa.alloc(Stored, accounts.by_contact.count());
    var i: usize = 0;
    var it = accounts.by_contact.iterator();
    while (it.next()) |entry| : (i += 1) entries[i] = .{
        .contact = entry.key_ptr.*,
        .account = entry.value_ptr.*,
    };
    const Sort = struct {
        fn lessThan(_: void, a: Stored, b: Stored) bool {
            return std.mem.order(u8, &a.contact, &b.contact) == .lt;
        }
    };
    std.mem.sort(Stored, entries, {}, Sort.lessThan);
    return entries;
}

pub const RestoreError = Allocator.Error || error{BadValue};

/// Rebuild the durable account index. Login/creation rate counters intentionally start empty;
/// they are short-lived abuse controls, not player progress.
pub fn restore(gpa: Allocator, entries: []const Stored, next_player: u32) RestoreError!Accounts {
    var accounts: Accounts = .empty;
    errdefer deinit(&accounts, gpa);
    try accounts.by_contact.ensureTotalCapacity(gpa, @intCast(entries.len));

    var players: std.AutoHashMapUnmanaged(PlayerId, void) = .empty;
    defer players.deinit(gpa);
    try players.ensureTotalCapacity(gpa, @intCast(entries.len));

    var highest: u32 = 0;
    for (entries) |entry| {
        const id = @intFromEnum(entry.account.player);
        if (id == 0 or accounts.by_contact.contains(entry.contact) or players.contains(entry.account.player))
            return error.BadValue;
        accounts.by_contact.putAssumeCapacity(entry.contact, entry.account);
        players.putAssumeCapacity(entry.account.player, {});
        highest = @max(highest, id);
    }
    if (next_player == 0 or next_player <= highest) return error.BadValue;
    accounts.next_player = next_player;
    return accounts;
}

pub fn nextPlayer(accounts: *const Accounts) u32 {
    return accounts.next_player;
}

/// Has this key exceeded its budget for the current window?
///
/// A fixed window, not a sliding one. A fixed window lets an attacker get up to 2x the budget
/// by straddling a boundary; the budget is small and the consequence is a delay rather than a
/// breach, so the simpler thing is correct here (F4). It is written down rather than discovered
/// later by someone who assumes it is sliding.
///
/// The tick is passed in. The core never asks what time it is (B3, B7).
fn allow(
    comptime Key: type,
    counters: *std.AutoHashMapUnmanaged(Key, Counter),
    gpa: Allocator,
    key: Key,
    tick: u64,
    budget: u32,
    window: u64,
) Allocator.Error!bool {
    const entry = try counters.getOrPut(gpa, key);

    // A fresh key, or a stale window: start counting again.
    if (!entry.found_existing or tick -| entry.value_ptr.window_start >= window) {
        entry.value_ptr.* = .{ .attempts = 1, .window_start = tick };
        return true;
    }

    if (entry.value_ptr.attempts >= budget) return false; // not right now (H4)

    entry.value_ptr.attempts += 1;
    return true;
}

const testing = std.testing;

fn fakeContact(n: u8) ContactHash {
    const hash: ContactHash = @splat(n);
    return hash;
}

test "one contact point, one account" {
    // THE FARM'S FRONT DOOR. Free unlimited account creation is what makes k sock-puppets in
    // one cell cheap, and a manufactured quorum is the one attack this design is actually
    // vulnerable to (H5).
    const gpa = testing.allocator;

    var accounts: Accounts = .empty;
    defer deinit(&accounts, gpa);

    const contact = fakeContact(1);
    const salt: Salt = @splat(0);
    const verifier: Verifier = @splat(0);

    _ = try register(&accounts, gpa, contact, salt, verifier, .human, 1, 0, .default);

    // The same contact point, a second time. Refused.
    try testing.expectError(
        Error.ContactAlreadyUsed,
        register(&accounts, gpa, contact, salt, verifier, .zombie, 1, 0, .default),
    );
}

test "account creation is rate limited" {
    const gpa = testing.allocator;
    const limits: Limits = .default;

    var accounts: Accounts = .empty;
    defer deinit(&accounts, gpa);

    const salt: Salt = @splat(0);
    const verifier: Verifier = @splat(0);
    const source: u64 = 0xABC;

    // A farm tries to spin up accounts as fast as it can, from one place.
    var made: u32 = 0;
    var i: u8 = 0;
    while (i < 20) : (i += 1) {
        if (register(&accounts, gpa, fakeContact(i), salt, verifier, .human, source, 0, limits)) |_| {
            made += 1;
        } else |err| {
            try testing.expectEqual(Error.TooManyAttempts, err);
        }
    }

    try testing.expectEqual(limits.creations_per_window, made);

    // And it is a "not right now", never a punishment (H4). An hour later, they may try again --
    // which is exactly what a real person who mistyped their email three times needs.
    const later = limits.window_ticks;
    _ = try register(&accounts, gpa, fakeContact(99), salt, verifier, .human, source, later, limits);
}

test "login is rate limited, and Argon2 is not a CPU-exhaustion vector" {
    // Argon2 is deliberately expensive. That cost points BOTH ways: an unlimited login endpoint
    // is a CPU-exhaustion attack aimed straight at our own server, and it needs no cleverness at
    // all -- just a loop.
    const gpa = testing.allocator;
    const limits: Limits = .default;

    var accounts: Accounts = .empty;
    defer deinit(&accounts, gpa);

    const contact = fakeContact(7);
    _ = try register(&accounts, gpa, contact, @splat(0), @splat(0), .human, 1, 0, limits);

    var attempts: u32 = 0;
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        if (beginLogin(&accounts, gpa, contact, 0, limits)) |_| {
            attempts += 1;
        } else |err| {
            try testing.expectEqual(Error.TooManyAttempts, err);
        }
    }

    try testing.expectEqual(limits.logins_per_window, attempts);
}

test "a successful login clears the counter" {
    const gpa = testing.allocator;
    const limits: Limits = .default;

    var accounts: Accounts = .empty;
    defer deinit(&accounts, gpa);

    const contact = fakeContact(3);
    _ = try register(&accounts, gpa, contact, @splat(0), @splat(0), .zombie, 1, 0, limits);

    // A few fat-fingered attempts, then the right one. A real person must not be locked out by
    // their own typing.
    _ = try beginLogin(&accounts, gpa, contact, 0, limits);
    _ = try beginLogin(&accounts, gpa, contact, 0, limits);
    loginSucceeded(&accounts, contact);

    var i: u32 = 0;
    while (i < limits.logins_per_window) : (i += 1) {
        _ = try beginLogin(&accounts, gpa, contact, 0, limits);
    }
}

test "an unknown contact point is not an account" {
    const gpa = testing.allocator;

    var accounts: Accounts = .empty;
    defer deinit(&accounts, gpa);

    try testing.expectError(
        Error.NoSuchAccount,
        beginLogin(&accounts, gpa, fakeContact(42), 0, .default),
    );
}

test "an account carries no punitive state" {
    // H4. A rate limit is a delay, not a punishment, and there is no code path anywhere from a
    // suspicion score to an account action -- the build guard rejects the function names that
    // would do it.
    //
    // This test is a second marker, on the data rather than the code: an Account has no field
    // that could hold a punishment. Someone adding one would have to delete this test to do it,
    // which is a deliberate act rather than a slip.
    //
    // (Amusing and worth recording: an earlier version of this comment quoted the forbidden
    // function name literally, and THE GUARD REJECTED THE COMMENT. A textual guard cannot tell a
    // mention from a use. That is a real limitation, it is the price of the guard being dumb
    // enough to be trustworthy, and the workaround is simply not to write the literal string.)
    inline for (@typeInfo(Account).@"struct".fields) |field| {
        try testing.expect(!std.mem.eql(u8, field.name, "banned"));
        try testing.expect(!std.mem.eql(u8, field.name, "suspended"));
        try testing.expect(!std.mem.eql(u8, field.name, "restricted"));
    }
}
