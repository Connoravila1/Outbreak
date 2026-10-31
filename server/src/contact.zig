//! Contact: the automatic real-world fight (DESIGN.md section 8). One fight is resolved for a
//! pair, then each side is settled from its own point of view and gets a "contact" event carrying
//! the Battle with themselves as "a".

const std = @import("std");
const game = @import("game");
const ctx_mod = @import("ctx.zig");
const model = @import("model.zig");
const views = @import("views.zig");
const fight = @import("fight.zig");
const rewards = @import("rewards.zig");
const missions = @import("missions.zig");
const warstate = @import("warstate.zig");

const data = game.data;
const progression = game.progression;
const loot = game.loot;
const Req = ctx_mod.Req;
const HandlerError = ctx_mod.HandlerError;
const Player = model.Player;

pub const range_m = 60.0;
pub const pair_cooldown_ms: i64 = 4 * 60 * 60 * 1000;
pub const recent_fight_ms: i64 = 10 * 60 * 1000;

/// Hide who the opponent is: faction, level, title, gear and abilities stay.
pub fn anonymous(s: fight.Side) fight.Side {
    var out = s;
    out.view.name = if (s.view.faction == .zombie) "A Zombie" else "A Human";
    out.view.kind = .player;
    return out;
}

/// Everything except the position conditions and the pair cooldown (checked by the caller).
pub fn eligible(p: *const Player, now: i64) bool {
    return p.faction != null and !p.downed(now) and now - p.last_pvp_at >= recent_fight_ms and !progression.pvpProtected(p.level);
}

/// Pay and record one side of a Contact. `o` is the fight with `p` as side "a"; `foe` is the
/// anonymous opponent as shown to `p`.
pub fn settleSide(req: *Req, p: *Player, a: fight.Side, foe: fight.Side, o: fight.Outcome, district: []const u8) HandlerError!void {
    const won = o.won();
    const foe_level: u32 = foe.view.level;
    var acc = rewards.Acc{};
    const win_xp = progression.pvpWinXp(foe_level);
    if (won) {
        acc.xp = win_xp;
        var lrng = game.rng.Rng.init(game.rng.hash(o.seed, .{ "loot", p.id }));
        try acc.addDrop(req, loot.rollPvp(&lrng, p.level, foe_level, rewards.lootMult(p, req.now)));
        acc.war_points = game.war.points(.pvp_win);
        p.wins += 1;
        p.contacts_won += 1;
        try warstate.addContactWin(req, p.id);
    } else {
        acc.xp = progression.pvpLossXp(foe_level);
        p.losses += 1;
        p.contacts_lost += 1;
    }
    acc.deliver_level_up = false;
    p.contacts += 1;
    p.last_pvp_at = req.now;
    rewards.settleHp(p, fight.hpAfter(a, o), req.now);
    const rw = try rewards.apply(req, p, &acc, district);
    if (won) try missions.event(req, p, .{ .kind = .contact_win });

    const me = try views.meFresh(req, p.id);
    const battle = try fight.battleView(req, if (foe.view.kind == .echo or foe.view.kind == .rogue) .echo else .pvp, a, foe, o, rw, me);
    const text = try std.fmt.allocPrint(req.arena, "CONTACT. {s}, level {d}. {s}", .{
        foe.view.name, foe.view.level, if (won) "You won." else "You lost.",
    });
    try model.pushEvent(req, p.id, "contact", text, try fight.toJson(req.arena, battle), try fight.toJson(req.arena, rw), false);
}

/// Stage a Contact for one player against a generated opponent (dev only).
pub fn stageBot(req: *Req, p: *Player, foe_build: *const @import("snapshot.zig").Build, district: []const u8, as: fight.CombatantKind) HandlerError!void {
    const a = try fight.selfSide(req, p);
    const b = try fight.buildSide(req.arena, foe_build, as, null);
    const o = try fight.run(req, a, b, fight.seedFor(req, p.id, 0xb07));
    try settleSide(req, p, a, b, o, district);
}
