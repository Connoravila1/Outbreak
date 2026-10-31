//! A small SQLite wrapper: open, exec, prepared statements with index binding, transactions, and
//! the schema with migrations keyed by `PRAGMA user_version`.
//!
//! SQLite is compiled in from vendor/sqlite (see build.zig). The few C functions used are declared
//! here by hand. Text and blob values returned by a statement are valid until the next `step`,
//! `reset` or `finalize`; copy them if they must live longer. Text passed to `bind*` must outlive
//! the statement's next `step` (the wrapper binds with SQLITE_STATIC).

const std = @import("std");

const Handle = opaque {};
const Stmt_ = opaque {};

const sqlite = struct {
    extern fn sqlite3_open_v2(filename: [*:0]const u8, out: *?*Handle, flags: c_int, vfs: ?[*:0]const u8) c_int;
    extern fn sqlite3_close(db: *Handle) c_int;
    extern fn sqlite3_exec(db: *Handle, sql: [*:0]const u8, cb: ?*anyopaque, arg: ?*anyopaque, err: ?*?[*:0]u8) c_int;
    extern fn sqlite3_errmsg(db: *Handle) [*:0]const u8;
    extern fn sqlite3_busy_timeout(db: *Handle, ms: c_int) c_int;
    extern fn sqlite3_prepare_v2(db: *Handle, sql: [*]const u8, n: c_int, out: *?*Stmt_, tail: ?*?[*]const u8) c_int;
    extern fn sqlite3_finalize(s: *Stmt_) c_int;
    extern fn sqlite3_reset(s: *Stmt_) c_int;
    extern fn sqlite3_step(s: *Stmt_) c_int;
    extern fn sqlite3_bind_int64(s: *Stmt_, i: c_int, v: i64) c_int;
    extern fn sqlite3_bind_double(s: *Stmt_, i: c_int, v: f64) c_int;
    extern fn sqlite3_bind_text(s: *Stmt_, i: c_int, p: [*]const u8, n: c_int, d: ?*anyopaque) c_int;
    extern fn sqlite3_bind_null(s: *Stmt_, i: c_int) c_int;
    extern fn sqlite3_column_int64(s: *Stmt_, i: c_int) i64;
    extern fn sqlite3_column_double(s: *Stmt_, i: c_int) f64;
    extern fn sqlite3_column_text(s: *Stmt_, i: c_int) ?[*]const u8;
    extern fn sqlite3_column_bytes(s: *Stmt_, i: c_int) c_int;
    extern fn sqlite3_column_type(s: *Stmt_, i: c_int) c_int;
    extern fn sqlite3_changes(db: *Handle) c_int;
    extern fn sqlite3_last_insert_rowid(db: *Handle) i64;
};

const ok = 0;
const row = 100;
const done = 101;
const open_readwrite = 0x2;
const open_create = 0x4;
const open_fullmutex = 0x10000;
const type_null = 5;

const log = std.log.scoped(.db);

pub const Error = error{ Sqlite, OutOfMemory };

