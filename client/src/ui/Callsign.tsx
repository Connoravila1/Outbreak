import { catalog, lens } from '../state/store';

/** The hex a callsign colour is drawn in on the current lens (paper wants a dark one, thermal a bright one). */
export function colorHex(id: string | null | undefined): string | undefined {
  if (!id) return undefined;
  const c = catalog.value?.cosmetics?.find((x) => x.id === id);
  if (!c) return undefined;
  return (lens.value === 'survey' ? c.survey : c.heat) ?? undefined;
}

/** A callsign, in the colour its owner wears (none by default). Used wherever callsigns are listed, never in a fight. */
export function Callsign({ name, color, class: cls }: { name: string; color?: string | null; class?: string }) {
  const hex = colorHex(color);
  return <span class={cls} style={hex ? { color: hex } : undefined}>{name}</span>;
}
