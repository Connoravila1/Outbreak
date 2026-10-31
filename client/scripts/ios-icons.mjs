// Generates the iOS AppIcon (1024 universal, no alpha) from assets/logo.png and a solid
// neutral (#0B0C0E) launch image. Needs ImageMagick (`magick` or `convert`) on PATH.
// Run: npm run icons:ios
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const logo = resolve(root, '../assets/logo.png');
const xc = resolve(root, 'ios/App/App/Assets.xcassets');

function im(args) {
  for (const bin of ['magick', 'convert']) {
    try { execFileSync(bin, args, { stdio: 'inherit' }); return; } catch (e) { if (e.code !== 'ENOENT') throw e; }
  }
  throw new Error('ImageMagick not found');
}

im([logo, '-resize', '1024x1024', '-background', '#0B0C0E', '-alpha', 'remove', '-alpha', 'off', `${xc}/AppIcon.appiconset/AppIcon-512@2x.png`]);
for (const f of ['splash-2732x2732.png', 'splash-2732x2732-1.png', 'splash-2732x2732-2.png']) {
  im(['-size', '2732x2732', 'xc:#0B0C0E', `${xc}/Splash.imageset/${f}`]);
}
console.log('iOS icon and splash written.');
