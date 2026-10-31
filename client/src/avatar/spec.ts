/** The avatar is a plain object of small integers (about 70 bytes serialized; the server allows 300). */
export interface AvatarSpec {
  body: number;
  skin: number;
  face: number;
  hair: number;
  hcol: number;
  facial: number;
  scar: number;
}

export const KEYS = ['body', 'skin', 'face', 'hair', 'hcol', 'facial', 'scar'] as const;
export type AvatarKey = (typeof KEYS)[number];

/** Option counts; must match the limits in server/src/api/account.zig. */
export const COUNT: Record<AvatarKey, number> = { body: 3, skin: 8, face: 6, hair: 10, hcol: 8, facial: 4, scar: 4 };

/** Skin tones across the real range. heat is the thermal value the tone reads as in the Heat lens. */
export const SKINS = [
  { name: 'Porcelain', hex: '#F4DCCB', heat: 0.8 },
  { name: 'Fair', hex: '#EBC4A2', heat: 0.76 },
  { name: 'Light olive', hex: '#DDAA7E', heat: 0.72 },
  { name: 'Tan', hex: '#C58E5C', heat: 0.68 },
  { name: 'Brown', hex: '#A56D3E', heat: 0.64 },
  { name: 'Deep brown', hex: '#7F4C2B', heat: 0.6 },
  { name: 'Dark', hex: '#5A3320', heat: 0.56 },
  { name: 'Ebony', hex: '#3A2216', heat: 0.52 },
] as const;

/** Six natural colours, then two dyed. */
export const HAIRS = [
  { name: 'Black', hex: '#1B1816', heat: 0.18 },
  { name: 'Dark brown', hex: '#3C2619', heat: 0.24 },
  { name: 'Brown', hex: '#6A4428', heat: 0.3 },
  { name: 'Auburn', hex: '#8E3E22', heat: 0.36 },
  { name: 'Blond', hex: '#C9A55C', heat: 0.46 },
  { name: 'Grey', hex: '#A4A6A4', heat: 0.42 },
  { name: 'Faded red', hex: '#B3262E', heat: 0.52 },
  { name: 'Ash blue', hex: '#3F78A8', heat: 0.2 },
] as const;

export const NAMES: Record<AvatarKey, readonly string[]> = {
  body: ['Build A', 'Build B', 'Build C'],
  skin: SKINS.map((s) => s.name),
  face: ['Oval', 'Round', 'Square', 'Long', 'Heart', 'Gaunt'],
  hair: ['Shaved', 'Buzz', 'Crop', 'Side part', 'Slick back', 'Bob', 'Long', 'Afro', 'Mohawk', 'Bun'],
  hcol: HAIRS.map((h) => h.name),
  facial: ['None', 'Stubble', 'Moustache', 'Beard'],
  scar: ['None', 'Cheek scar', 'Split brow', 'Burn'],
};

function rng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** A random pleasant default: mostly plain, a little character. Same seed, same face. */
export function avatarDefaults(seed: number | string = Math.random() * 4294967296): AvatarSpec {
  let s = 0;
  if (typeof seed === 'number') s = Math.floor(seed) >>> 0;
  else for (let i = 0; i < seed.length; i++) s = (Math.imul(s, 31) + seed.charCodeAt(i)) >>> 0;
  const r = rng(s);
  const pick = (n: number) => Math.floor(r() * n);
  return {
    body: pick(3),
    skin: pick(8),
    face: pick(6),
    hair: pick(10),
    hcol: r() < 0.12 ? 6 + pick(2) : pick(6),
    facial: r() < 0.65 ? 0 : 1 + pick(3),
    scar: r() < 0.7 ? 0 : 1 + pick(3),
  };
}

/** Coerce anything (server data, old saves) into an in-range spec. */
export function cleanAvatar(raw: unknown): AvatarSpec {
  const d = avatarDefaults(1);
  const o = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>;
  const out = { ...d };
  for (const k of KEYS) {
    const v = o[k];
    out[k] = typeof v === 'number' && Number.isInteger(v) && v >= 0 && v < COUNT[k] ? v : d[k];
  }
  return out;
}

export function hasAvatar(raw: unknown): boolean {
  return !!raw && typeof raw === 'object' && KEYS.every((k) => typeof (raw as Record<string, unknown>)[k] === 'number');
}

/** Human gear unlocks every 5 levels (title tier). */
export const humanTier = (level: number) => Math.max(0, Math.floor(level / 5));

/** Zombie decay stage: 0 pallor, 1 veins, 2 torn skin, 3 exposed jaw, 4 glowing eyes. */
export function decayStage(level: number): number {
  return level >= 35 ? 4 : level >= 22 ? 3 : level >= 12 ? 2 : level >= 5 ? 1 : 0;
}
