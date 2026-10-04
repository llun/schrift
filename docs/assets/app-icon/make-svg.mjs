// Builds Schrift's "Soft relief" app-icon masters as plain SVG.
//
// This file is the source of truth for the icon: every PNG in the asset catalog is
// rendered from what it writes (see export.sh beside it). Change a number here and
// re-export — never hand-edit or AI-regenerate the PNGs. Run: `node make-svg.mjs`.
import { writeFileSync } from 'node:fs';
const out = new URL('./', import.meta.url);

// Nib drawn pointing UP in local space from the origin; its rounded point peaks at
// (0, -4.5). Placed with its axis on the tile's diagonal x + y = 1024, so it leaves
// exactly through the top-right corner.
const NIB = `M4.5 -12
C34 -104 92 -250 134 -372
C162 -452 206 -504 222 -568
C236 -624 220 -678 190 -718
C168 -748 164 -802 176 -862
C186 -912 214 -962 238 -1012
L240 -1500 L-240 -1500 L-238 -1012
C-214 -962 -186 -912 -176 -862
C-164 -802 -168 -748 -190 -718
C-220 -678 -236 -624 -222 -568
C-206 -504 -162 -452 -134 -372
C-92 -250 -34 -104 -4.5 -12
Q0 3 4.5 -12 Z`;
// Breather hole + slit (slit stops short of the tip so the point stays one clean point).
const HOLE = `M0 -458 a56 56 0 1 0 0 112 a56 56 0 1 0 0 -112 Z`;
const SLIT = `M-10 -400 L10 -400 L2.2 -84 Q0 -74 -2.2 -84 Z`;
// Origin at (205, 819), so the point renders at ~(208, 816); axis on the diagonal x + y = 1024; puts the hole on the tile centre.
const PLACE = 'translate(205 819) rotate(45) scale(1.08)';

const palettes = {
  light: {
    bg: [['0', '#7F7CF7'], ['0.5', '#5F5BE0'], ['1', '#3F39B6']],
    glow: '#FFFFFF', glowOpacity: 0.14,
    face: ['#FFFFFF', '#F1EFFE'], relief: ['#D6D3FC', '#ABA6F2'],
    shadow: '#231F7A', shadowOpacity: 0.38,
  },
  dark: {
    bg: [['0', '#2A2858'], ['0.55', '#18172F'], ['1', '#0E0D1C']],
    glow: '#7B79E8', glowOpacity: 0.30,
    face: ['#ECEAFF', '#CFCBFA'], relief: ['#7B79E8', '#4F4BC0'],
    shadow: '#000000', shadowOpacity: 0.55,
  },
  // Tinted/mono: iOS recolours a grayscale foreground over black.
  tinted: {
    bg: [['0', '#1C1C1C'], ['1', '#000000']],
    glow: '#FFFFFF', glowOpacity: 0.06,
    face: ['#FFFFFF', '#E2E2E2'], relief: ['#8E8E8E', '#6B6B6B'],
    shadow: '#000000', shadowOpacity: 0.6,
  },
};

function svg(name, p, { layer = 'all' } = {}) {
  const stops = p.bg.map(([o, c]) => `<stop offset="${o}" stop-color="${c}"/>`).join('');
  const bg = `<rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#glow)"/>`;
  const fg = `
  <g filter="url(#shadow)" opacity="${p.shadowOpacity}">
    <g transform="translate(18 28)"><g transform="${PLACE}"><path d="${NIB}" fill="${p.shadow}"/></g></g>
  </g>
  <g mask="url(#cut)">
    <!-- relief: the same nib sheared about its tip, so the lavender edge grows from
         nothing at the point to ~28px at the shoulder (|y| x tan 2.6deg x 1.08) -->
    <g transform="${PLACE} skewX(-2.6)"><path d="${NIB}" fill="url(#relief)"/></g>
    <g transform="${PLACE}"><path d="${NIB}" fill="url(#face)"/></g>
  </g>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <title>Schrift app icon (${name})</title>
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1024" y2="1024" gradientUnits="userSpaceOnUse">${stops}</linearGradient>
    <radialGradient id="glow" cx="170" cy="120" r="760" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="${p.glow}" stop-opacity="${p.glowOpacity}"/>
      <stop offset="1" stop-color="${p.glow}" stop-opacity="0"/>
    </radialGradient>
    <!-- face: light from the upper-left, across the nib -->
    <linearGradient id="face" x1="-220" y1="0" x2="220" y2="0" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="${p.face[0]}"/><stop offset="1" stop-color="${p.face[1]}"/>
    </linearGradient>
    <linearGradient id="relief" x1="0" y1="0" x2="0" y2="-1000" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="${p.relief[0]}"/><stop offset="1" stop-color="${p.relief[1]}"/>
    </linearGradient>
    <mask id="cut" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
      <rect width="1024" height="1024" fill="#fff"/>
      <g transform="${PLACE}" fill="#000"><path d="${HOLE}"/><path d="${SLIT}"/></g>
    </mask>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="18"/></filter>
  </defs>
  ${layer !== 'fg' ? bg : ''}${layer !== 'bg' ? fg : ''}
</svg>
`;
}

for (const [name, p] of Object.entries(palettes)) {
  writeFileSync(new URL(`schrift-icon-${name}.svg`, out), svg(name, p));
}
// Separate layers, the shape Icon Composer wants (background fill + foreground glyph).
writeFileSync(new URL('layer-background-light.svg', out), svg('background', palettes.light, { layer: 'bg' }));
writeFileSync(new URL('layer-nib-light.svg', out), svg('nib', palettes.light, { layer: 'fg' }));
console.log('ok');
