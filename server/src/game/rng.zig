//! Deterministic randomness. xoshiro256++ seeded through splitmix64, plus `hash` for deriving
//! stable seeds from (server_seed, cell, window, ...) tuples.

const std = @import("std");

fn splitmix(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    return mix(state.*);
}

/// The splitmix64 finaliser: a strong 64-bit bit mixer.
pub fn mix(x: u64) u64 {
    var z = x;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

pub const Rng = struct {
    s: [4]u64,

    pub fn init(seed: u64) Rng {
        var sm = seed;
        return .{ .s = .{ splitmix(&sm), splitmix(&sm), splitmix(&sm), splitmix(&sm) } };
    }

    pub fn next(self: *Rng) u64 {
        const r = std.math.rotl(u64, self.s[0] +% self.s[3], 23) +% self.s[0];
        const t = self.s[1] << 17;
        self.s[2] ^= self.s[0];
        self.s[3] ^= self.s[1];
        self.s[1] ^= self.s[2];
        self.s[0] ^= self.s[3];
        self.s[2] ^= t;
        self.s[3] = std.math.rotl(u64, self.s[3], 45);
        return r;
    }

    /// Uniform in [0, 1).
    pub fn float(self: *Rng) f64 {
        return @as(f64, @floatFromInt(self.next() >> 11)) * (1.0 / 9007199254740992.0);
    }

    /// Uniform in [lo, hi).
    pub fn range(self: *Rng, lo: f64, hi: f64) f64 {
        return lo + (hi - lo) * self.float();
    }

    /// Uniform integer in [0, n). `n` must be > 0.
    pub fn below(self: *Rng, n: u32) u32 {
        return @intCast((self.next() >> 32) * n >> 32);
    }

    /// Uniform integer in [lo, hi], both inclusive.
    pub fn intRange(self: *Rng, lo: i32, hi: i32) i32 {
        return lo + @as(i32, @intCast(self.below(@intCast(hi - lo + 1))));
    }

    pub fn chance(self: *Rng, p: f64) bool {
        return self.float() < p;
    }

    /// Index picked proportionally to `weights` (non-negative, at least one positive).
    pub fn weighted(self: *Rng, weights: []const f64) usize {
        var total: f64 = 0;
        for (weights) |w| total += w;
        var x = self.float() * total;
        for (weights, 0..) |w, i| {
            if (x < w) return i;
            x -= w;
        }
        // Floating-point leftovers: fall back to the last positive weight.
        var i = weights.len;
        while (i > 0) {
            i -= 1;
            if (weights[i] > 0) return i;
        }
        return 0;
    }
};

fn partBits(part: anytype) u64 {
    const T = @TypeOf(part);
    switch (@typeInfo(T)) {
        .int, .comptime_int => {
            const wide: i128 = part;
            return @truncate(@as(u128, @bitCast(wide)));
        },
        .bool => return @intFromBool(part),
        .@"enum" => return @intCast(@intFromEnum(part)),
        .pointer => {
            const bytes: []const u8 = part;
            return hashBytes(0x5bd1e995, bytes);
        },
        else => @compileError("rng.hash: unsupported part type " ++ @typeName(T)),
    }
}

pub fn hashBytes(seed: u64, bytes: []const u8) u64 {
    var h = mix(seed ^ 0xcbf29ce484222325);
    for (bytes) |b| h = mix(h ^ b) +% 0x9e3779b97f4a7c15;
    return mix(h ^ bytes.len);
}

/// Deterministic derivation: `hash(seed, .{ "e", cell, window, idx })`. Integers, enums, bools
/// and byte strings are accepted as parts; order matters.
pub fn hash(seed: u64, parts: anytype) u64 {
    var h = mix(seed ^ 0x2545f4914f6cdd1d);
    inline for (parts) |part| h = mix(h ^ partBits(part)) +% 0x9e3779b97f4a7c15;
    return mix(h);
}

/// Shorthand: an `Rng` seeded from `hash`.
pub fn derive(seed: u64, parts: anytype) Rng {
    return Rng.init(hash(seed, parts));
}

test "same seed, same stream; different seed, different stream" {
    var a = Rng.init(42);
    var b = Rng.init(42);
    var c = Rng.init(43);
    var differs = false;
    for (0..100) |_| {
        const x = a.next();
        try std.testing.expectEqual(x, b.next());
        if (x != c.next()) differs = true;
    }
    try std.testing.expect(differs);
}

test "float and range stay in bounds with sane mean" {
    var r = Rng.init(1);
    var sum: f64 = 0;
    const n = 100_000;
    for (0..n) |_| {
        const f = r.float();
        try std.testing.expect(f >= 0 and f < 1);
        const g = r.range(0.85, 1.15);
        try std.testing.expect(g >= 0.85 and g < 1.15);
        sum += f;
    }
    try std.testing.expectApproxEqAbs(0.5, sum / n, 0.01);
}

test "intRange is inclusive and uniform-ish" {
    var r = Rng.init(7);
    var counts = [_]u32{0} ** 5;
    for (0..50_000) |_| {
        const v = r.intRange(-2, 2);
        counts[@intCast(v + 2)] += 1;
    }
    for (counts) |c| try std.testing.expect(c > 9_000 and c < 11_000);
}

test "weighted respects proportions and skips zero weights" {
    var r = Rng.init(9);
    const w = [_]f64{ 1, 0, 3 };
    var counts = [_]u32{ 0, 0, 0 };
    for (0..40_000) |_| counts[r.weighted(&w)] += 1;
    try std.testing.expectEqual(@as(u32, 0), counts[1]);
    const ratio = @as(f64, @floatFromInt(counts[2])) / @as(f64, @floatFromInt(counts[0]));
    try std.testing.expectApproxEqAbs(3.0, ratio, 0.2);
}

test "hash is deterministic, order-sensitive and part-sensitive" {
    const a = hash(5, .{ "e", "dr5ru7k", @as(i64, 2849112), @as(u8, 1) });
    try std.testing.expectEqual(a, hash(5, .{ "e", "dr5ru7k", @as(i64, 2849112), @as(u8, 1) }));
    try std.testing.expect(a != hash(6, .{ "e", "dr5ru7k", @as(i64, 2849112), @as(u8, 1) }));
    try std.testing.expect(a != hash(5, .{ "e", "dr5ru7k", @as(i64, 2849112), @as(u8, 2) }));
    try std.testing.expect(hash(5, .{ 1, 2 }) != hash(5, .{ 2, 1 }));
    try std.testing.expect(hash(5, .{"ab"}) != hash(5, .{"ba"}));
}
