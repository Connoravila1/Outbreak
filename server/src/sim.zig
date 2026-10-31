//! Balance simulator: `zig build sim [-- --players N --seed S --hours-per-day H]`.
//!
//! Plays many virtual players from level 1 with the real combat, loot, progression and mission
//! code, and prints how long each level takes. Player behaviour (what "active" means) is set by
//! the constants below; game constants live in the game modules.
//!
//! The assumed player: plays `hours_per_day` active hours each day (HP is full at the start of
//! each day), always walking; fights an enemy as soon as one is within reach and HP is above a
//! floor; heals from stock under a lower HP mark, otherwise waits (still walking) for regen;
//! opens caches met on the way; equips better drops, scraps the rest; spends salvage on small
//! heals first and item upgrades second; claims dailies and the weekly as they complete; takes an
//! Echo about every two active hours from level 5.

const std = @import("std");
const game = @import("game");

const data = game.data;
const stats = game.stats;
const progression = game.progression;
const combat = game.combat;
const loot = game.loot;
const missions = game.missions;
const war = game.war;
const stance_rules = game.stance;
const daynight = game.daynight;
const Rng = game.rng.Rng;
const Item = stats.Item;

// --- Behaviour assumptions -----------------------------------------------------------------------

const walk_speed_ms = 1.3;
const fight_seconds = 12.0; // tap, playback, result card
const approach_seconds = 20.0; // walking to the next enemy
const caches_per_hour = 6.0; // caches met per hour spent walking
const fight_hp_floor = 0.60; // fights only at or above this HP fraction
const heal_below = 0.50; // uses a stocked heal under this HP fraction
const heal_stock = 3; // buys small heals up to this many
const echo_interval_s = 2 * 3600.0;
const elite_hp_floor = 0.80;
const step_seconds = 30.0; // waiting granularity
const max_hours = 450.0;

const max_lvl = data.max_level;
const probe_levels = [_]u8{ 5, 10, 15, 20, 25, 30, 35, 40, 45, 50 };
const probe_archetypes = 6; // everything except the raid boss
const probe_fights = 60;
const stance_count = 3;
/// Share of the 24 hours that is night (20:00 to 06:00): fights are dealt a random hour, so the
/// results average over the day.
const night_share = 10.0 / 24.0;

/// How the simulated player picks a stance for PvE: `none` is the old model (no stances, no
/// time of day), `random` a player who does not know the counters, `optimal` one who always
/// stands in the counter (Careful against enemies with no counter).
const Policy = enum { none, random, optimal, aggressive, careful, evasive };

const Config = struct {
    players: u32 = 100,
    seed: u64 = 1,
    hours_per_day: f64 = 2.0,
    stance: Policy = .random,
};

const ProbeCell = struct { fights: u32 = 0, wins: u32 = 0, turns: u64 = 0, lost: f64 = 0 };