pub const Db = struct {
    handle: *Handle,
    /// Tests that expect failures set this to keep expected errors out of the log.
    quiet: bool = false,

    /// Open (creating if needed) and migrate. `path` may be ":memory:".
    pub fn open(path: [:0]const u8) Error!Db {
        var h: ?*Handle = null;
        const rc = sqlite.sqlite3_open_v2(path.ptr, &h, open_readwrite | open_create | open_fullmutex, null);
        if (rc != ok) {
            if (h) |hh| _ = sqlite.sqlite3_close(hh);
            log.err("cannot open database (code {d})", .{rc});
            return error.Sqlite;
        }
        var self = Db{ .handle = h.? };
        errdefer self.close();
        _ = sqlite.sqlite3_busy_timeout(self.handle, 5000);
        try self.exec("PRAGMA journal_mode = WAL");
        try self.exec("PRAGMA synchronous = NORMAL");
        try self.exec("PRAGMA foreign_keys = ON");
        try self.migrate();
        return self;
    }

    pub fn close(self: *Db) void {
        _ = sqlite.sqlite3_close(self.handle);
        self.* = undefined;
    }

    fn fail(self: *const Db, what: []const u8) Error {
        if (!self.quiet) log.err("{s}: {s}", .{ what, sqlite.sqlite3_errmsg(self.handle) });
        return error.Sqlite;
    }

    /// Run SQL without parameters (may contain several statements).
    pub fn exec(self: *Db, sql: [:0]const u8) Error!void {
        if (sqlite.sqlite3_exec(self.handle, sql.ptr, null, null, null) != ok) return self.fail("exec");
    }

    pub fn begin(self: *Db) Error!void {
        try self.exec("BEGIN IMMEDIATE");
    }

    pub fn commit(self: *Db) Error!void {
        try self.exec("COMMIT");
    }

    pub fn rollback(self: *Db) void {
        self.exec("ROLLBACK") catch {};
    }

    pub fn prepare(self: *Db, sql: []const u8) Error!Stmt {
        var s: ?*Stmt_ = null;
        if (sqlite.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &s, null) != ok) return self.fail("prepare");
        return .{ .s = s.?, .db = self };
    }

    /// Prepare, bind `args` (a tuple), and step until done. Rows are ignored.
    pub fn run(self: *Db, sql: []const u8, args: anytype) Error!void {
        var st = try self.prepare(sql);
        defer st.finalize();
        try st.bindAll(args);
        while (try st.step()) {}
    }

    /// Prepare and bind; the caller steps through rows.
    pub fn query(self: *Db, sql: []const u8, args: anytype) Error!Stmt {
        var st = try self.prepare(sql);
        errdefer st.finalize();
        try st.bindAll(args);
        return st;
    }

    /// First column of the first row as an integer, or null if there is no row.
    pub fn scalar(self: *Db, sql: []const u8, args: anytype) Error!?i64 {
        var st = try self.query(sql, args);
        defer st.finalize();
        if (!try st.step()) return null;
        if (st.isNull(0)) return null;
        return st.int(0);
    }

    pub fn changes(self: *const Db) i64 {
        return sqlite.sqlite3_changes(self.handle);
    }

    pub fn lastInsertId(self: *const Db) i64 {
        return sqlite.sqlite3_last_insert_rowid(self.handle);
    }

    // --- Meta -----------------------------------------------------------------------------------

    pub fn metaInt(self: *Db, key: []const u8) Error!?i64 {
        return self.scalar("SELECT CAST(value AS INTEGER) FROM meta WHERE key = ?", .{key});
    }

    pub fn setMetaInt(self: *Db, key: []const u8, value: i64) Error!void {
        try self.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", .{ key, value });
    }

    // --- Migrations -----------------------------------------------------------------------------

    fn migrate(self: *Db) Error!void {
        const current: usize = @intCast(try self.scalar("PRAGMA user_version", .{}) orelse 0);
        if (current > migrations.len) {
            if (!self.quiet) log.err("database is from a newer server (schema {d}, this build knows {d})", .{ current, migrations.len });
            return error.Sqlite;
        }
        for (migrations[current..], current..) |sql, i| {
            try self.begin();
            errdefer self.rollback();
            try self.exec(sql);
            var buf: [48]u8 = undefined;
            const pragma = std.fmt.bufPrintZ(&buf, "PRAGMA user_version = {d}", .{i + 1}) catch unreachable;
            try self.exec(pragma);
            try self.commit();
            log.info("database migrated to schema {d}", .{i + 1});
        }
    }
};

