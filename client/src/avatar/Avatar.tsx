import { memo } from 'preact/compat';
import type { Faction } from '../api';
import type { Lens } from '../state/store';
import { hash, makePaint, mix } from './paint';
import {
  Background, Body, BODIES, Defs, Ears, FACES, Face, Facial, Features, HairBack, HairFront,
  HumanFace, HumanGearBody, HumanGearHead, Scar, ZombieFace, ZombieGarment, type Ctx,
} from './parts';
import { FieldPaint, HumanSkinBody, HumanSkinHead, ZombieGrowth, ZombieGrowthTop } from './skins';
import { HAIRS, HUMAN_LOOKS, SKINS, ZOMBIE_LOOK_STAGE, cleanAvatar, decayStage, humanTier, type AvatarSpec } from './spec';

export interface AvatarProps {
  spec: AvatarSpec | Record<string, unknown> | null | undefined;
  faction: Faction;
  level: number;
  lens: Lens;
  size?: number;
  /** Accessible name; omit for a decorative avatar. */
  label?: string;
}

/** A layered, procedurally drawn bust. Pure: same props, same picture. */
export const Avatar = memo(function Avatar({ spec, faction, level, lens, size = 96, label }: AvatarProps) {
  const s = cleanAvatar(spec);
  const zombie = faction === 'zombie';
  const heat = lens === 'heat';
  const lv = Math.max(1, Math.floor(level || 1));
  // A chosen look overrides what the level would show; 0 is automatic.
  const look = s.look;
  const stage = zombie ? (look > 0 ? ZOMBIE_LOOK_STAGE[look] : decayStage(lv)) : 0;
  const auto = zombie ? 0 : humanTier(lv);
  const hl = !zombie && look > 0 ? HUMAN_LOOKS[look] : { face: auto, body: auto, head: auto };
  const tier = hl.face;
  const sizeBucket = size < 56 ? 'a' : size < 110 ? 'b' : 'c';
  const id = 'av' + hash(JSON.stringify([s, zombie, stage, tier, heat, sizeBucket]));
  const P = makePaint(heat, zombie, size);

  const tone = SKINS[s.skin], hr = HAIRS[s.hcol];
  const skin = zombie ? mix(tone.hex, '#9DA494', 0.22 + stage * 0.04) : tone.hex;
  const skinH = tone.heat - (zombie ? 0.07 + stage * 0.015 : 0);
  const c: Ctx = {
    P, s, id, zombie, stage, tier, bodyTier: hl.body, headTier: hl.head, look, skin, skinH,
    hair: zombie ? mix(hr.hex, '#6B6E64', 0.25) : hr.hex, hairH: hr.heat,
    g: FACES[s.face], nk: BODIES[s.body].nk, sw: BODIES[s.body].sw,
  };

  return (
    <svg viewBox="-4 5 108 108" width={size} height={size} role={label ? 'img' : undefined} aria-label={label} aria-hidden={label ? undefined : true} class="avatar-svg">
      <Defs c={c} />
      <Background c={c} />
      <HairBack c={c} />
      <Body c={c} />
      {zombie ? <ZombieGarment c={c} /> : <HumanGearBody c={c} />}
      {!zombie && <HumanSkinBody c={c} />}
      <Ears c={c} />
      <Face c={c} />
      <Facial c={c} />
      <Features c={c} />
      <Scar c={c} />
      {zombie ? <ZombieFace c={c} /> : <HumanFace c={c} />}
      {!zombie && <FieldPaint c={c} />}
      <HairFront c={c} />
      {!zombie && <HumanGearHead c={c} />}
      {!zombie && <HumanSkinHead c={c} />}
      {zombie && <ZombieGrowth c={c} />}
      {zombie && <ZombieGrowthTop c={c} />}
    </svg>
  );
});