const Player = struct {
    id: u64,
    faction: data.Faction,
    rng: Rng,
    day_budget_s: f64,

    level: u8 = 1,
    xp: u32 = 0,
    hp: f64 = 100,
    gear: [3]?Item = .{ null, null, null },
    salvage: u32 = 0,
    cons: [9]u32 = [_]u32{0} ** 9,
    comp: stats.Computed = undefined,
    abilities: std.EnumSet(data.Ability) = .initEmpty(),

    t: f64 = 0,
    day_clock: f64 = 0,
    day: i64 = 0,
    week: i64 = 0,
    walk_xp_today: u32 = 0,
    metres_frac: f64 = 0,
    downed_left: f64 = 0,
    echo_timer: f64 = 0,
    total_wins: u32 = 0,

    streak: u32 = 0,
    last_claim_day: i64 = -10,
    daily: [3]missions.Mission = undefined,
    daily_prog: [3]u32 = .{ 0, 0, 0 },
    daily_claimed: [3]bool = .{ false, false, false },
    weekly: ?missions.Mission = null,
    weekly_prog: u32 = 0,
    weekly_claimed: bool = false,

    xp_by: [max_lvl + 1][5]f64 = [_][5]f64{.{ 0, 0, 0, 0, 0 }} ** (max_lvl + 1),
    reach_h: [max_lvl + 1]f64 = [_]f64{std.math.inf(f64)} ** (max_lvl + 1),
    reach_salvage: [max_lvl + 1]u32 = [_]u32{0} ** (max_lvl + 1),
    reach_ratio: [max_lvl + 1][4]f32 = [_][4]f32{.{ 0, 0, 0, 0 }} ** (max_lvl + 1),
    fights: [max_lvl + 1]u32 = [_]u32{0} ** (max_lvl + 1),
    wins: [max_lvl + 1]u32 = [_]u32{0} ** (max_lvl + 1),
    lost: [max_lvl + 1]f64 = [_]f64{0} ** (max_lvl + 1),
    turns: [max_lvl + 1]u64 = [_]u64{0} ** (max_lvl + 1),
    probes: [probe_levels.len][probe_archetypes][stance_count]ProbeCell = [_][probe_archetypes][stance_count]ProbeCell{[_][stance_count]ProbeCell{[_]ProbeCell{.{}} ** stance_count} ** probe_archetypes} ** probe_levels.len,
    policy: Policy = .random,

    fn init(id: u64, seed: u64, cfg: Config) Player {
        var p = Player{
            .id = id,
            .faction = if (id % 2 == 0) .human else .zombie,
            .rng = game.rng.derive(seed, .{ "player", id }),
            .day_budget_s = cfg.hours_per_day * 3600.0,
            .policy = cfg.stance,
        };
        p.day = 20000 + @as(i64, @intCast(p.rng.below(7)));
        p.week = war.weekIndex(p.day * war.day_ms);
        for ([_][]const u8{ "baseball_bat", "hoodie", "flashlight" }, 0..) |b, i| {
            p.gear[i] = .{ .base = data.findBase(b).? };
        }
        p.cons[@intFromEnum(data.Consumable.heal_s)] = 3;
        p.recompute();
        p.hp = @floatFromInt(p.comp.stats.hp);
        p.startDay();
        p.reach_h[1] = 0;
        return p;
    }

    fn maxHp(p: *const Player) f64 {
        return @floatFromInt(p.comp.stats.hp);
    }

    fn hpFrac(p: *const Player) f64 {
        return p.hp / p.maxHp();
    }

    fn recompute(p: *Player) void {
        var items: [3]Item = undefined;
        var n: usize = 0;
        for (p.gear) |g| {
            if (g) |it| {
                items[n] = it;
                n += 1;
            }
        }
        p.comp = stats.playerStats(p.level, p.faction, items[0..n], .{});
        // Abilities by fixed priority of tier: heal, barricade, overwatch, burn, aimed shot, rush, last stand.
        const priority = [_]usize{ 0, 2, 5, 4, 1, 3, 6 };
        p.abilities = .initEmpty();
        var slots = progression.abilitySlots(p.level);
        for (priority) |tier| {
            if (slots == 0) break;
            const row = data.abilities[tier * 2 + @intFromEnum(p.faction)];
            if (row.level <= p.level) {
                p.abilities.insert(row.id);
                slots -= 1;
            }
        }
    }

    /// Own stats relative to base + reference gear: hp, atk, def, spd.
    fn ratio(p: *const Player) [4]f32 {
        const b = stats.baseStats(p.level);
        const g = stats.reference_gear[p.level];
        const s = p.comp.stats;
        return .{
            @as(f32, @floatFromInt(s.hp)) / @as(f32, @floatFromInt(b.hp + g.hp)),
            @as(f32, @floatFromInt(s.atk)) / @as(f32, @floatFromInt(b.atk + g.atk)),
            @as(f32, @floatFromInt(s.def)) / @as(f32, @floatFromInt(b.def + g.def)),
            @as(f32, @floatFromInt(s.spd)) / @as(f32, @floatFromInt(b.spd + g.spd)),
        };
    }

    fn combatant(p: *const Player) combat.Combatant {
        return .{
            .faction = p.faction,
            .stats = p.comp.stats,
            .hp = @intFromFloat(@round(p.hp)),
            .abilities = p.abilities,
            .mods = p.comp.mods,
        };
    }

    // --- Time ---------------------------------------------------------------------------------------

    fn startDay(p: *Player) void {
        p.hp = p.maxHp();
        p.downed_left = 0;
        p.walk_xp_today = 0;
        p.daily = missions.dailyMissions(p.id, p.day, p.level);
        p.daily_prog = .{ 0, 0, 0 };
        p.daily_claimed = .{ false, false, false };
        const week = war.weekIndex(p.day * war.day_ms);
        if (week != p.week or p.weekly == null) {
            p.week = week;
            p.weekly_prog = 0;
            p.weekly_claimed = false;
        }
        p.weekly = missions.weeklyMission(p.id, p.week, p.level);
    }

    fn advance(p: *Player, dt: f64, walking: bool) void {
        p.t += dt;
        p.day_clock += dt;
        p.echo_timer += dt;
        if (p.downed_left > 0) {
            p.downed_left -= dt;
            if (p.downed_left <= 0) {
                p.downed_left = 0;
                p.hp = stats.revive_fraction * p.maxHp();
            }
        } else {
            const rate = stats.regenRate(p.faction);
            p.hp = @min(p.maxHp(), p.hp + rate * p.maxHp() * dt / 60.0);
        }
        if (walking) {
            p.metres_frac += dt * walk_speed_ms;
            const whole: u32 = @intFromFloat(@floor(p.metres_frac));
            if (whole >= 20) {
                p.metres_frac -= @floatFromInt(whole);
                const xp = progression.walkXp(whole, p.walk_xp_today);
                p.walk_xp_today += xp;
                p.gainXp(.walk, xp);
                p.missionEvent(.{ .kind = .walk, .amount = whole });
            }
            if (p.rng.chance(1.0 - @exp(-caches_per_hour * dt / 3600.0))) p.openCache();
        }
        if (p.day_clock >= p.day_budget_s) {
            p.day_clock -= p.day_budget_s;
            p.day += 1;
            p.startDay();
        }
    }

    // --- XP, levels, loot -------------------------------------------------------------------------------

    const Src = enum { fight, cache, walk, mission, echo };

    fn gainXp(p: *Player, src: Src, amount: u32) void {
        p.xp_by[p.level][@intFromEnum(src)] += @floatFromInt(amount);
        const r = progression.applyXp(p.level, p.xp, amount);
        p.xp = r.xp;
        if (r.levels_gained == 0) return;
        var l = p.level + 1;
        while (l <= r.level) : (l += 1) {
            p.reach_h[l] = p.t / 3600.0;
            p.reach_salvage[l] = p.salvage;
        }
        p.level = r.level;
        p.recompute();
        if (p.downed_left == 0) p.hp = p.maxHp(); // levelling up heals fully
        p.reach_ratio[r.level] = p.ratio();
        for (probe_levels, 0..) |pl, i| {
            if (pl > r.level - r.levels_gained and pl <= r.level) p.probe(i, pl);
        }
    }

    fn probe(p: *Player, slot: usize, level: u8) void {
        var rng = game.rng.derive(p.id, .{ "probe", level });
        const full = blk: {
            var c = p.combatant();
            c.hp = c.stats.hp;
            break :blk c;
        };
        var log: [combat.max_log]combat.Turn = undefined;
        for (0..probe_archetypes) |a| {
            const arch: data.Archetype = @enumFromInt(a);
            for (0..stance_count) |si| {
                var cell = &p.probes[slot][a][si];
                for (0..probe_fights) |_| {
                    const night = p.policy != .none and rng.chance(night_share);
                    const adj = if (p.policy == .none) stance_rules.Adjusted{ .c = full } else stance_rules.adjust(full, @enumFromInt(si), arch, night);
                    const foe = enemyCombatant(arch, level, if (p.policy == .none) 1.0 else daynight.enemyMult(p.faction, night));
                    const r = combat.fight(adj.c, foe, rng.next(), &log);
                    cell.fights += 1;
                    if (r.winner == .a) cell.wins += 1;
                    cell.turns += r.rounds;
                    const left = stance_rules.realHp(r.hp_a, adj.hp_scale, full.stats.hp);
                    cell.lost += @as(f64, @floatFromInt(full.stats.hp - left)) / @as(f64, @floatFromInt(full.stats.hp));
                }
            }
        }
    }

    fn handleItem(p: *Player, item: Item, emit: bool) void {
        const idx = @intFromEnum(item.slot());
        if (p.gear[idx]) |cur| {
            if (@as(f32, @floatFromInt(stats.itemPower(item))) <= 1.05 * @as(f32, @floatFromInt(stats.itemPower(cur)))) {
                p.salvage += loot.scrapValue(item);
                if (emit) p.missionEvent(.{ .kind = .item_scrap, .amount = 1 });
                return;
            }
            p.salvage += loot.scrapValue(cur);
            if (emit) p.missionEvent(.{ .kind = .item_scrap, .amount = 1 });
        }
        p.gear[idx] = item;
        p.recompute();
    }

    fn takeDrop(p: *Player, d: loot.Drop) void {
        p.salvage += d.salvage;
        for (d.consumableSlice()) |c| p.cons[@intFromEnum(c)] += 1;
        for (d.itemSlice()) |it| p.handleItem(it, true);
    }

    fn lootMult(p: *const Player) f32 {
        return 1.0 + p.comp.mods.loot;
    }

    fn openCache(p: *Player) void {
        p.gainXp(.cache, progression.cacheXp(p.level));
        p.takeDrop(loot.rollCache(&p.rng, p.level, p.lootMult()));
        p.missionEvent(.{ .kind = .cache_open });
    }

    // --- Missions ------------------------------------------------------------------------------------------

    fn missionEvent(p: *Player, ev: missions.Event) void {
        for (0..3) |i| {
            if (p.daily_claimed[i]) continue;
            p.daily_prog[i] += missions.progressDelta(p.daily[i], ev);
            if (p.daily_prog[i] >= p.daily[i].target) p.claimDaily(i);
        }
        if (p.weekly) |w| {
            if (!p.weekly_claimed) {
                p.weekly_prog += missions.progressDelta(w, ev);
                if (p.weekly_prog >= w.target) {
                    p.weekly_claimed = true;
                    const r = missions.reward(w, p.level, 0);
                    p.salvage += r.salvage;
                    p.handleItem(loot.rollItem(&p.rng, .{ .level = p.level, .min_rarity = r.item_min_rarity.? }), false);
                    p.gainXp(.mission, r.xp);
                }
            }
        }
    }

    fn claimDaily(p: *Player, i: usize) void {
        p.daily_claimed[i] = true;
        p.streak = missions.streakAfterClaim(p.streak, p.last_claim_day, p.day);
        p.last_claim_day = p.day;
        const r = missions.reward(p.daily[i], p.level, p.streak);
        p.salvage += r.salvage;
        if (p.daily_claimed[0] and p.daily_claimed[1] and p.daily_claimed[2]) {
            p.cons[@intFromEnum(missions.all_dailies_bonus)] += 1;
        }
        p.gainXp(.mission, r.xp);
    }

    // --- Decisions ------------------------------------------------------------------------------------------

    fn useHeal(p: *Player) bool {
        const hs = @intFromEnum(data.Consumable.heal_s);
        const hm = @intFromEnum(data.Consumable.heal_m);
        const missing = p.maxHp() - p.hp;
        var pick: ?data.Consumable = null;
        if (p.cons[hm] > 0 and missing >= 0.5 * p.maxHp()) {
            pick = .heal_m;
        } else if (p.cons[hs] > 0) {
            pick = .heal_s;
        } else if (p.cons[hm] > 0) {
            pick = .heal_m;
        }
        const c = pick orelse return false;
        p.cons[@intFromEnum(c)] -= 1;
        const amt: f64 = @floatFromInt(stats.healAmount(c, p.faction, p.comp.stats.hp));
        p.hp = @min(p.maxHp(), p.hp + amt);
        p.missionEvent(.{ .kind = .consumable_use });
        return true;
    }

    fn spend(p: *Player) void {
        const hs = @intFromEnum(data.Consumable.heal_s);
        while (p.cons[hs] < heal_stock and p.salvage >= 20) {
            p.salvage -= 20;
            p.cons[hs] += 1;
        }
        if (p.level < 4) return;
        while (true) {
            var best: ?usize = null;
            var best_cost: u32 = std.math.maxInt(u32);
            for (p.gear, 0..) |g, i| {
                const it = g orelse continue;
                const cost = loot.upgradeCost(it) orelse continue;
                if (cost < best_cost) {
                    best_cost = cost;
                    best = i;
                }
            }
            const i = best orelse return;
            if (best_cost > p.salvage) return;
            p.salvage -= best_cost;
            p.gear[i].?.upgrade += 1;
            p.recompute();
            p.missionEvent(.{ .kind = .item_upgrade });
        }
    }

    /// Wait (walking) and heal until fit to fight.
    fn getReady(p: *Player, need: f64) void {
        while (true) {
            if (p.downed_left > 0) {
                if (p.cons[@intFromEnum(data.Consumable.revive)] > 0) {
                    p.cons[@intFromEnum(data.Consumable.revive)] -= 1;
                    p.downed_left = 0;
                    p.hp = p.maxHp();
                    p.missionEvent(.{ .kind = .consumable_use });
                    continue;
                }
                p.advance(step_seconds, true);
                continue;
            }
            if (p.hpFrac() >= need) return;
            if (p.hpFrac() < heal_below and p.useHeal()) continue;
            p.advance(step_seconds, true);
        }
    }

    fn lose(p: *Player) void {
        p.hp = 0;
        p.downed_left = @floatFromInt(@divTrunc(stats.downedMs(p.level), 1000));
    }

    fn pveFight(p: *Player) void {
        p.getReady(fight_hp_floor);
        var arch: data.Archetype = undefined;
        var elite = false;
        var offset: i32 = 0;
        const new_player = p.level < stats.grace_levels;
        for (0..6) |_| {
            arch = @enumFromInt(p.rng.weighted(&data.archetype_weights));
            elite = p.rng.chance(game.spawns.elite_chance);
            offset = if (elite) p.rng.intRange(3, 5) else p.rng.intRange(-2, 2);
            if (new_player) {
                // Below level 5 the world has no elites and nothing above the player.
                elite = false;
                offset = @mod(p.rng.intRange(-2, 2) + 2, 3) - 2;
                break;
            }
            if (!elite or p.hpFrac() >= elite_hp_floor) break;
        }
        // The First Blood enemy: a weak Shambler at the player's level, until the first win.
        const first_blood = p.total_wins == 0;
        if (first_blood) {
            arch = .shambler;
            elite = false;
            offset = 0;
        }
        const night = p.policy != .none and p.rng.chance(night_share);
        const stance = p.pickStance(arch);
        const night_mult: f32 = if (p.policy == .none) 1.0 else daynight.enemyMult(p.faction, night);
        const mult: f32 = (if (first_blood) stats.tutorial_factor else stats.graceFactor(p.level)) * night_mult;
        const e_level: u8 = @intCast(std.math.clamp(@as(i32, p.level) + offset, 1, max_lvl + 5));
        p.advance(approach_seconds, true);
        var log: [combat.max_log]combat.Turn = undefined;
        const me = p.combatant();
        const adj = if (p.policy == .none) stance_rules.Adjusted{ .c = me } else stance_rules.adjust(me, stance, arch, night);
        const r = combat.fight(adj.c, enemyCombatant(arch, e_level, mult), p.rng.next(), &log);
        p.advance(fight_seconds, false);
        const lvl = p.level;
        const hp_left = stance_rules.realHp(r.hp_a, adj.hp_scale, p.comp.stats.hp);
        p.fights[lvl] += 1;
        p.turns[lvl] += r.rounds;
        p.lost[lvl] += @as(f64, @floatFromInt(me.hp - hp_left)) / p.maxHp();
        p.hp = @floatFromInt(hp_left);
        const row = data.archetype(arch);
        const class: progression.EnemyClass = if (elite) .elite else .normal;
        const base_xp = progression.pveWinXp(e_level, class, row.reward_mult);
        const xp_mult: f32 = if (p.policy == .none) 1.0 else daynight.pveXpMult(p.faction, night);
        const win_xp: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(base_xp)) * xp_mult));
        if (r.winner == .a) {
            p.wins[lvl] += 1;
            p.total_wins += 1;
            p.takeDrop(loot.rollPve(&p.rng, .{ .player_level = lvl, .enemy_level = e_level, .archetype = arch, .loot_mult = p.lootMult() }));
            if (first_blood) p.handleItem(loot.rollItem(&p.rng, .{ .level = lvl, .min_rarity = .uncommon }), true);
            p.gainXp(.fight, win_xp);
            p.missionEvent(.{ .kind = .pve_win, .archetype = arch, .elite = elite });
        } else {
            p.lose();
            p.gainXp(.fight, progression.pveLossXp(win_xp));
        }
        p.spend();
    }

    fn pickStance(p: *Player, arch: data.Archetype) stance_rules.Stance {
        return switch (p.policy) {
            .none, .careful => .careful,
            .aggressive => .aggressive,
            .evasive => .evasive,
            .random => @enumFromInt(p.rng.below(stance_count)),
            .optimal => data.archetype(arch).counter orelse .careful,
        };
    }

    fn echoFight(p: *Player) void {
        p.echo_timer = 0;
        p.getReady(fight_hp_floor);
        var log: [combat.max_log]combat.Turn = undefined;
        var foe = p.combatant();
        foe.hp = foe.stats.hp;
        foe.faction = p.faction.opposite();
        const r = combat.fight(p.combatant(), foe, p.rng.next(), &log);
        p.advance(fight_seconds, false);
        p.hp = @floatFromInt(r.hp_a);
        if (r.winner == .a) {
            p.takeDrop(loot.rollPvp(&p.rng, p.level, p.level, p.lootMult()));
            p.gainXp(.echo, progression.echoWinXp(p.level));
            p.missionEvent(.{ .kind = .contact_win });
        } else {
            p.lose();
            p.gainXp(.echo, progression.lossXp(progression.echoWinXp(p.level), progression.pvp_loss_fraction));
        }
        p.spend();
    }

    fn run(p: *Player) void {
        while (p.level < max_lvl and p.t < max_hours * 3600.0) {
            if (p.level >= 5 and p.echo_timer >= echo_interval_s) {
                p.echoFight();
            } else {
                p.pveFight();
            }
        }
    }
};