pub const Stmt = struct {
    s: *Stmt_,
    db: *Db,

    pub fn finalize(self: *Stmt) void {
        _ = sqlite.sqlite3_finalize(self.s);
    }

    pub fn reset(self: *Stmt) void {
        _ = sqlite.sqlite3_reset(self.s);
    }

    /// Advance: true if a row is available, false when finished.
    pub fn step(self: *Stmt) Error!bool {
        const rc = sqlite.sqlite3_step(self.s);
        if (rc == row) return true;
        if (rc == done) return false;
        return self.db.fail("step");
    }

    /// Bind one value to the 1-based parameter `i`.
    pub fn bind(self: *Stmt, i: usize, value: anytype) Error!void {
        const T = @TypeOf(value);
        const idx: c_int = @intCast(i);
        const rc = switch (@typeInfo(T)) {
            .int, .comptime_int => sqlite.sqlite3_bind_int64(self.s, idx, @intCast(value)),
            .bool => sqlite.sqlite3_bind_int64(self.s, idx, @intFromBool(value)),
            .float, .comptime_float => sqlite.sqlite3_bind_double(self.s, idx, value),
            .@"enum" => sqlite.sqlite3_bind_int64(self.s, idx, @intFromEnum(value)),
            .null => sqlite.sqlite3_bind_null(self.s, idx),
            .optional => if (value) |v| return self.bind(i, v) else sqlite.sqlite3_bind_null(self.s, idx),
            .pointer => blk: {
                const s: []const u8 = value;
                break :blk sqlite.sqlite3_bind_text(self.s, idx, if (s.len == 0) "" else s.ptr, @intCast(s.len), null);
            },
            else => @compileError("db: cannot bind " ++ @typeName(T)),
        };
        if (rc != ok) return self.db.fail("bind");
    }

    pub fn bindAll(self: *Stmt, args: anytype) Error!void {
        inline for (args, 0..) |a, i| try self.bind(i + 1, a);
    }

    pub fn int(self: *Stmt, col: usize) i64 {
        return sqlite.sqlite3_column_int64(self.s, @intCast(col));
    }

    pub fn real(self: *Stmt, col: usize) f64 {
        return sqlite.sqlite3_column_double(self.s, @intCast(col));
    }

    pub fn isNull(self: *Stmt, col: usize) bool {
        return sqlite.sqlite3_column_type(self.s, @intCast(col)) == type_null;
    }

    pub fn optInt(self: *Stmt, col: usize) ?i64 {
        return if (self.isNull(col)) null else self.int(col);
    }

    /// Text of a column; empty for NULL. Valid until the next step/reset/finalize.
    pub fn text(self: *Stmt, col: usize) []const u8 {
        const p = sqlite.sqlite3_column_text(self.s, @intCast(col)) orelse return "";
        const n: usize = @intCast(sqlite.sqlite3_column_bytes(self.s, @intCast(col)));
        return p[0..n];
    }

    pub fn optText(self: *Stmt, col: usize) ?[]const u8 {
        return if (self.isNull(col)) null else self.text(col);
    }

    /// Text copied into `gpa`.
    pub fn dupe(self: *Stmt, gpa: std.mem.Allocator, col: usize) std.mem.Allocator.Error![]u8 {
        return gpa.dupe(u8, self.text(col));
    }
};

// --- Schema -----------------------------------------------------------------------------------------

