// The Naut mark: one moment of the Lorenz system laid onto the circles the
// sauropod was drawn with (left wing -> body circle, right wing -> neck circle).
// Only the starting point is random; everything after is plain Euler steps
// with + - x, so the ID below always reproduces the same picture.
//
//   node brand/mark.js        regenerates brand/*.svg (dark and light)
//
// ID: seed 13508 · eps 1e-5 · n 240 · t 27.40 · trail 3.5
// macos/Naut.icns is naut-icon.svg rendered at 1024 px (a browser is needed
// for mix-blend-mode), cut to the tile and run through iconutil.

const GEOM = {"arch": {"body": "M150.0 742.0 A230.0 230.0 0 0 1 610.0 742.0 L460.0 742.0 A80.0 80.0 0 0 0 300.0 742.0 Z", "neck": "M502.0 742.0 L502.0 552.0 A248.0 248.0 0 0 1 842.9 322.1 A54.0 54.0 0 0 1 802.4 422.2 A140.0 140.0 0 0 0 610.0 552.0 L610.0 742.0 Z", "tail": "M248.1 553.6 A260.0 260.0 0 0 0 -40.0 736.0 A380.0 380.0 0 0 1 152.0 742.0 Z", "bounds": [-40, 304, 876.673679122687, 742], "bodyC": [380, 742], "R": 230, "r": 80, "neckC": [750, 552], "Ro": 248, "Ri": 140, "headC": [822.7, 372.1], "cap": 54.0}, "mono": {"body": "M0 0 V-162.0 A101.0 101.0 0 0 1 202.0 -162.0 V0", "tail": "M25.9 -229.6 A300 300 0 0 0 -230 -96", "neck": "M168.6 -237.1 L292.4 -374.5", "lensC": [349.9, -438.4], "lensR": 86, "W": 74, "shoulderC": [101.0, -162.0], "R": 101.0, "tailTip": [-230, -96], "bounds": [-267.0, -561.4498750775906, 472.91658556549527, 0]}};
const PAL = [[61, 90, 254], [143, 107, 255], [255, 180, 138]];
// Light paper can't take added light, so the light theme lays ink instead:
// deeper versions of the same three hues, multiplied onto the paper.
const THEMES = {
  dark: { bg: "#05060b", pal: PAL, blend: "plus-lighter", alpha: .34, ghost: ".11", guide: "#8f6bff" },
  light: { bg: "#fbfaf7", pal: [[30, 52, 210], [98, 58, 214], [222, 98, 52]], blend: "multiply", alpha: .26, ghost: ".07", guide: "#6a45e0" },
};
const hex = c => "#" + c.map(v => Math.round(v).toString(16).padStart(2, "0")).join("");
function palHex(t, PAL = THEMES.dark.pal) {
  const i = t < .5 ? 0 : 1, f = t < .5 ? t * 2 : (t - .5) * 2;
  return hex(PAL[i].map((v, k) => v + (PAL[i + 1][k] - v) * f));
}
function rng(seed) {
  return () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
}
const LOBE = Math.sqrt(8 / 3 * 27), DT = .005, TMAX = 40, BASE = 742;

/* Same mapping as the live study: each wing laid onto its construction circle. */
function map(x, z) {
  const g = GEOM.arch, w = 1 / (1 + Math.exp(-x / 1.5));
  const on = (cx, C, R) => {
    const dx = (x - cx) / 9, dz = (z - 27) / 13, a = Math.atan2(dz, dx), rr = R * (.62 + .38 * Math.hypot(dx, dz));
    return [C[0] + Math.cos(a) * rr, C[1] - Math.sin(a) * rr];
  };
  const b = on(-LOBE, g.bodyC, 155), n = on(LOBE, g.neckC, 194);
  return [b[0] + (n[0] - b[0]) * w, b[1] + (n[1] - b[1]) * w];
}

/* Integrates every strand once and keeps every mapped position, so any moment
   can be cut out later without re-running. Plain Euler with only + − ×, so a
   seed always reproduces the same picture. */
