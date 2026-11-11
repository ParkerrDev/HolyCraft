// Shared pieces of the C1 regression checks: the HolyCraft world layout, a test scene of
// flat ground with walls and a ceiling, 48 fixed and seeded poses, an exact ray traversal (slow,
// fresh boundary arithmetic, tests the start cell, enters the world box from outside) and the
// per-pixel classification. The two harnesses (web.mjs, tos.mjs) supply the renderer.
export const WX = 128, WZ = 128, WY = 40, EYE = 1.62;
export const widx = (x, y, z) => x + WX * (z + WZ * y);
export const CODE0 = 32, SKY0 = 200;                      // unique colors poked into the face tables

export function mulberry(seed) {
  let a = seed >>> 0;
  return () => { a = (a + 0x6D2B79F5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}

export function colTop(world, x, z) {
  for (let y = WY - 1; y >= 0; y--) if (world[widx(x, y, z)]) return y;
  return 0;
}

// The test scene: flatten x,z in [44,84] to ground height 14 and build on it.
// Returns the list of [index, value] edits so a harness can write them into the game's memory.
export function buildScene(world) {
  const edits = new Map();
  const set = (x, y, z, b) => { const i = widx(x, y, z); if (world[i] !== b) { world[i] = b; edits.set(i, b); } };
  for (let x = 44; x <= 84; x++) for (let z = 44; z <= 84; z++) for (let y = 0; y < WY; y++)
    set(x, y, z, y < 11 ? 3 : y < 13 ? 2 : y < 14 ? 1 : 0);
  for (let x = 56; x <= 72; x++) for (let y = 14; y <= 18; y++) set(x, y, 70, 3);        // wall, 5 high, z=70
  for (let x = 74; x <= 80; x++) for (let y = 14; y <= 33; y++) set(x, y, 56, 3);        // cliff, 20 high, z=56
  for (let x = 46; x <= 50; x++) for (let z = 76; z <= 80; z++) set(x, 16, z, 4);        // floating ceiling at y=16
  for (let y = 14; y <= 20; y++) set(60, y, 60, 5);                                       // a thin pillar
  return [...edits.entries()];
}

// Camera poses (eye position, yaw, pitch). The ground of the scene is y=14, so a standing eye is 15.62.
export function poses(world) {
  const P = [], add = (name, x, y, z, yaw, pitch) => P.push({ name, x, y, z, yaw, pitch });
  const hx = (x, z) => colTop(world, x, z) + 1;
  add('spawn', 64.5, hx(64, 64) + EYE, 64.5, 0.7, -0.06);
  add('eye-in-ceiling-up', 48.5, 16.05, 78.5, 0.3, 1.3);
  add('eye-in-ceiling-flat', 48.5, 16.05, 78.5, 0.3, 0.0);
  add('eye-in-ground', 64.5, 13.5, 64.5, 0.7, 0.0);
  add('under-ceiling-up', 48.5, 15.8, 78.5, 0.3, 1.3);
  add('wall-0.25', 64.5, 15.62, 69.75, 0.0, 0.0);
  add('wall-0.3', 64.5, 15.62, 69.7, 0.0, 0.0);
  add('wall-0.3-40deg', 64.5, 15.62, 69.7, 0.698, 0.0);
  add('wall-0.6-40deg', 64.5, 15.62, 69.4, 0.698, 0.0);
  add('wall-0.3-down', 64.5, 15.62, 69.7, 0.3, -1.2);
  add('wall-0.3-up', 64.5, 15.62, 69.7, -0.3, 1.2);
  add('cliff-0.7', 77.5, 15.62, 55.3, 0.0, 0.0);
  add('cliff-0.7-up', 77.5, 15.62, 55.3, 0.0, 0.9);
  add('cliff-0.3-along-up', 77.5, 15.62, 55.7, Math.PI / 2, 1.2);
  add('cliff-0.3-along-down', 77.5, 15.62, 55.7, Math.PI / 2, -1.2);
  add('cliff-top-down', 77.5, 35.62, 56.5, 0.0, -1.3);
  add('pillar-0.3', 60.5, 15.62, 59.7, 0.0, 0.2);
  const e = hx(0, 64);
  add('edge-out', 0.3, e + EYE, 64.5, -Math.PI / 2, -0.3);
  add('edge-in', 0.3, e + EYE, 64.5, Math.PI / 2, -0.3);
  add('edge-along-down', 0.3, e + EYE, 64.5, 0.0, -1.2);
  add('corner-out', 0.3, hx(0, 0) + EYE, 0.3, -2.356, -0.4);
  add('corner-in', 0.3, hx(0, 0) + EYE, 0.3, 0.785, -0.4);
  add('above-40.5', 64.5, 40.5, 64.5, 0.7, -0.8);
  add('above-41.5', 64.5, 41.5, 64.5, 0.7, -1.0);
  add('above-41.5-flat', 64.5, 41.5, 64.5, 0.7, 0.0);
  add('above-45', 64.5, 45.0, 64.5, 0.7, -0.6);
  add('fly18-pitch-1.40', 64.5, 14 + 18, 64.5, 0.7, -1.40);
  add('fly18-pitch-1.0', 64.5, 14 + 18, 64.5, 0.7, -1.0);
  const rnd = mulberry(6), solidAt = (x, y, z) => x < 0 || z < 0 || x >= WX || z >= WZ || y < 0 ? 1 : y >= WY ? 0 : world[widx(x, y, z)];
  const boxFree = (x, y, z) => {
    for (let j = Math.floor(y - EYE); j <= Math.floor(y + 0.2); j++) for (let k = Math.floor(z - 0.3); k <= Math.floor(z + 0.3); k++)
      for (let i = Math.floor(x - 0.3); i <= Math.floor(x + 0.3); i++) if (solidAt(i, j, k)) return false;
    return true;
  };
  let n = 0;
  for (let tries = 0; n < 20 && tries < 100000; tries++) {
    const x = 1 + rnd() * (WX - 2), z = 1 + rnd() * (WZ - 2), y = hx(Math.floor(x), Math.floor(z)) + EYE + rnd() * 6;
    if (y + 0.2 >= WY || !boxFree(x, y, z)) continue;
    add('open-' + n, x, y, z, rnd() * 2 * Math.PI, (rnd() * 2 - 1) * 1.45); n++;
  }
  return P;
}

export function basis(yaw, pitch) {
  const cp = Math.cos(pitch), sp = Math.sin(pitch), cy = Math.cos(yaw), sy = Math.sin(yaw);
  return { fw: [sy * cp, sp, cy * cp], rg: [cy, 0, -sy], up: [-sy * sp, cp, -cy * sp] };
}

// First solid cell along the ray (unit direction d) from o, out to tmax. Faces as HolyCraft numbers
// them (0=-X 1=+X 2=-Y 3=+Y 4=-Z 5=+Z, the face the ray enters through); a start cell that is solid
// is a hit at t=0 with face 2 looking up, else 3. Returns null for sky.
export function trace(world, o, d, tmax) {
  const size = [WX, WY, WZ];
  let t0 = 0, t1 = tmax, axis0 = -1;
  for (let a = 0; a < 3; a++) {
    if (d[a] === 0) { if (o[a] < 0 || o[a] >= size[a]) return null; continue; }
    let ta = (0 - o[a]) / d[a], tb = (size[a] - o[a]) / d[a];
    if (ta > tb) [ta, tb] = [tb, ta];
    if (ta > t0) { t0 = ta; axis0 = a; }
    if (tb < t1) t1 = tb;
  }
  if (t0 > t1) return null;
  const st = d.map((v) => (v > 0 ? 1 : v < 0 ? -1 : 0));
  const cell = [0, 0, 0];
  for (let a = 0; a < 3; a++) {
    let c = Math.floor(o[a] + d[a] * t0);
    if (a === axis0) c = st[a] > 0 ? 0 : size[a] - 1;
    cell[a] = Math.min(size[a] - 1, Math.max(0, c));
  }
  const faceOf = (a) => a * 2 + (st[a] > 0 ? 0 : 1);
  let t = t0, face = axis0 < 0 ? (st[1] > 0 ? 2 : 3) : faceOf(axis0);
  for (let guard = 0; guard < 1000; guard++) {
    const b = world[widx(cell[0], cell[1], cell[2])];
    if (b) return { t, bt: b, face, code: CODE0 + b * 6 + face };
    let best = Infinity, ba = -1;
    for (let a = 0; a < 3; a++) {
      if (!st[a]) continue;
      const tn = ((st[a] > 0 ? cell[a] + 1 : cell[a]) - o[a]) / d[a];
      if (tn < best) { best = tn; ba = a; }
    }
    if (ba < 0 || best > t1 || best > tmax) return null;
    cell[ba] += st[ba]; t = best; face = faceOf(ba);
    if (cell[ba] < 0 || cell[ba] >= size[ba]) return null;
  }
  return null;
}

// The ray through screen point sx,sy (pixel centers at x+0.5) of a W by H view from pose p.
export function rayAt(p, W, H, sx, sy) {
  const { fw, rg, up } = basis(p.yaw, p.pitch), focal = (H / 2) / 1.05;
  const a = (sx - W / 2) / focal, b = (H / 2 - sy) / focal;
  const d = [fw[0] + rg[0] * a + up[0] * b, fw[1] + up[1] * b, fw[2] + rg[2] * a + up[2] * b];
  const ln = Math.hypot(d[0], d[1], d[2]);
  return d.map((v) => v / ln);
}

// The exact image of pose p: the hit of the ray through each pixel's center, with its forward depth.
export function refFrame(world, p, W, H) {
  const { fw } = basis(p.yaw, p.pitch), out = new Array(W * H);
  for (let sy = 0; sy < H; sy++) for (let sx = 0; sx < W; sx++) {
    const d = rayAt(p, W, H, sx + 0.5, sy + 0.5), h = trace(world, [p.x, p.y, p.z], d, 64);
    if (h) h.fd = h.t * (d[0] * fw[0] + d[1] * fw[1] + d[2] * fw[2]);
    out[sy * W + sx] = h;
  }
  return out;
}

// Does the exact image show face code g anywhere within 1.5 pixels of pixel x,y? 7 by 7 rays.
export function seenNear(world, p, W, H, x, y, g) {
  for (let j = -3; j <= 3; j++) for (let i = -3; i <= 3; i++) {
    const h = trace(world, [p.x, p.y, p.z], rayAt(p, W, H, x + 0.5 + i / 2, y + 0.5 + j / 2), 64);
    if (h && h.code === g) return true;
  }
  return false;
}

// Compare one rendered frame (codes, and optionally the forward depth of each pixel) with the
// exact image. hard: distance below which a block must show; beyond it, it may fade to sky.
// A pixel whose reference differs from a 4-neighbor's (code, or a jump in distance) is an edge.
// Bad is what the eye must never see where a block nearer than hard is:
//   sky   sky, away from an edge;
//   far   a face behind the true one (needs the depth), away from an edge;
//   crack at an edge, sky or a face behind everything the exact image shows in the 3x3;
//   wrong another face, not behind the true one, that the exact image shows nowhere within 1.5
//         pixels (a face that is not there; seen(x, y, g) answers that, or the 3x3 without it).
// Counted, not bad: over (a nearer face over an edge or a sliver it really has), deep (the true
// face with its depth too deep), edge (an edge pixel showing what is beyond the edge).
export function classify(W, H, ref, got, hard, gotFd, labels, seen) {
  const r = { sky: 0, far: 0, wrong: 0, crack: 0, over: 0, deep: 0, edge: 0, ok: 0, fogged: 0, total: W * H };
  const isSky = (g) => g >= SKY0 && g < SKY0 + 8;
  const in3 = (i, x, y, f) => {
    for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++)
      if (x + dx >= 0 && x + dx < W && y + dy >= 0 && y + dy < H && f(ref[i + dy * W + dx])) return true;
    return false;
  };
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const i = y * W + x, a = ref[i], g = got[i];
    if (!a || a.t >= hard) { if (isSky(g) || (a && g === a.code)) r.ok++; else r.fogged++; continue; }
    let edge = false;
    for (const j of [i - 1, i + 1, i - W, i + W]) {
      if (j < 0 || j >= W * H || (j === i - 1 && x === 0) || (j === i + 1 && x === W - 1)) continue;
      const b = ref[j];
      if (!b || b.code !== a.code || Math.abs(b.t - a.t) > 0.02 * a.t + 0.05) { edge = true; break; }
    }
    const depth = isSky(g) ? Infinity : gotFd ? gotFd[i] : null, behind = (f) => depth > f * 1.02 + 0.02;
    let c;
    if (g === a.code && !isSky(g)) c = depth !== null && behind(a.fd) ? 'deep' : 'ok';
    else if (depth === null) c = !edge ? 'wrong' : in3(i, x, y, (b) => b && b.code === g) ? 'edge' : 'crack';
    else if (!behind(a.fd)) c = edge || (seen ? seen(x, y, g) : in3(i, x, y, (b) => b && b.code === g)) ? 'over' : 'wrong';
    else if (!edge) c = isSky(g) ? 'sky' : 'far';
    else c = in3(i, x, y, (b) => !b || b.t >= hard || !behind(b.fd)) ? 'edge' : 'crack';
    r[c]++;
    if (labels) labels[i] = c;
  }
  r.bad = r.sky + r.far + r.wrong + r.crack;
  return r;
}