/// One entry per schema version. Never edit a shipped entry; append a new one.
const migrations = [_][:0]const u8{
    \\CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    \\
    \\CREATE TABLE players (
    \\  id INTEGER PRIMARY KEY,
    \\  callsign TEXT NOT NULL,
    \\  callsign_lc TEXT NOT NULL UNIQUE,
    \\  token_hash TEXT NOT NULL UNIQUE,
    \\  recovery_hash TEXT NOT NULL UNIQUE,
    \\  faction INTEGER,
    \\  level INTEGER NOT NULL DEFAULT 1,
    \\  xp INTEGER NOT NULL DEFAULT 0,
    \\  hp INTEGER NOT NULL DEFAULT 0,
    \\  hp_at INTEGER NOT NULL DEFAULT 0,
    \\  downed_until INTEGER,
    \\  salvage INTEGER NOT NULL DEFAULT 0,
    \\  expansions INTEGER NOT NULL DEFAULT 0,
    \\  avatar TEXT,
    \\  abilities TEXT NOT NULL DEFAULT '',
    \\  created_at INTEGER NOT NULL,
    \\  last_seen INTEGER NOT NULL,
    \\  last_pvp_at INTEGER NOT NULL DEFAULT 0,
    \\  streak INTEGER NOT NULL DEFAULT 0,
    \\  last_claim_day INTEGER NOT NULL DEFAULT -10,
    \\  mday INTEGER NOT NULL DEFAULT -1,
    \\  mlevel INTEGER NOT NULL DEFAULT 1,
    \\  mweek INTEGER NOT NULL DEFAULT -1,
    \\  wlevel INTEGER NOT NULL DEFAULT 1,
    \\  walk_day INTEGER NOT NULL DEFAULT -1,
    \\  walk_xp_today INTEGER NOT NULL DEFAULT 0,
    \\  wins INTEGER NOT NULL DEFAULT 0,
    \\  losses INTEGER NOT NULL DEFAULT 0,
    \\  contacts INTEGER NOT NULL DEFAULT 0,
    \\  echoes INTEGER NOT NULL DEFAULT 0,
    \\  caches INTEGER NOT NULL DEFAULT 0,
    \\  distance_m INTEGER NOT NULL DEFAULT 0,
    \\  clan_id INTEGER,
    \\  clan_role TEXT
    \\);
    \\CREATE INDEX players_last_seen ON players(last_seen);
    \\CREATE INDEX players_clan ON players(clan_id);
    \\
    \\CREATE TABLE items (
    \\  id INTEGER PRIMARY KEY,
    \\  uid TEXT NOT NULL UNIQUE,
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  base INTEGER NOT NULL,
    \\  rarity INTEGER NOT NULL,
    \\  upgrade INTEGER NOT NULL DEFAULT 0,
    \\  uniq INTEGER NOT NULL DEFAULT -1,
    \\  perk_count INTEGER NOT NULL DEFAULT 0,
    \\  perk0 INTEGER NOT NULL DEFAULT 0,
    \\  perk1 INTEGER NOT NULL DEFAULT 0,
    \\  equipped INTEGER NOT NULL DEFAULT 0
    \\);
    \\CREATE INDEX items_player ON items(player_id);
    \\
    \\CREATE TABLE consumables (
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  kind INTEGER NOT NULL,
    \\  n INTEGER NOT NULL,
    \\  PRIMARY KEY (player_id, kind)
    \\);
    \\
    \\CREATE TABLE buffs (
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  kind TEXT NOT NULL,
    \\  until INTEGER NOT NULL,
    \\  PRIMARY KEY (player_id, kind)
    \\);
    \\
    \\CREATE TABLE mission_progress (
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  mid TEXT NOT NULL,
    \\  progress INTEGER NOT NULL DEFAULT 0,
    \\  claimed INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY (player_id, mid)
    \\);
    \\
    \\CREATE TABLE events (
    \\  id INTEGER PRIMARY KEY,
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  at INTEGER NOT NULL,
    \\  type TEXT NOT NULL,
    \\  text TEXT NOT NULL,
    \\  battle TEXT,
    \\  rewards TEXT,
    \\  delivered INTEGER NOT NULL DEFAULT 0
    \\);
    \\CREATE INDEX events_player ON events(player_id, id);
    \\
    \\CREATE TABLE war_district (
    \\  week INTEGER NOT NULL,
    \\  district TEXT NOT NULL,
    \\  faction INTEGER NOT NULL,
    \\  points INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY (week, district, faction)
    \\);
    \\
    \\CREATE TABLE war_player (
    \\  week INTEGER NOT NULL,
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  district TEXT NOT NULL,
    \\  points INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY (week, player_id, district)
    \\);
    \\
    \\CREATE TABLE clans (
    \\  id INTEGER PRIMARY KEY,
    \\  name TEXT NOT NULL,
    \\  name_lc TEXT NOT NULL UNIQUE,
    \\  tag TEXT NOT NULL,
    \\  tag_lc TEXT NOT NULL UNIQUE,
    \\  code TEXT NOT NULL UNIQUE,
    \\  faction INTEGER NOT NULL,
    \\  created_at INTEGER NOT NULL
    \\);
    \\
    \\CREATE TABLE clan_chat (
    \\  id INTEGER PRIMARY KEY,
    \\  clan_id INTEGER NOT NULL REFERENCES clans(id) ON DELETE CASCADE,
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  text TEXT NOT NULL,
    \\  at INTEGER NOT NULL
    \\);
    \\CREATE INDEX clan_chat_clan ON clan_chat(clan_id, id);
    \\
    \\CREATE TABLE strongholds (
    \\  id TEXT PRIMARY KEY,
    \\  clan_id INTEGER NOT NULL REFERENCES clans(id) ON DELETE CASCADE,
    \\  week INTEGER NOT NULL,
    \\  district TEXT NOT NULL,
    \\  claimed_at INTEGER NOT NULL,
    \\  last_hour INTEGER NOT NULL DEFAULT 0,
    \\  last_day INTEGER NOT NULL DEFAULT 0
    \\);
    \\
    \\CREATE TABLE raids (
    \\  id TEXT PRIMARY KEY,
    \\  district TEXT NOT NULL,
    \\  week INTEGER NOT NULL,
    \\  site TEXT NOT NULL,
    \\  hp INTEGER NOT NULL,
    \\  max_hp INTEGER NOT NULL,
    \\  created_at INTEGER NOT NULL,
    \\  ends_at INTEGER NOT NULL,
    \\  settled INTEGER NOT NULL DEFAULT 0
    \\);
    \\
    \\CREATE TABLE raid_damage (
    \\  raid_id TEXT NOT NULL REFERENCES raids(id) ON DELETE CASCADE,
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  damage INTEGER NOT NULL DEFAULT 0,
    \\  last_attack_at INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY (raid_id, player_id)
    \\);
    \\
    \\CREATE TABLE snapshots (
    \\  player_id INTEGER PRIMARY KEY REFERENCES players(id) ON DELETE CASCADE,
    \\  faction INTEGER NOT NULL,
    \\  level INTEGER NOT NULL,
    \\  items TEXT NOT NULL,
    \\  abilities TEXT NOT NULL,
    \\  updated_at INTEGER NOT NULL
    \\);
    \\CREATE INDEX snapshots_match ON snapshots(faction, level);
    \\
    \\CREATE TABLE done (
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  sid TEXT NOT NULL,
    \\  expires_at INTEGER NOT NULL,
    \\  PRIMARY KEY (player_id, sid)
    \\);
    \\CREATE INDEX done_expiry ON done(expires_at);
    \\
    \\CREATE TABLE contact_log (
    \\  a INTEGER NOT NULL,
    \\  b INTEGER NOT NULL,
    \\  at INTEGER NOT NULL
    \\);
    \\CREATE INDEX contact_log_pair ON contact_log(a, b);
    ,
    // Sign-in identities (a player with none is a guest), and clan chat that outlives its authors:
    // a deleted player's messages stay, shown as "[deleted]".
    \\CREATE TABLE identities (
    \\  id INTEGER PRIMARY KEY,
    \\  provider TEXT NOT NULL,
    \\  subject TEXT NOT NULL,
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  email TEXT,
    \\  created_at INTEGER NOT NULL,
    \\  UNIQUE (provider, subject)
    \\);
    \\CREATE INDEX identities_player ON identities(player_id);
    \\
    \\CREATE TABLE clan_chat_new (
    \\  id INTEGER PRIMARY KEY,
    \\  clan_id INTEGER NOT NULL REFERENCES clans(id) ON DELETE CASCADE,
    \\  player_id INTEGER REFERENCES players(id) ON DELETE SET NULL,
    \\  text TEXT NOT NULL,
    \\  at INTEGER NOT NULL
    \\);
    \\INSERT INTO clan_chat_new(id, clan_id, player_id, text, at) SELECT id, clan_id, player_id, text, at FROM clan_chat;
    \\DROP TABLE clan_chat;
    \\ALTER TABLE clan_chat_new RENAME TO clan_chat;
    \\CREATE INDEX clan_chat_clan ON clan_chat(clan_id, id);
    ,
    // Fight stance (the saved default, used in Contact) and how often each enemy type was fought.
    \\ALTER TABLE players ADD COLUMN stance INTEGER NOT NULL DEFAULT 1;
    \\ALTER TABLE players ADD COLUMN bestiary TEXT NOT NULL DEFAULT '';
    ,
    // Patrol: an event can be announced by a notification (notified) before the app shows it (delivered).
    \\ALTER TABLE events ADD COLUMN notified INTEGER NOT NULL DEFAULT 0;
    \\UPDATE events SET notified = delivered;
    ,
    // Contact record (wins and losses of real-world fights only), Echo wins, and weekly Contact wins.
    \\ALTER TABLE players ADD COLUMN contacts_won INTEGER NOT NULL DEFAULT 0;
    \\ALTER TABLE players ADD COLUMN contacts_lost INTEGER NOT NULL DEFAULT 0;
    \\ALTER TABLE players ADD COLUMN echoes_won INTEGER NOT NULL DEFAULT 0;
    \\CREATE TABLE contact_week (
    \\  week INTEGER NOT NULL,
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  wins INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY (week, player_id)
    \\);
    ,
    // Found notes (docs/LORE.md) and the sets whose reward and title were claimed.
    \\CREATE TABLE player_notes (
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  note_id TEXT NOT NULL,
    \\  found_at INTEGER NOT NULL,
    \\  PRIMARY KEY (player_id, note_id)
    \\);
    \\CREATE TABLE note_claims (
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  set_id TEXT NOT NULL,
    \\  claimed_at INTEGER NOT NULL,
    \\  PRIMARY KEY (player_id, set_id)
    \\);
    ,
    // Moderation: suspensions (banned_until is 0 for none, the largest integer for permanent), a
    // forced callsign change, and player reports. A report keeps a text label of its target so it
    // stays readable after the target is renamed or deleted.
    \\ALTER TABLE players ADD COLUMN banned_until INTEGER NOT NULL DEFAULT 0;
    \\ALTER TABLE players ADD COLUMN ban_reason TEXT NOT NULL DEFAULT '';
    \\ALTER TABLE players ADD COLUMN must_rename INTEGER NOT NULL DEFAULT 0;
    \\CREATE TABLE reports (
    \\  id INTEGER PRIMARY KEY,
    \\  reporter_id INTEGER REFERENCES players(id) ON DELETE SET NULL,
    \\  kind TEXT NOT NULL,
    \\  target_key TEXT NOT NULL,
    \\  target_player_id INTEGER REFERENCES players(id) ON DELETE SET NULL,
    \\  target_clan_id INTEGER REFERENCES clans(id) ON DELETE SET NULL,
    \\  message_id INTEGER,
    \\  label TEXT NOT NULL,
    \\  excerpt TEXT NOT NULL DEFAULT '',
    \\  reason TEXT NOT NULL,
    \\  note TEXT NOT NULL DEFAULT '',
    \\  status TEXT NOT NULL DEFAULT 'open',
    \\  created_at INTEGER NOT NULL,
    \\  resolved_at INTEGER
    \\);
    \\CREATE UNIQUE INDEX reports_open_once ON reports(reporter_id, target_key) WHERE status = 'open';
    \\CREATE INDEX reports_target ON reports(status, target_key);
    \\CREATE INDEX reports_reporter ON reports(reporter_id, created_at);
    ,
    // Achievements, the collection log and cosmetics. `counters` holds the running totals that
    // achievements count and nothing else keeps; `discoveries` is what a player has ever held
    // (kind 0 base item, 1 legendary unique, 2 rarity; idx indexes the game tables). Players
    // already in the game are credited from what they hold and have done.
    \\ALTER TABLE players ADD COLUMN callsign_color TEXT NOT NULL DEFAULT '';
    \\ALTER TABLE players ADD COLUMN avatar_frame TEXT NOT NULL DEFAULT '';
    \\CREATE TABLE counters (
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  key TEXT NOT NULL,
    \\  n INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY (player_id, key)
    \\);
    \\CREATE TABLE achievements (
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  ach_id TEXT NOT NULL,
    \\  earned_at INTEGER NOT NULL,
    \\  PRIMARY KEY (player_id, ach_id)
    \\);
    \\CREATE TABLE cosmetics (
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  cosmetic_id TEXT NOT NULL,
    \\  acquired_at INTEGER NOT NULL,
    \\  PRIMARY KEY (player_id, cosmetic_id)
    \\);
    \\CREATE TABLE discoveries (
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  kind INTEGER NOT NULL,
    \\  idx INTEGER NOT NULL,
    \\  first_at INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY (player_id, kind, idx)
    \\);
    \\INSERT OR IGNORE INTO discoveries(player_id, kind, idx) SELECT DISTINCT player_id, 0, base FROM items;
    \\INSERT OR IGNORE INTO discoveries(player_id, kind, idx) SELECT DISTINCT player_id, 1, uniq FROM items WHERE uniq >= 0;
    \\INSERT OR IGNORE INTO discoveries(player_id, kind, idx) SELECT DISTINCT player_id, 2, rarity FROM items;
    \\INSERT INTO counters(player_id, key, n) SELECT player_id, 'war_points', SUM(points) FROM war_player GROUP BY player_id;
    \\INSERT INTO counters(player_id, key, n) SELECT player_id, 'best_upgrade', MAX(upgrade) FROM items WHERE upgrade > 0 GROUP BY player_id;
    \\INSERT INTO counters(player_id, key, n) SELECT id, 'pve_wins', wins - contacts_won - echoes_won FROM players WHERE wins - contacts_won - echoes_won > 0;
    \\INSERT INTO counters(player_id, key, n) SELECT id, 'best_streak', streak FROM players WHERE streak > 0;
    ,
    // Terms of service: the version a player accepted and when (0: never; players from before
    // this are asked once). No age or birth date is kept anywhere.
    \\ALTER TABLE players ADD COLUMN terms_accepted INTEGER NOT NULL DEFAULT 0;
    \\ALTER TABLE players ADD COLUMN terms_accepted_at INTEGER NOT NULL DEFAULT 0;
    ,
    // Crash and error reports from the app (anonymous; the newest few thousand are kept), and a
    // per-player count of sessions played with a simulated location. No position is stored.
    \\CREATE TABLE client_errors (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  at INTEGER NOT NULL,
    \\  hash TEXT NOT NULL,
    \\  message TEXT NOT NULL,
    \\  stack TEXT NOT NULL DEFAULT '',
    \\  frame TEXT NOT NULL DEFAULT '',
    \\  version TEXT NOT NULL DEFAULT '',
    \\  platform TEXT NOT NULL DEFAULT '',
    \\  screen TEXT NOT NULL DEFAULT ''
    \\);
    \\CREATE INDEX client_errors_hash ON client_errors(hash, at);
    \\CREATE INDEX client_errors_at ON client_errors(at);
    \\ALTER TABLE players ADD COLUMN mock_sessions INTEGER NOT NULL DEFAULT 0;
    \\ALTER TABLE players ADD COLUMN mock_at INTEGER NOT NULL DEFAULT 0;
    ,
    // Limited-time events (DESIGN.md section 18). A row per event that has run: from the calendar
    // (made the first time anything looks, at most one per start) or started by an admin. `target`
    // is fixed from the active-player count when it starts; `settled` is set once the rewards are
    // paid. Contributions are per player and district; districts get their own target on their
    // first contribution. `world_event_buys` counts Exchange purchases per event, `event_titles`
    // the yearly title of the monthly event.
    \\CREATE TABLE world_events (
    \\  id INTEGER PRIMARY KEY,
    \\  type TEXT NOT NULL,
    \\  source TEXT NOT NULL,
    \\  starts_at INTEGER NOT NULL,
    \\  ends_at INTEGER NOT NULL,
    \\  param INTEGER NOT NULL DEFAULT 0,
    \\  active_players INTEGER NOT NULL DEFAULT 1,
    \\  target INTEGER NOT NULL DEFAULT 0,
    \\  progress INTEGER NOT NULL DEFAULT 0,
    \\  settled INTEGER NOT NULL DEFAULT 0
    \\);
    \\CREATE UNIQUE INDEX world_events_calendar ON world_events(starts_at) WHERE source = 'calendar';
    \\CREATE INDEX world_events_span ON world_events(starts_at, ends_at);
    \\CREATE TABLE world_event_district (
    \\  event_id INTEGER NOT NULL REFERENCES world_events(id) ON DELETE CASCADE,
    \\  district TEXT NOT NULL,
    \\  active_players INTEGER NOT NULL,
    \\  target INTEGER NOT NULL,
    \\  progress INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY (event_id, district)
    \\);
    \\CREATE TABLE world_event_player (
    \\  event_id INTEGER NOT NULL REFERENCES world_events(id) ON DELETE CASCADE,
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  district TEXT NOT NULL,
    \\  n INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY (event_id, player_id, district)
    \\);
    \\CREATE INDEX world_event_player_player ON world_event_player(player_id);
    \\CREATE TABLE world_event_buys (
    \\  event_id INTEGER NOT NULL REFERENCES world_events(id) ON DELETE CASCADE,
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  sku TEXT NOT NULL,
    \\  n INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY (event_id, player_id, sku)
    \\);
    \\CREATE TABLE event_titles (
    \\  player_id INTEGER NOT NULL REFERENCES players(id) ON DELETE CASCADE,
    \\  year INTEGER NOT NULL,
    \\  earned_at INTEGER NOT NULL,
    \\  PRIMARY KEY (player_id, year)
    \\);
    ,
};

