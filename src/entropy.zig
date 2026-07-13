//! SHELL (B1, B3). Cryptographically secure randomness. The only source of it.
//!
//! Randomness is I/O (B3), and this is the one place the system asks the operating system for
//! it. The core cannot reach this function, and it must not want to.
//!
//! ============================================================================
//! WHY THIS FILE EXISTS, WRITTEN DOWN SO THE MISTAKE IS NOT REPEATED
//!
//! The first version of the session layer minted session ids with `rand.draw` -- the
//! splitmix64 mixer written for the tick. That is a catastrophic mistake dressed as a
//! convenience, and it is worth naming precisely:
//!
//!   1. splitmix64 is a BIJECTION. It is trivially invertible. Given an output you can walk
//!      it backwards to its input.
//!   2. Its inputs were the server seed, the player id, and a constant -- values an attacker
//!      either knows, can guess, or can enumerate.
//!   3. Therefore SESSION IDS WERE FORGEABLE. An attacker who held their own session could
//!      invert the mix, recover the structure, and derive other players' sessions.
//!
//! A forged session in this game means impersonating a real person and moving where the
//! system believes they are. It is the closest thing to a catastrophic failure this design
//! has, and it was introduced by reaching for the mixer that happened to be nearby.
//!
//! The deterministic mixer in `rand.zig` is for the TICK. It exists so a fight replays. It is
//! not a source of secrets and it never will be. A deterministic PRNG and a CSPRNG are
//! different tools that look identical at the call site, and that is exactly why the rule
//! (B3: randomness is I/O, and I/O lives in the shell) exists.
//!
//! Note the language agrees: `Io.randomSecure` requires an `Io` handle, so the core -- which
//! has no `Io` -- structurally cannot call it. The rule and the type system say the same thing.

const std = @import("std");
const protocol = @import("protocol.zig");

const Io = std.Io;

/// SHELL. A fresh, unguessable session id, straight from the operating system.
///
/// `randomSecure` always makes a syscall for fresh entropy and has no fallback: if the OS
/// cannot give us randomness, we FAIL rather than quietly produce a predictable value. A
/// silently-degraded CSPRNG is worse than none, because it looks like it is working.
pub fn newSession(io: Io) Io.RandomSecureError!protocol.SessionId {
    var bytes: [8]u8 = undefined;
    try io.randomSecure(&bytes);
    return @enumFromInt(std.mem.readInt(u64, &bytes, .little));
}

/// SHELL. Fresh secure bytes, for anything else that must not be guessable.
pub fn secure(io: Io, buffer: []u8) Io.RandomSecureError!void {
    return io.randomSecure(buffer);
}
