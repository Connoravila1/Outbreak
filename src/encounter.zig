//! CORE. The origin of an encounter, kept explicit so environmental pressure is never presented
//! as if it were another human being nearby.

pub const Source = enum(u8) {
    none,
    ambient,
    players,
};
