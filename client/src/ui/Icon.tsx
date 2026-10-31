import { ICONS, ICON_VIEWBOX, type IconName } from './icon-data';

export type { IconName };

interface Props { name: IconName; size?: number; class?: string; title?: string }

/** game-icons.net glyph (CC BY 3.0) from the generated subset. Inherits currentColor. */
export function Icon({ name, size = 24, class: cls, title }: Props) {
  const body = ICONS[name] ?? '';
  return (
    <svg
      class={'icon' + (cls ? ' ' + cls : '')}
      width={size}
      height={size}
      viewBox={`0 0 ${ICON_VIEWBOX} ${ICON_VIEWBOX}`}
      role={title ? 'img' : undefined}
      aria-hidden={title ? undefined : true}
      aria-label={title}
      focusable="false"
      dangerouslySetInnerHTML={{ __html: body }}
    />
  );
}
