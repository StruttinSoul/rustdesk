// Run against a COPY of the light V4 .fig to produce a matching editable dark variant.
// Leave image/video stand-ins intact: a remote stream must not be tinted by the theme.
const page = figma.currentPage;
page.name = 'MIRPG STUDIO V4 / Dark workspace / 2026-10-12';
const rgb = hex => {
  const h = hex.replace('#','');
  return {r:parseInt(h.slice(0,2),16)/255,g:parseInt(h.slice(2,4),16)/255,b:parseInt(h.slice(4,6),16)/255};
};
const asHex = c => '#'+[c.r,c.g,c.b].map(x=>Math.round(x*255).toString(16).padStart(2,'0')).join('').toUpperCase();

// Match the existing V4 semantic tokens by value, with separate on-dark text and
// button/shape accents to preserve legible white text on filled blue controls.
const palette = {
  '#F5F7FA':'#101923', // canvas
  '#FFFFFF':'#1C2938', // surfaces; white text is handled separately
  '#192431':'#F0F5FC', // primary text and outline icons
  '#5E6D7F':'#BBC8D8', // secondary text
  '#526273':'#A5B5CA', // tertiary text and inactive icons
  '#DCE3EA':'#36475B', // dividers and borders
  '#EDF1F5':'#29394A', // soft panels
  '#2855CC':'#3964CF', // filled blue actions (text below gets a brighter shade)
  '#EAF0FF':'#273B60', // selected tabs
  '#0C795D':'#70D8B0', // connected text and indicators
  '#E4F5EF':'#1D3D36', // connected pill background
  '#FFF4E2':'#483B2B', // warning badge
  '#EBC998':'#AA8145', // warning badge stroke
  '#835314':'#FFE0A6', // warning badge glyph
};
const illustrations = [
  'Illustrative Windows preview',
  'MapleStory R illustrative preview',
  'MapleStory Idle illustrative preview',
  'Remote game video 317x852',
  'Windows video stage',
];
function inIllustration(node) {
  for (let n = node; n && n !== page; n = n.parent) {
    if (illustrations.includes(n.name)) return true;
  }
  return false;
}
function inSystemRailIcon(node) {
  let seenIcon = false;
  for (let n = node; n && n !== page; n = n.parent) {
    if (n.name.startsWith('Vector icon / ')) seenIcon = true;
    if (n.name === 'Reserved system button rail') return seenIcon;
  }
  return false;
}
let changed = 0, skipped = 0;
function repaint(node, prop) {
  if (!Array.isArray(node[prop]) || node[prop].length === 0) return;
  let any = false;
  const paints = node[prop].map(paint => {
    // OpenPencil represents shape fills as SOLID paints and strokes as
    // color-bearing records without a type field.
    if ((paint.type && paint.type !== 'SOLID') || !paint.color) return paint;
    const original = asHex(paint.color);
    let target = palette[original];
    if (original === '#FFFFFF' && node.type === 'TEXT') target = '#FFFFFF';
    // Android system-button icons sit on an existing dark rail. Their white
    // strokes/fills are foreground glyphs, never light-theme card surfaces.
    // The second case also repairs previously generated dark variants.
    if (inSystemRailIcon(node) && (original === '#FFFFFF' || original === '#1C2938')) target = '#FFFFFF';
    if (original === '#2855CC' && node.type === 'TEXT') target = '#A4BCFF';
    if (original === '#0C795D' && node.type === 'TEXT') target = '#70D8B0';
    if (!target || target === original) return paint;
    any = true;
    return {...paint, color:rgb(target)};
  });
  if (any) {node[prop] = paints; changed++;}
}
for (const artboard of page.children.filter(n=>n.type==='FRAME')) {
  artboard.name = artboard.name.replace(' / Light workspace',' / Dark workspace');
  artboard.name = artboard.name.replace(/^([0-9]{2}) \/ /,'$1 / Dark / ');
  for (const node of [artboard, ...artboard.findAll(()=>true)]) {
    if (inIllustration(node)) {skipped++; continue;}
    repaint(node,'fills');
    repaint(node,'strokes');
  }
}
console.log('Dark theme: '+page.children.length+' editable artboards, '+changed+' paint changes, '+skipped+' illustration layers preserved.');
