/*
 * outbreak.h — the entire surface between the phone and the core.
 *
 * Ten functions. What is NOT here is the point.
 *
 * =============================================================================
 * THE PHONE COMPUTES NOTHING
 *
 * There is no combat here. No tick. No quorum. No XP. No damage. No loot. The
 * phone cannot resolve a fight, because the code to resolve a fight is not in
 * this library — verified by inspecting the exported symbols, not by promising.
 *
 * The phone can do exactly three things:
 *
 *   1. Turn a GPS reading into a room, and forget the reading.
 *   2. Put bytes on a wire.
 *   3. Take bytes off a wire and read what it was told.
 *
 * Every outcome is computed on the server, from data the client cannot
 * influence. The only lie a perfectly modified phone can tell is a false cell —
 * and a false cell is worth nothing, because no cell is worth reaching.
 *
 * =============================================================================
 * THE COORDINATE DIES IN outbreak_quantize(), AND THE KOTLIN SIDE MUST HELP
 *
 * outbreak_quantize() is the only function in this entire system — on either
 * side of the network — that accepts a latitude and a longitude. It takes them,
 * returns a u64, and the floats are gone.
 *
 * THE KOTLIN SIDE MUST DO THE SAME. Take the Location object, call this, and
 * drop it in the same function. Do not store it. Do not cache it. Do not log it.
 * Do not put it in a crash report, an analytics event, or a debug toast.
 *
 * The server has no coordinate and cannot leak one. The phone is the only place
 * a coordinate ever exists, so the phone is the only place it can leak from.
 *
 * =============================================================================
 * NOTHING HERE THROWS, PANICS, OR ABORTS
 *
 * A Zig panic unwinding into the JVM is not a crash you can debug; it is a
 * corrupted runtime. So every function validates its arguments and returns a
 * status code. Hostile bytes from a hostile server get an error, never a signal.
 *
 * Check every return value.
 */

#ifndef OUTBREAK_H
#define OUTBREAK_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Zero is success. Every failure has a name. */
typedef enum {
    OUTBREAK_OK = 0,
    /* The GPS fix was NaN, infinite, or off the planet.
     * NOT AN ERROR: a phone in a tunnel does not know where it is, and that is
     * an ordinary condition. Report nothing this tick and try again. */
    OUTBREAK_BAD_COORDINATE = 1,
    /* The buffer you passed is the wrong size. Use the *_size() functions. */
    OUTBREAK_BAD_BUFFER = 2,
    /* The bytes are not a message this version understands. */
    OUTBREAK_BAD_MESSAGE = 3,
    /* A protocol version we do not speak. */
    OUTBREAK_BAD_VERSION = 4,
    /* A field carrying a value that does not exist. A hostile or broken server. */
    OUTBREAK_BAD_VALUE = 5,
} outbreak_status;

/* ------------------------------------------------------------------ the wall */

/*
 * THE ONLY DOOR IN THE COORDINATE WALL.
 *
 * A latitude and a longitude go in. A room (an opaque u64 cell id) comes out.
 *
 * Returns 0 if the fix is unusable — 0 is never a valid cell. Do not report a
 * cell of 0; simply say nothing this tick.
 *
 * A cell id is NOT a compressed coordinate. There is no function anywhere that
 * converts one back toward a latitude. It is a room, not a point.
 */
uint64_t outbreak_quantize(double lat, double lon, uint8_t precision);

/* The precision to use before the server has told you otherwise. */
uint8_t outbreak_default_precision(void);

/* ---------------------------------------------------------------- frame sizes */

/* Every frame is a FIXED SIZE. There is no length field anywhere in this
 * protocol — so there is no length field to get wrong, and no length field for
 * an attacker to lie about. Ask for the size; do not hard-code it. */
int outbreak_hello_size(void);
int outbreak_report_size(void);
int outbreak_response_size(void);
int outbreak_welcome_size(void);

/* ------------------------------------------------------------------ handshake */

/*
 * Register or log in. `faction` is 0 = human, 1 = zombie, chosen once and
 * permanently. `registering` selects create-account vs log-in.
 *
 * The contact point and password are copied into the frame and nothing is kept.
 * They travel inside TLS. Wipe your own copies afterwards.
 */
outbreak_status outbreak_encode_hello(
    const char *contact,
    const char *password,
    uint8_t faction,
    bool registering,
    uint8_t *out,
    int out_len);

/*
 * What the server said. `out_precision` is the cell precision it wants you to
 * quantize at — USE IT, and re-read it on every session. It can change, and
 * that is deliberate: it is what lets the cell size be tuned without an app
 * update.
 */
outbreak_status outbreak_decode_welcome(
    const uint8_t *bytes,
    int len,
    uint64_t *out_session,
    uint8_t *out_precision,
    uint8_t *out_tick_seconds);

/* ------------------------------------------------------------- the whole game */

/*
 * THE ENTIRE OUTBOUND VOCABULARY OF THE PHONE, AFTER THE HANDSHAKE.
 *
 * A session, a room, and bounded equipment intent. The server remains authoritative
 * over combat, rewards, progression, and whether the selection is currently legal.
 */
outbreak_status outbreak_encode_report(
    uint64_t session,
    uint64_t cell,
    uint8_t kit,
    uint8_t weapon,
    uint8_t armor,
    uint8_t utility,
    uint8_t *out,
    int out_len);

/*
 * What you are told, every tick, whether or not anything happened.
 *
 * NOTE WHAT IS ABSENT: there is no occupant count, no hostile tally, no list of
 * who is here, and no position for anyone. `crowd` is a coarse BAND, sampled
 * once when a fight began and never refreshed — so a person leaving the room
 * cannot be watched, because there is nothing to watch move.
 */
typedef struct {
    uint64_t tick;
    uint32_t total_xp;
    uint16_t hp;
    uint16_t damage;  /* taken this tick */
    uint16_t xp;      /* earned this tick */
    uint16_t level;
    /* 0 even | 1 humans have the edge | 2 zombies have the edge
     * 3 humans are winning | 4 zombies are winning */
    uint8_t momentum;
    /* 0 a few | 1 dozens | 2 scores | 3 hundreds | 4 thousands
     * A BAND, never a number. It does not move during a fight. */
    uint8_t crowd;
    /* 0 field | 1 raider | 2 bulwark */
    uint8_t kit;
    /* 0 none | 1 weapon parts | 2 armor parts | 3 field supplies */
    uint8_t reward;
    uint16_t salvage;
    uint32_t owned;    /* bitset of the 24 authored discoveries */
    uint8_t weapon;    /* equipped catalogue id */
    uint8_t armor;     /* equipped catalogue id */
    uint8_t utility;   /* equipped catalogue id */
    uint8_t item;      /* latest drop id, 255 when none */
    uint8_t discovered;/* 1 new discovery, 0 duplicate/no item */
    uint8_t capacity;  /* equipment discoveries available */
} outbreak_tell;

/*
 * Read what the server told you. Never panics, whatever the bytes say.
 *
 * A QUIET TICK AND A BUSY ONE ARE THE SAME SIZE, and arrive at the same moment
 * (the tick boundary). If damage and xp are 0, nothing happened to you — and
 * that is indistinguishable from standing alone in an empty field, on purpose.
 */
outbreak_status outbreak_decode_tell(
    const uint8_t *bytes,
    int len,
    outbreak_tell *out);

#ifdef __cplusplus
}
#endif

#endif /* OUTBREAK_H */