fn enemyCombatant(arch: data.Archetype, level: u8, mult: f32) combat.Combatant {
    const s = stats.enemyStatsScaled(arch, level, mult);
    return .{ .faction = .zombie, .stats = s, .hp = s.hp };
}

// --- Standard kits for the PvP table -------------------------------------------------------------------

/// The best base in each slot at or below `level`, at one rarity, no upgrades or perks.
fn kit(level: u8, rarity: data.Rarity) [3]Item {
    var out: [3]Item = undefined;
    for ([_]data.Slot{ .weapon, .armor, .utility }, 0..) |slot, si| {
        var best: u8 = 0;
        var best_power: i32 = -1;
        for (data.bases, 0..) |b, bi| {
            if (b.slot != slot or b.req > level) continue;
            const pw = stats.itemPower(.{ .base = @intCast(bi), .rarity = rarity });
            if (b.req > data.bases[best].req or (b.req == data.bases[best].req and pw > best_power) or best_power < 0) {
                best = @intCast(bi);
                best_power = pw;
            }
        }
        out[si] = .{ .base = best, .rarity = rarity };
    }
    return out;
}

fn kitCombatant(level: u8, faction: data.Faction, rarity: data.Rarity) combat.Combatant {
    const k = kit(level, rarity);
    const comp = stats.playerStats(level, faction, &k, .{});
    var set: std.EnumSet(data.Ability) = .initEmpty();
    const priority = [_]usize{ 0, 2, 5, 4, 1, 3, 6 };
    var slots = progression.abilitySlots(level);
    for (priority) |tier| {
        if (slots == 0) break;
        const row = data.abilities[tier * 2 + @intFromEnum(faction)];
        if (row.level <= level) {
            set.insert(row.id);
            slots -= 1;
        }
    }
    return .{ .faction = faction, .stats = comp.stats, .hp = comp.stats.hp, .abilities = set, .mods = comp.mods };
}