let SIM = null;
function simulate(seed, eps, N) {
  const steps = Math.round(TMAX / DT), r = rng(seed), x0 = r() * 2 - 1, e = 10 ** eps;
  const pos = new Float32Array(N * (steps + 1) * 2);
  for (let i = 0; i < N; i++) {
    // spread the strands over the same total width whatever N is
    let x = x0 + i * e * (320 / N), y = 1, z = 20, o = i * (steps + 1) * 2;
    for (let s = 0; s <= steps; s++) {
      const [px, py] = map(x, z); pos[o + 2 * s] = px; pos[o + 2 * s + 1] = py;
      const dx = 10 * (y - x), dy = x * (28 - z) - y, dz = x * y - 8 / 3 * z;
      x += DT * dx; y += DT * dy; z += DT * dz;
    }
  }
  return { seed, eps, N, steps, pos };
}

/* Ramer–Douglas–Peucker, then Catmull–Rom to cubic Bézier. */
function rdp(pts, tol) {
  if (pts.length < 3) return pts;
  const keep = new Uint8Array(pts.length); keep[0] = keep[pts.length - 1] = 1;
  const stack = [[0, pts.length - 1]];
  while (stack.length) {
    const [a, b] = stack.pop(); let md = 0, mi = -1;
    const [ax, ay] = pts[a], [bx, by] = pts[b], dx = bx - ax, dy = by - ay, l = Math.hypot(dx, dy) || 1e-9;
    for (let i = a + 1; i < b; i++) { const d = Math.abs(dy * pts[i][0] - dx * pts[i][1] + bx * ay - by * ax) / l; if (d > md) { md = d; mi = i; } }
    if (md > tol) { keep[mi] = 1; stack.push([a, mi], [mi, b]); }
  }
  return pts.filter((_, i) => keep[i]);
}
const f2 = v => (Math.round(v * 10) / 10).toString();
function bezier(p) {
  let d = `M${f2(p[0][0])} ${f2(p[0][1])}`;
  for (let i = 0; i < p.length - 1; i++) {
    const p0 = p[Math.max(0, i - 1)], p1 = p[i], p2 = p[i + 1], p3 = p[Math.min(p.length - 1, i + 2)];
    d += `C${f2(p1[0] + (p2[0] - p0[0]) / 6)} ${f2(p1[1] + (p2[1] - p0[1]) / 6)} ${f2(p2[0] - (p3[0] - p1[0]) / 6)} ${f2(p2[1] - (p3[1] - p1[1]) / 6)} ${f2(p2[0])} ${f2(p2[1])}`;
  }
  return d;
}

/* Builds the mark as an SVG string. Strands are stored once in <defs> and
   reused three times: bright inside the mark, faint outside, and mirrored on
   the floor. Strands add up through mix-blend-mode: plus-lighter on dark,
   multiply on light. */
