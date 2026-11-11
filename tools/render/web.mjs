// The browser build of HolyCraft, compiled as the site compiles it (HolyC-wasm, strict), run in node:
//   SRC=path/HolyCraft.HC node web.mjs check   48 deterministic poses against the exact reference rays
//   SRC=path/HolyCraft.HC node web.mjs bench   ms per RenderFrame at fixed views
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { holycWasm } from '../game.mjs';
import { WX, WZ, WY, CODE0, SKY0, buildScene, poses, basis, trace, classify, colTop } from './ref.mjs';
const HCW = holycWasm();
assert(HCW, 'Set HOLYC_WASM to a HolyC-wasm checkout.');
const { compileHolyC } = await import(HCW + '/src/compiler.js');
const { createHost } = await import(HCW + '/src/runtime/host.js');
const SRC = process.env.SRC || fileURLToPath(new URL('../../HolyCraft.HC', import.meta.url));
const mode = process.argv[2] || 'check';
assert(['check', 'bench'].includes(mode), 'Usage: web.mjs [check|bench]');
const W = 640, H = 480, FOV = 1.05;

async function load() {
  const source = readFileSync(SRC, 'latin1').replace(/HolyCraft;\s*$/, '');
  const res = compileHolyC(source, { filename: 'HolyCraft.HC', lenient: false, resilient: false, exports: ['Init', 'RenderFrame', 'HandleInput'] });
  if (res.diagnostics.length || res.warnings.length) throw new Error([...res.diagnostics, ...res.warnings].join('\n'));
  let now = 0;
  const host = createHost({ scanChar: () => 0, timeMs: () => now, onText: () => {} });
  const { instance } = await WebAssembly.instantiate(res.bytes, { env: host.env });
  host.attach(instance);
  const ex = instance.exports;
  ex.__rt_init(); ex.__main(); ex.Init();
  const has = (n) => res.globals.has(n);
  const addr = (n) => { const g = res.globals.get(n); if (!g) throw new Error('no global ' + n); return Number(g.addr); };
  const dv = () => new DataView(ex.memory.buffer), u8 = () => new Uint8Array(ex.memory.buffer);
  const ptr = (n) => Number(dv().getBigInt64(addr(n), true));
  const setF = (n, v) => dv().setFloat64(addr(n), v, true);
  const setI = (n, v) => dv().setBigInt64(addr(n), BigInt(v), true);
  return { ex, has, addr, dv, u8, ptr, setF, setI, clock: (ms) => { now = ms; } };
}

function pose(g, p) {
  g.setF('g_px', p.x); g.setF('g_py', p.y); g.setF('g_pz', p.z); g.setF('g_yaw', p.yaw); g.setF('g_pitch', p.pitch);
}

function refFrame(world, p, rdist) {
  const { fw, rg, up } = basis(p.yaw, p.pitch), asp = W / H, out = new Array(W * H);
  for (let sy = 0; sy < H; sy++) {
    const vy = (1 - 2 * sy / H) * FOV;
    for (let sx = 0; sx < W; sx++) {
      const cx = -asp * FOV + sx * (2 / W * asp * FOV);
      let d = [fw[0] + up[0] * vy + rg[0] * cx, fw[1] + up[1] * vy, fw[2] + up[2] * vy + rg[2] * cx];
      const ln = Math.hypot(d[0], d[1], d[2]); d = d.map((v) => v / ln);
      const h = trace(world, [p.x, p.y, p.z], d, rdist);
      if (h) h.fd = h.t * (d[0] * fw[0] + d[1] * fw[1] + d[2] * fw[2]);
      out[sy * W + sx] = h;
    }
  }
  return out;
}

if (mode === 'check') {
  const g = await load();
  const wp = g.ptr('g_world'), world = g.u8().slice(wp, wp + WX * WZ * WY);
  for (const [i, b] of buildScene(world)) g.u8()[wp + i] = b;
  const hm = g.ptr('g_hm');
  for (let x = 0; x < WX; x++) for (let z = 0; z < WZ; z++) g.u8()[hm + x + WX * z] = colTop(world, x, z);
  for (let k = 0; k < 24 * 6; k++) { g.u8()[g.addr('g_flo') + k] = CODE0 + k; g.u8()[g.addr('g_fhi') + k] = CODE0 + k; }
  for (let k = 0; k < 3; k++) g.u8()[g.addr('g_skyr') + k] = SKY0 + k;
  const src = readFileSync(SRC, 'latin1').split('#else')[1] || '', def = (n, d) => Number((src.match(new RegExp('#define ' + n + '\\s+([0-9.]+)')) || [0, d])[1]);
  const rdist = def('RDIST', 48), hard = def('FOG0', rdist - 8), tot = { sky: 0, wrong: 0, crack: 0, edge: 0, bad: 0, framesBad: 0 };
  const lines = [];
  console.log(`RDIST ${rdist}, exact below ${hard}`);
  for (const p of poses(world)) {
    pose(g, p); g.ex.RenderFrame();
    const fb = g.ptr('g_fb'), got = g.u8().slice(fb, fb + W * H);
    const r = classify(W, H, refFrame(world, p, rdist), got, hard);
    tot.sky += r.sky; tot.wrong += r.wrong; tot.crack += r.crack; tot.edge += r.edge; tot.bad += r.bad; if (r.bad) tot.framesBad++;
    lines.push(`${p.name.padEnd(22)} bad ${String(r.bad).padStart(6)} (sky ${r.sky}, wrong ${r.wrong}, crack ${r.crack})  edge ${r.edge}  beyond ${r.fogged}`);
  }
  console.log(lines.join('\n'));
  console.log(`TOTAL bad ${tot.bad} (sky ${tot.sky}, wrong ${tot.wrong}, crack ${tot.crack}) in ${tot.framesBad} of ${lines.length} frames; edge ${tot.edge}`);
  assert.equal(tot.bad + tot.edge, 0, 'Browser faces differ from exact rays before fog.');
}

if (mode === 'bench') {
  const g = await load();
  const wp = g.ptr('g_world'), world = g.u8().slice(wp, wp + WX * WZ * WY);
  const P = poses(world).filter((p) => p.name === 'spawn' || p.name.startsWith('open-')).slice(0, 11);
  const N = Number(process.env.N || 20), per = [];
  for (let rep = 0; rep < 2; rep++) for (const p of P) { pose(g, p); g.ex.RenderFrame(); }   // warm the JIT
  let total = 0;
  for (const p of P) {
    pose(g, p);
    const t0 = performance.now();
    for (let i = 0; i < N; i++) g.ex.RenderFrame();
    const ms = (performance.now() - t0) / N; total += ms; per.push(`${p.name}:${ms.toFixed(2)}`);
  }
  console.log(per.join(' '));
  console.log(`MEAN ${(total / P.length).toFixed(2)} ms per RenderFrame over ${P.length} views x ${N}`);
}