// --- Reporting --------------------------------------------------------------------------------------------

fn median(vals: []f64) f64 {
    std.mem.sort(f64, vals, {}, std.sort.asc(f64));
    return vals[vals.len / 2];
}

fn quantile(vals: []const f64, q: f64) f64 {
    return vals[@min(vals.len - 1, @as(usize, @intFromFloat(q * @as(f64, @floatFromInt(vals.len)))))];
}

const report_levels = [_]u8{ 2, 3, 4, 5, 7, 10, 15, 20, 25, 30, 35, 40, 45, 50 };

fn target_hours(l: u8) ?f64 {
    return switch (l) {
        5 => 1,
        10 => 5,
        20 => 25,
        30 => 70,
        50 => 300,
        else => null,
    };
}

pub fn main(init: std.process.Init) !void {
    var cfg = Config{};
    var it = init.minimal.args.iterate();
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--players")) {
            cfg.players = try std.fmt.parseInt(u32, it.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--seed")) {
            cfg.seed = try std.fmt.parseInt(u64, it.next() orelse return error.MissingValue, 10);
        } else if (std.mem.eql(u8, arg, "--hours-per-day")) {
            cfg.hours_per_day = try std.fmt.parseFloat(f64, it.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--stance")) {
            cfg.stance = std.meta.stringToEnum(Policy, it.next() orelse return error.MissingValue) orelse return error.UnknownStance;
        } else return error.UnknownArgument;
    }

    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    const w = &out.interface;
    const gpa = init.gpa;

    const players = try gpa.alloc(Player, cfg.players);
    defer gpa.free(players);
    for (players, 0..) |*p, i| {
        p.* = Player.init(i, cfg.seed, cfg);
        p.run();
    }

    try w.print("Outbreak balance simulation: {d} players, {d:.1} active h/day, seed {d}, stance policy {s}\n\n", .{ cfg.players, cfg.hours_per_day, cfg.seed, @tagName(cfg.stance) });
    if (cfg.players > 0) {
        try reportPlayers(w, gpa, players, cfg);
        try reportStances(w, players);
    }
    try reportPvp(w, cfg);
    try w.flush();
}