const CHUNKS = 4, WIDTH = .9;
function build(sim, t, trail, opt) {
  const { N, steps, pos } = sim, g = GEOM.arch, th = THEMES[opt.theme || "dark"], ALPHA = th.alpha;
  const s1 = Math.min(steps, Math.round(t / DT)), s0 = Math.max(0, s1 - Math.round(trail / DT));
  let strands = "";
  for (let i = 0; i < N; i++) {
    const o = i * (steps + 1) * 2, col = palHex(i / (N - 1), th.pal);
    for (let k = 0; k < CHUNKS; k++) {
      const a = s0 + Math.floor((s1 - s0) * k / CHUNKS), b = s0 + Math.floor((s1 - s0) * (k + 1) / CHUNKS);
      if (b - a < 2) continue;
      const pts = []; for (let s = a; s <= b; s++) pts.push([pos[o + 2 * s], pos[o + 2 * s + 1]]);
      const op = ALPHA * Math.pow((k + 1) / CHUNKS, 1.6);
      strands += `<path d="${bezier(rdp(pts, opt.tol ?? .22))}" stroke="${col}" stroke-opacity="${op.toFixed(3)}"/>`;
    }
  }
  const box = opt.box || [-80, 230, 1010, opt.floor ? 830 : 760];
  const [vx, vy, vw, vh] = [box[0], box[1], box[2] - box[0], box[3] - box[1]];
  const guides = opt.guides ? `<g fill="none" stroke="${th.guide}" stroke-opacity=".22" stroke-width=".8" stroke-dasharray="4 6">
<circle cx="${g.bodyC[0]}" cy="${g.bodyC[1]}" r="155"/><circle cx="${g.neckC[0]}" cy="${g.neckC[1]}" r="194"/></g>
<line x1="${vx}" y1="${BASE}" x2="${vx + vw}" y2="${BASE}" stroke="${th.guide}" stroke-opacity=".35" stroke-width=".8"/>` : "";
  return `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="${vx} ${vy} ${vw} ${vh}" data-naut="seed ${sim.seed} eps 1e${sim.eps} n ${N} t ${t.toFixed(2)} trail ${trail.toFixed(1)}">
<style>.nst path{fill:none;stroke-width:${WIDTH};stroke-linecap:round;stroke-linejoin:round;mix-blend-mode:${th.blend}}</style>
<defs>
<g id="nst" class="nst">${strands}</g>
<mask id="nmask" maskUnits="userSpaceOnUse" x="${vx}" y="${vy}" width="${vw}" height="${vh}">
<path d="${g.tail}" fill="#fff"/><path d="${g.neck}" fill="#fff"/>
<path d="${g.body}" fill="#fff"/></mask>
<clipPath id="nabove"><rect x="${vx}" y="${vy}" width="${vw}" height="${BASE - vy}"/></clipPath>
</defs>
<rect x="${vx}" y="${vy}" width="${vw}" height="${vh}" fill="${th.bg}"/>
<g style="isolation:isolate">
${opt.ghost ? `<use href="#nst" xlink:href="#nst" opacity="${th.ghost}" clip-path="url(#nabove)"/>` : ""}
<use href="#nst" xlink:href="#nst" mask="url(#nmask)"/>
${opt.floor ? `<g transform="matrix(1 0 0 -.3 0 ${1.3 * BASE})"><use href="#nst" xlink:href="#nst" mask="url(#nmask)" opacity=".2"/></g>` : ""}
</g>
${guides}
</svg>`;
}


const fs = require("fs"), path = require("path");
const sim = simulate(13508, -5, 240), box = [190, 282, 982, 770];
const opt = guides => ({ guides, floor: false, ghost: true, tol: .6, box });
const out = name => path.join(__dirname, name);
fs.writeFileSync(out("naut-mark.svg"), build(sim, 27.4, 3.5, opt(true)));
fs.writeFileSync(out("naut-mark-clean.svg"), build(sim, 27.4, 3.5, opt(false)));
fs.writeFileSync(out("naut-mark-light.svg"), build(sim, 27.4, 3.5, { ...opt(true), theme: "light" }));
fs.writeFileSync(out("naut-mark-clean-light.svg"), build(sim, 27.4, 3.5, { ...opt(false), theme: "light" }));
// The app icon: the clean mark on the macOS tile (824 on 1024, radius 185) with the app's lit edge.
const mark = build(sim, 27.4, 3.5, { ...opt(false), box: [150, 240, 1022, 812] })
  .replace("<svg ", '<svg x="132" y="262" width="760" height="500" ');
fs.writeFileSync(out("naut-icon.svg"), `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<defs><linearGradient id="edge" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".16"/><stop offset="1" stop-color="#fff" stop-opacity=".06"/></linearGradient>
<clipPath id="tile"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath></defs>
<rect x="100" y="100" width="824" height="824" rx="185" fill="#05060b"/>
<g clip-path="url(#tile)">${mark}</g>
<rect x="102" y="102" width="820" height="820" rx="183" fill="none" stroke="url(#edge)" stroke-width="4"/>
</svg>`);