// --- Tests -------------------------------------------------------------------------------------------

test "open, migrate, bind and read back" {
    var db = try Db.open(":memory:");
    defer db.close();
    try std.testing.expectEqual(@as(?i64, migrations.len), try db.scalar("PRAGMA user_version", .{}));

    try db.run("INSERT INTO meta(key, value) VALUES(?, ?)", .{ "a", "hello" });
    try db.run("INSERT INTO meta(key, value) VALUES(?, ?)", .{ "b", @as(i64, 42) });
    try db.run("INSERT INTO meta(key, value) VALUES(?, ?)", .{ "c", 2.5 });
    try db.run("INSERT INTO meta(key, value) VALUES(?, ?)", .{ "", "" });

    var st = try db.query("SELECT key, value, typeof(value) FROM meta ORDER BY key", .{});
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("", st.text(0));
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("a", st.text(0));
    try std.testing.expectEqualStrings("hello", st.text(1));
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(i64, 42), st.int(1));
    try std.testing.expect(try st.step());
    try std.testing.expectEqual(@as(f64, 2.5), st.real(1));
    try std.testing.expect(!try st.step());
}

test "null binding, optionals, scalar, changes and last id" {
    var db = try Db.open(":memory:");
    defer db.close();
    // The foreign key rejects an unknown player.
    db.quiet = true;
    try std.testing.expectError(error.Sqlite, db.run("INSERT INTO events(player_id, at, type, text) VALUES(?, ?, ?, ?)", .{ 1, 2, "x", "y" }));
    db.quiet = false;
    try db.run("INSERT INTO players(callsign, callsign_lc, token_hash, recovery_hash, created_at, last_seen) VALUES(?, ?, ?, ?, 0, 0)", .{ "Ann", "ann", "t", "r" });
    const id = db.lastInsertId();
    try std.testing.expect(id > 0);
    var none: ?i64 = null;
    _ = &none;
    try db.run("UPDATE players SET downed_until = ?, avatar = ? WHERE id = ?", .{ none, null, id });
    try std.testing.expectEqual(@as(?i64, null), try db.scalar("SELECT downed_until FROM players WHERE id = ?", .{id}));
    try db.run("UPDATE players SET downed_until = ? WHERE id = ?", .{ @as(?i64, 99), id });
    try std.testing.expectEqual(@as(?i64, 99), try db.scalar("SELECT downed_until FROM players WHERE id = ?", .{id}));
    try std.testing.expectEqual(@as(i64, 1), db.changes());
    try std.testing.expectEqual(@as(?i64, null), try db.scalar("SELECT id FROM players WHERE id = ?", .{id + 1}));
}

test "transactions roll back; meta round trips" {
    var db = try Db.open(":memory:");
    defer db.close();
    try db.setMetaInt("seed", 7);
    try db.begin();
    try db.setMetaInt("seed", 8);
    db.rollback();
    try std.testing.expectEqual(@as(?i64, 7), try db.metaInt("seed"));
    try db.begin();
    try db.setMetaInt("seed", 9);
    try db.commit();
    try std.testing.expectEqual(@as(?i64, 9), try db.metaInt("seed"));
    try std.testing.expectEqual(@as(?i64, null), try db.metaInt("missing"));
}

test "a database from a newer server is refused" {
    var db = try Db.open(":memory:");
    defer db.close();
    db.quiet = true;
    try db.exec("PRAGMA user_version = 99");
    try std.testing.expectError(error.Sqlite, db.migrate());
}