fn reportPlayers(w: *std.Io.Writer, gpa: std.mem.Allocator, players: []const Player, cfg: Config) !void {
    try w.print("PACING (active hours; HP lost is per fight, % of max HP; fights include fights taken wounded)\n", .{});
    try w.print("{s:>3} {s:>8} {s:>8} {s:>8} {s:>7} {s:>6} {s:>7} {s:>6} {s:>8} {s:>9}\n", .{ "Lvl", "median_h", "p10_h", "p90_h", "target", "win%", "hp_lost", "turns", "salvage", "fights/h" });

    const times = try gpa.alloc(f64, cfg.players);
    defer gpa.free(times);
    for (report_levels) |l| {
        for (players, 0..) |p, i| times[i] = p.reach_h[l];
        std.mem.sort(f64, times, {}, std.sort.asc(f64));
        var fights: f64 = 0;
        var wins: f64 = 0;
        var lost: f64 = 0;
        var turns: f64 = 0;
        var salv = try gpa.alloc(f64, cfg.players);
        defer gpa.free(salv);
        var n_salv: usize = 0;
        for (players) |p| {
            fights += @floatFromInt(p.fights[l]);
            wins += @floatFromInt(p.wins[l]);
            lost += p.lost[l];
            turns += @floatFromInt(p.turns[l]);
            if (p.reach_h[l] < max_hours) {
                salv[n_salv] = @floatFromInt(p.reach_salvage[l]);
                n_salv += 1;
            }
        }
        const med = times[times.len / 2];
        const salv_med: f64 = if (n_salv > 0) median(salv[0..n_salv]) else 0;
        var tgt_buf: [16]u8 = undefined;
        const tgt = if (target_hours(l)) |t| try std.fmt.bufPrint(&tgt_buf, "{d:.0}", .{t}) else "";
        try w.print("{d:>3} {d:>8.2} {d:>8.2} {d:>8.2} {s:>7} {d:>6.1} {d:>7.1} {d:>6.1} {d:>8.0} {d:>9.1}\n", .{
            l,
            med,
            quantile(times, 0.1),
            quantile(times, 0.9),
            tgt,
            if (fights > 0) 100.0 * wins / fights else 0,
            if (fights > 0) 100.0 * lost / fights else 0,
            if (fights > 0) turns / fights else 0,
            salv_med,
            // fights taken at this level per hour spent at it
            blk: {
                var hours: f64 = 0;
                for (players) |p| {
                    const next = if (l < max_lvl) p.reach_h[l + 1] else p.reach_h[l];
                    if (next < max_hours and p.reach_h[l] < max_hours) hours += next - p.reach_h[l];
                }
                break :blk if (hours > 0) fights / hours else 0;
            },
        });
    }

    try w.print("\nPOWER: median total stats of sim players on reaching a level, relative to base + reference gear\n", .{});
    try w.print("{s:>3} {s:>7} {s:>7} {s:>7} {s:>7}\n", .{ "Lvl", "hp", "atk", "def", "spd" });
    for (probe_levels) |l| {
        try w.print("{d:>3}", .{l});
        for (0..4) |k| {
            for (players, 0..) |p, i| times[i] = p.reach_ratio[l][k];
            try w.print(" {d:>7.2}", .{median(times)});
        }
        try w.print("\n", .{});
    }

    try w.print("\nXP SOURCES, share of all XP earned at levels in the band\n", .{});
    try w.print("{s:>8} {s:>7} {s:>7} {s:>7} {s:>8} {s:>7}\n", .{ "levels", "fights", "caches", "walking", "missions", "echoes" });
    for ([_][2]u8{ .{ 1, 10 }, .{ 11, 20 }, .{ 21, 30 }, .{ 31, 40 }, .{ 41, 50 } }) |band| {
        var tot = [_]f64{0} ** 5;
        for (players) |p| {
            for (band[0]..band[1] + 1) |l| {
                for (0..5) |k| tot[k] += p.xp_by[l][k];
            }
        }
        var sum: f64 = 0;
        for (tot) |v| sum += v;
        try w.print("{d:>3}-{d:<4}", .{ band[0], band[1] });
        for (tot) |v| try w.print(" {d:>7.0}", .{100.0 * v / @max(1.0, sum)});
        try w.print("\n", .{});
    }

    // Matchups: the simulated players' real builds at full HP against same-level enemies.
    try w.print("\nPVE MATCHUPS at full HP, same level, sim players' real gear (win% / turns / HP lost%)\n", .{});
    try w.print("{s:>3}", .{"Lvl"});
    for (0..probe_archetypes) |a| try w.print(" {s:>17}", .{data.archetypes[a].name.human});
    try w.print(" {s:>17}\n", .{"spawn-weighted"});
    for (probe_levels, 0..) |pl, si| {
        try w.print("{d:>3}", .{pl});
        var tot_w: f64 = 0;
        var win_w: f64 = 0;
        var lost_w: f64 = 0;
        var turns_w: f64 = 0;
        for (0..probe_archetypes) |a| {
            var c = ProbeCell{};
            for (players) |p| {
                // A random stance: all three, equally weighted.
                for (p.probes[si][a]) |pc| {
                    c.fights += pc.fights;
                    c.wins += pc.wins;
                    c.turns += pc.turns;
                    c.lost += pc.lost;
                }
            }
            try printCell(w, c);
            if (c.fights > 0) {
                const f: f64 = @floatFromInt(c.fights);
                const wt: f64 = data.archetypes[a].weight;
                tot_w += wt;
                win_w += wt * @as(f64, @floatFromInt(c.wins)) / f;
                turns_w += wt * @as(f64, @floatFromInt(c.turns)) / f;
                lost_w += wt * c.lost / f;
            }
        }
        var cell: [32]u8 = undefined;
        const mix = try std.fmt.bufPrint(&cell, "{d:.0}/{d:.1}/{d:.0}", .{ 100.0 * win_w / tot_w, turns_w / tot_w, 100.0 * lost_w / tot_w });
        try w.print(" {s:>17}", .{mix});
        try w.print("\n", .{});
    }
}

