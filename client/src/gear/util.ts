import type { Item, Rarity, Slot, Stats } from '../api';
import type { IconName } from '../ui/Icon';
import { catalog, faction } from '../state/store';

const SLOT_NAME: Record<Slot, [string, string]> = {
  weapon: ['Weapon', 'Claws'],
  armor: ['Armor', 'Hide'],
  utility: ['Gear', 'Strain'],
};
export const SLOTS: Slot[] = ['weapon', 'armor', 'utility'];
export const SLOT_ICON: Record<Slot, IconName> = { weapon: 'baseball-bat', armor: 'hoodie', utility: 'flashlight' };
export const RARITY_ORDER: Record<Rarity, number> = { common: 0, uncommon: 1, rare: 2, legendary: 3 };

export function slotLabel(s: Slot): string { return SLOT_NAME[s][faction.value === 'zombie' ? 1 : 0]; }

/** Display name for an item, from the catalog (uniques have their own). */
export function itemTitle(it: Pick<Item, 'base' | 'unique'>): string {
  const f = faction.value ?? 'human';
  const c = catalog.value;
  if (it.unique) {
    const u = c?.uniques.find((x) => x.id === it.unique);
    if (u) return u.names[f];
  }
  return c?.items.find((i) => i.id === it.base)?.names[f] ?? it.base.replace(/_/g, ' ');
}

export function consumableName(id: string): string {
  const f = faction.value ?? 'human';
  return catalog.value?.consumables.find((c) => c.id === id)?.names[f] ?? id.replace(/_/g, ' ');
}

export function abilityName(id: string, f = faction.value ?? 'human'): string {
  return catalog.value?.abilities.find((a) => a.id === id)?.names[f] ?? id.replace(/_/g, ' ');
}

export const STAT_KEYS = ['hp', 'atk', 'def', 'spd'] as const;
export const STAT_LABEL: Record<keyof Stats, string> = { hp: 'HP', atk: 'ATK', def: 'DEF', spd: 'SPD' };

export function statLine(s: Stats): string {
  return STAT_KEYS.filter((k) => s[k]).map((k) => `${STAT_LABEL[k]} ${s[k]}`).join(' · ');
}

export function isRarePlus(r: Rarity): boolean { return RARITY_ORDER[r] >= RARITY_ORDER.rare; }

export function perkInfo(id: string): { name: string; text: string } {
  const p = catalog.value?.perks.find((x) => x.id === id);
  return p ?? { name: id.replace(/_/g, ' '), text: '' };
}

export function uniqueLore(id: string | null): string | null {
  return id ? catalog.value?.uniques.find((u) => u.id === id)?.lore ?? null : null;
}
