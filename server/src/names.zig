//! Name rules at entry: callsigns, clan names and clan tags. A short blocklist of slurs and plain
//! obscenities, with simple look-alike folding ("Sh1t" is "shit"). The whole list lives here.
//!
//! Two tiers keep innocent names (the Scunthorpe problem) safe:
//!   - `severe` terms are caught anywhere in the name, separators ignored.
//!   - `whole_word` terms are caught only as a word of their own: the name is split at `_`, `-`,
//!     spaces, digits and capital letters ("TheCuntKing" has the word "cunt", "Scunthorpe" does not).
//! A name typed as one lowercase run, such as "iamacunt", gets past the second tier. That is the
//! price of not blocking "Scunthorpe"; player reports and `admin rename` cover the rest.

const std = @import("std");

/// Caught as a substring of the folded name.
const severe = [_][]const u8{
    "nigger", "nigga", "faggot", "fuck", "kkk", "hitler", "tranny", "pedophile", "paedophile",
};

/// Caught only as a whole word of the name.
const whole_word = [_][]const u8{
    "shit",   "cunt", "bitch",   "whore", "slut", "rapist", "rape",    "nazi",     "kike",
    "chink",  "spic", "retard",  "pussy", "twat", "penis",  "vagina",  "dildo",    "porn",
    "molest", "fag",  "dyke",    "coon",  "gook", "negro",  "wetback", "jihadist", "cock",
    "dick",   "cum",  "asshole",
};

/// The message shown for a rejected name.
pub const rejection = "That name is not allowed here. Please pick another name.";

/// Lowercase, with the digits and symbols people use for letters turned back into letters.
fn fold(c: u8) u8 {
    return switch (c) {
        '0' => 'o',
        '1' => 'i',
        '3' => 'e',
        '4' => 'a',
        '5' => 's',
        '7' => 't',
        '$' => 's',
        '@' => 'a',
        '!' => 'i',
        else => std.ascii.toLower(c),
    };
}

/// Runs of one letter shrink to a single letter, so "shiiit" and "fuuuck" match "shit" and "fuck".
fn collapse(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (n > 0 and buf[n - 1] == c) continue;
        if (n == buf.len) break;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

fn wordBlocked(word: []const u8) bool {
    if (word.len == 0) return false;
    var wb: [64]u8 = undefined;
    const w = collapse(&wb, word);
    for (whole_word) |term| {
        var tb: [32]u8 = undefined;
        if (std.mem.eql(u8, w, collapse(&tb, term))) return true;
    }
    return false;
}

/// False when the name contains something on the list.
pub fn allowed(name: []const u8) bool {
    if (name.len > 64) return false;

    // Severe terms: every letter of the name, separators and stray digits dropped.
    var all_buf: [64]u8 = undefined;
    var an: usize = 0;
    for (name) |c| {
        const f = fold(c);
        if (std.ascii.isAlphabetic(f)) {
            all_buf[an] = f;
            an += 1;
        }
    }
    const all = all_buf[0..an];
    var cb: [64]u8 = undefined;
    const squeezed = collapse(&cb, all);
    for (severe) |term| {
        if (std.mem.indexOf(u8, all, term) != null) return false;
        // "kkk" is already a repeat; the squeezed form only helps longer terms.
        if (term.len > 3 and std.mem.indexOf(u8, squeezed, term) != null) return false;
    }

    // Whole words: split at separators, at a digit with no look-alike letter, and at a capital
    // letter that follows a lowercase one.
    var word: [64]u8 = undefined;
    var n: usize = 0;
    var prev_lower = false;
    for (name) |c| {
        const sep = c == '_' or c == '-' or c == ' ' or c == '.';
        if (sep or (std.ascii.isUpper(c) and prev_lower)) {
            if (wordBlocked(word[0..n])) return false;
            n = 0;
        }
        prev_lower = std.ascii.isLower(c);
        if (sep) continue;
        const f = fold(c);
        if (!std.ascii.isAlphabetic(f)) {
            if (wordBlocked(word[0..n])) return false;
            n = 0;
            continue;
        }
        word[n] = f;
        n += 1;
    }
    return !wordBlocked(word[0..n]);
}

test "obscenities and slurs are blocked, with look-alikes" {
    try std.testing.expect(!allowed("Fuck_You"));
    try std.testing.expect(!allowed("Sh1t_lord"));
    try std.testing.expect(!allowed("5H1T"));
    try std.testing.expect(!allowed("shiiit"));
    try std.testing.expect(!allowed("fuuuck"));
    try std.testing.expect(!allowed("TheCuntKing"));
    try std.testing.expect(!allowed("cunt69"));
    try std.testing.expect(!allowed("big-bitch"));
    try std.testing.expect(!allowed("xX_n1gg3r_Xx"));
    try std.testing.expect(!allowed("Hitler"));
    try std.testing.expect(!allowed("KKK"));
    try std.testing.expect(!allowed("F4GG0T"));
    try std.testing.expect(!allowed("Zombie Whore"));
}

test "innocent names pass (Scunthorpe)" {
    const fine = [_][]const u8{
        "Scunthorpe", "Assassin",   "Cocktail", "Dickens", "Shitake",  "Penistone", "Cumberland",
        "Grey_Fox",   "Last Light", "Raiders",  "Gookie",  "Rapeseed", "Niger",     "Nigeria",
        "Analyst",    "Skull_Kid",  "Kikeriki",
    };
    for (fine) |n| try std.testing.expect(allowed(n));
}