/// Win% and HP lost% of one probe cell summed over all players.
fn stanceCell(players: []const Player, si: usize, a: usize, st: usize) ProbeCell {
    var c = ProbeCell{};
    for (players) |p| {
        const pc = p.probes[si][a][st];
        c.fights += pc.fights;
        c.wins += pc.wins;
        c.turns += pc.turns;
        c.lost += pc.lost;
    }
    return c;
}

fn winFrac(c: ProbeCell) f64 {
    return if (c.fights == 0) 0 else @as(f64, @floatFromInt(c.wins)) / @as(f64, @floatFromInt(c.fights));
}

fn lostFrac(c: ProbeCell) f64 {
    return if (c.fights == 0) 0 else c.lost / @as(f64, @floatFromInt(c.fights));
}

/// The best stance against one archetype at one level, by win rate then HP kept.
fn bestStance(players: []const Player, si: usize, a: usize) usize {
    var best: usize = 0;
    for (1..stance_count) |st| {
        const c = stanceCell(players, si, a, st);
        const b = stanceCell(players, si, a, best);
        if (winFrac(c) > winFrac(b) + 1e-9 or (@abs(winFrac(c) - winFrac(b)) <= 1e-9 and lostFrac(c) < lostFrac(b))) best = st;
    }
    return best;
}

fn reportStances(w: *std.Io.Writer, players: []const Player) !void {
    try w.print("\nSTANCES at full HP, same level, spawn-weighted over the six enemy types, hours drawn across the day (win% / HP lost%)\n", .{});
    try w.print("{s:>3}", .{"Lvl"});
    for (0..stance_count) |st| try w.print(" {s:>12}", .{@tagName(@as(stance_rules.Stance, @enumFromInt(st)))});
    try w.print(" {s:>12} {s:>12} {s:>12} {s:>8}\n", .{ "random", "counter", "best", "gain" });
    for (probe_levels, 0..) |pl, si| {
        var per = [_][2]f64{.{ 0, 0 }} ** stance_count;
        var counter = [2]f64{ 0, 0 };
        var best = [2]f64{ 0, 0 };
        var tot_w: f64 = 0;
        for (0..probe_archetypes) |a| {
            const wt: f64 = data.archetypes[a].weight;
            tot_w += wt;
            for (0..stance_count) |st| {
                const c = stanceCell(players, si, a, st);
                per[st][0] += wt * winFrac(c);
                per[st][1] += wt * lostFrac(c);
            }
            const cs: usize = if (data.archetypes[a].counter) |c| @intFromEnum(c) else @intFromEnum(stance_rules.default);
            const cc = stanceCell(players, si, a, cs);
            counter[0] += wt * winFrac(cc);
            counter[1] += wt * lostFrac(cc);
            const bc = stanceCell(players, si, a, bestStance(players, si, a));
            best[0] += wt * winFrac(bc);
            best[1] += wt * lostFrac(bc);
        }
        try w.print("{d:>3}", .{pl});
        var rnd = [2]f64{ 0, 0 };
        for (per) |v| {
            try w.print(" {d:>5.1}/{d:<6.1}", .{ 100 * v[0] / tot_w, 100 * v[1] / tot_w });
            rnd[0] += v[0] / stance_count;
            rnd[1] += v[1] / stance_count;
        }
        try w.print(" {d:>5.1}/{d:<6.1} {d:>5.1}/{d:<6.1} {d:>5.1}/{d:<6.1} {d:>8.1}\n", .{
            100 * rnd[0] / tot_w,             100 * rnd[1] / tot_w,
            100 * counter[0] / tot_w,         100 * counter[1] / tot_w,
            100 * best[0] / tot_w,            100 * best[1] / tot_w,
            100 * (best[0] - rnd[0]) / tot_w,
        });
    }

    try w.print("\nBEST STANCE per enemy type, win% by stance, all probe levels pooled (counter marked *, punished marked !)\n", .{});
    try w.print("{s:>12}", .{"enemy"});
    for (0..stance_count) |st| try w.print(" {s:>11}", .{@tagName(@as(stance_rules.Stance, @enumFromInt(st)))});
    try w.print("\n", .{});
    for (0..probe_archetypes) |a| {
        const row = data.archetypes[a];
        try w.print("{s:>12}", .{row.name.human});
        for (0..stance_count) |st| {
            var c = ProbeCell{};
            for (0..probe_levels.len) |si| {
                const x = stanceCell(players, si, a, st);
                c.fights += x.fights;
                c.wins += x.wins;
                c.lost += x.lost;
            }
            const mark: u8 = if (row.counter != null and @intFromEnum(row.counter.?) == st) '*' else if (row.punished != null and @intFromEnum(row.punished.?) == st) '!' else ' ';
            try w.print(" {d:>9.1}{c} ", .{ 100 * winFrac(c), mark });
        }
        try w.print("\n", .{});
    }
}

fn reportPvp(w: *std.Io.Writer, cfg: Config) !void {
    try w.print("\nPVP, same level, standard kits (no upgrades or perks), first side's win% / turns\n", .{});
    try w.print("{s:>3} {s:>26} {s:>12} {s:>12} {s:>12}\n", .{ "Lvl", "matchup", "win%", "turns", "hp_left%" });
    const Pair = struct { a: data.Rarity, b: data.Rarity, fa: data.Faction, fb: data.Faction };
    const pairs = [_]Pair{
        .{ .a = .common, .b = .common, .fa = .human, .fb = .zombie },
        .{ .a = .common, .b = .common, .fa = .human, .fb = .human },
        .{ .a = .common, .b = .uncommon, .fa = .human, .fb = .human },
        .{ .a = .common, .b = .rare, .fa = .human, .fb = .human },
        .{ .a = .common, .b = .legendary, .fa = .human, .fb = .human },
        .{ .a = .uncommon, .b = .rare, .fa = .human, .fb = .human },
        .{ .a = .rare, .b = .legendary, .fa = .human, .fb = .human },
    };
    var log: [combat.max_log]combat.Turn = undefined;
    for ([_]u8{ 5, 10, 20, 30, 40, 50 }) |lvl| {
        for (pairs) |pr| {
            const a = kitCombatant(lvl, pr.fa, pr.a);
            const b = kitCombatant(lvl, pr.fb, pr.b);
            var wins: f64 = 0;
            var turns: f64 = 0;
            var left: f64 = 0;
            const n = 2000;
            for (0..n) |s| {
                const r = combat.fight(a, b, game.rng.hash(cfg.seed, .{ "pvp", lvl, s }), &log);
                if (r.winner == .a) wins += 1;
                turns += @floatFromInt(r.rounds);
                left += if (r.winner == .a) @as(f64, @floatFromInt(r.hp_a)) / @as(f64, @floatFromInt(a.stats.hp)) else 0;
            }
            var lbl: [40]u8 = undefined;
            const label = try std.fmt.bufPrint(&lbl, "{s} {s} v {s} {s}", .{ @tagName(pr.fa)[0..1], @tagName(pr.a), @tagName(pr.fb)[0..1], @tagName(pr.b) });
            try w.print("{d:>3} {s:>26} {d:>12.1} {d:>12.1} {d:>12.1}\n", .{ lvl, label, 100.0 * wins / n, turns / n, if (wins > 0) 100.0 * left / wins else 0 });
        }
    }
}

fn printCell(w: *std.Io.Writer, c: ProbeCell) !void {
    if (c.fights == 0) return w.print(" {s:>17}", .{"-"});
    const f: f64 = @floatFromInt(c.fights);
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d:.0}/{d:.1}/{d:.0}", .{ 100.0 * @as(f64, @floatFromInt(c.wins)) / f, @as(f64, @floatFromInt(c.turns)) / f, 100.0 * c.lost / f });
    try w.print(" {s:>17}", .{s});
}
