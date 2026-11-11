// Compile with TempleOS V5.03 in HEMU and compare visible faces with exact rays.
// TEMPLEOS_WEB=/path/to/TempleOS-Web node tools/render/tos.mjs [check|time|windows]
// HLE=0 exercises the guest raster routines. See README.md for scope and options.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { WX, WZ, WY, CODE0, SKY0, buildScene, poses, refFrame, seenNear, classify, colTop } from './ref.mjs';

assert(process.env.TEMPLEOS_WEB, 'Set TEMPLEOS_WEB to a TempleOS-Web checkout with built HEMU dependencies.');
const site = resolve(process.env.TEMPLEOS_WEB), moduleAt = path => import(pathToFileURL(resolve(site, path)));
const { compileHemu, hemuFile } = await moduleAt('engine/compile.js');
const { createHemuHost } = await moduleAt('engine/host.js');
const jit = await moduleAt('engine/jit.js');
const { createGuestExec } = await moduleAt('engine/guestexec.js');
const { SnapshotRead, DiskRead } = await moduleAt('tools/hemu/Fixtures.mjs');
const SRC = process.env.SRC || fileURLToPath(new URL('../../HolyCraft.HC', import.meta.url));
const mode = process.argv[2] || 'check';
assert(['check', 'time', 'windows'].includes(mode), 'Usage: tos.mjs [check|time|windows]');
const RAMSZ = 402653184, W = 640, H = 480, NEAR = 0.05, ZFAR = 2**30;
const liveBuf = SnapshotRead(), disk = DiskRead();
const r = compileHemu({ source: hemuFile('snapshot.HC') });
const mod = await WebAssembly.compile(r.bytes);
let gBase = 0, inst, budget = Number(process.env.BUDGET || 12000000), dtMs = 16, presents = 0;
const ovl = new Map(), badops = [];
const host = createHemuHost({ onText: (s) => { if (s && s.indexOf('BADOP') >= 0) badops.push(s.trim()); if (process.env.TEXT) process.stdout.write(s); }, snd: { tone: () => {} },
  snapLoad: (base, u8) => { gBase = base; u8.set(liveBuf.subarray(0, RAMSZ), base); },
  diskRead: (lba, cnt, u8, dst) => { for (let s = 0; s < cnt; s++) { const o = ovl.get(lba + s); if (o) u8.set(o, dst + s * 512); else disk.readInto(lba + s, 1, u8, dst + s * 512); } },
  diskWrite: (lba, cnt, u8, src) => { for (let s = 0; s < cnt; s++) ovl.set(lba + s, u8.slice(src + s * 512, src + s * 512 + 512)); },
  present: () => { presents++; } });
host.env.__host_msx = () => 320n; host.env.__host_msy = () => 240n; host.env.__host_msb = () => 0n; host.env.__host_wheel = () => 0n;
host.env.__host_key = () => -1n; host.env.__host_time = () => 0n;
host.env.__host_budget = () => BigInt(budget | 0); host.env.__host_dt = () => BigInt(dtMs | 0);
host.env.__jit_state = (rg, fl, rp) => { jit.jitState(rg, fl, rp, gBase, inst.exports.memory, inst.exports.RdMem, inst.exports.WrMem, inst.exports.RasterHLE); return 1n; };
host.env.__jit_compile = (rip) => BigInt(jit.jitCompile(Number(rip)));
host.env.__jit_run = (rip) => BigInt(jit.jitRun(Number(rip)));
host.env.__jit_x87 = (a, b, c) => jit.jitX87(a, b, c);
host.env.__jit_dispatch = (b) => BigInt(jit.jitDispatch(Number(b)));
host.env.__jit_chain = (a, b) => jit.jitChain(a, b); host.env.__jit_seg = (...a) => jit.jitSeg(...a.map(Number));
jit.jitReset();
inst = await WebAssembly.instantiate(mod, { env: host.env }); host.attach(inst); inst.exports.__rt_init();
const dv = () => new DataView(inst.exports.memory.buffer), u8 = () => new Uint8Array(inst.exports.memory.buffer);
const hemuVar = (n) => Number(r.globals.get(n).addr);

let gx = null;
async function run(n) { for (let i = 0; i < n; i++) { inst.exports.__main(); if (gx) gx.tick(); if (i % 8 === 7) await new Promise((ok) => setImmediate(ok)); } }
async function until(pred, maxFrames, step = 2) { for (let f = 0; f < maxFrames; f += step) { if (pred()) return true; await run(step); } return pred(); }
const finalStates = ['done', 'failed', 'error'];
const waitState = (id, states, maxFrames) => until(() => { const s = gx.status(id); return s && states.includes(s.state); }, maxFrames);

await run(300);
gx = createGuestExec({ inst, gBase, log: () => {} });
const probe = gx.probe();
if (!probe.ok) { console.log('probe failed', probe.errors); process.exit(1); }

async function launch(src) {
  const id = gx.launch({ src, name: 'HolyCraft' });
  await waitState(id, ['running', 'failed', 'error'], 1200);
  if (gx.status(id).state !== 'running') throw new Error('launch: ' + JSON.stringify(gx.status(id)));
  return id;
}
async function globals(id, names) {
  const task = Number.parseInt(gx.status(id).task, 16), slot = gx.scratch.base + 0xb00;
  const query = names.map((name, i) => `*(${slot + i * 8})(I64*)=HashFind("${name}",${task}(CTask*)->hash_table,HTT_GLBL_VAR)(CHashGlblVar*)->data_addr;`).join('');
  const req = gx.exec({ src: query, target: 'adam' }); await waitState(req, finalStates, 600);
  if (gx.status(req).state !== 'done') throw new Error('lookup: ' + JSON.stringify(gx.status(req)));
  const out = {}; names.forEach((n, i) => { out[n] = gx.rd64(slot + i * 8); if (!out[n]) throw new Error('no global ' + n); });
  return out;
}
const rdPtr = (a) => Number(dv().getBigUint64(gBase + a, true));
const wrF = (a, v) => dv().setFloat64(gBase + a, v, true);
const wrI = (a, v) => dv().setBigInt64(gBase + a, BigInt(v), true);
const rdI = (a) => Number(dv().getBigInt64(gBase + a, true));

function depthCheck(name, expected, pixels, depth, hard) {
  let count=0,low=0,high=0;
  for(let i=0;i<expected.length;i++) {
    const hit=expected[i];
    if(!hit||hit.t>=hard||hit.fd<NEAR||pixels[i]!==hit.code)continue;
    const error=depth[i]-ZFAR*(1-NEAR/hit.fd);
    // Endpoint truncation and interpolation flooring lose up to two units.
    // At 640 pixels, 32.32 slope quantization adds <639/2^32 unit; the margin
    // covers that and floating-point plane setup in these tested views.
    assert(error>=-2.0001&&error<=0.0001,
      `${name} at ${i%W},${Math.floor(i/W)}: integer depth error ${error}`);
    low=Math.min(low,error);high=Math.max(high,error);count++;
  }
  return {count,low,high};
}

if (['check', 'time', 'windows'].includes(mode)) {
  const text = readFileSync(SRC, 'latin1'), tosPart = (text.split('#ifdef TOS_NATIVE')[1] || '').split('#else')[0];
  const def = (n, d) => Number((tosPart.match(new RegExp('#define ' + n + '\\s+([0-9.]+)')) || [0, d])[1]);
  const rdist = def('RDIST', 32), hard = def('FOG0', rdist - 8) - 0.87;   // fog goes by a cell's center, up to 0.87 behind its faces
  const rebuild = text.includes('SkyRowsMake');   // the new code keeps g_lo and sky rows, made in the guest
  console.log(`RDIST ${rdist}, exact below ${hard}, rebuild in guest ${rebuild}`);
  const driver = `
I64 c1_req=0,c1_done=0,c1_n=1,c1_i,c1_rebuild=0,c1_w=${W},c1_h=${H},c1_stride;
F64 c1_pose[5];
CDC *c1_dc=NULL,*c1_ref=NULL;
CTask *c1_task=NULL;
U8 *c1_body=NULL,*c1_expected=NULL;
U0 C1Test()
{
  Init;
  c1_dc=DCNew(${W},${H});
  c1_body=c1_dc->body;
  c1_task=CAlloc(sizeof(CTask));
  while (TRUE) {
    if (c1_rebuild) {
      ${rebuild ? 'BuildHM;SkyRowsMake;' : ''}
      c1_rebuild=0;
    }
    if (c1_req!=c1_done) {
      g_px=c1_pose[0];g_py=c1_pose[1];g_pz=c1_pose[2];
      g_yaw=c1_pose[3];g_pitch=c1_pose[4];
      ${mode==='windows' ? `
      DCDel(c1_dc);DCDel(c1_ref);
      c1_dc=DCNew(c1_w,c1_h);c1_ref=DCNew(c1_w,c1_h);
      c1_task->pix_width=c1_w;c1_task->pix_height=c1_h;
      DrawIt(c1_task,c1_dc);
      RenderFaces(c1_ref);
      DrawHUD(c1_ref->body,c1_w,c1_h,c1_ref->width_internal);
      c1_body=c1_dc->body;c1_expected=c1_ref->body;
      c1_stride=c1_dc->width_internal;
      ` : `for (c1_i=0;c1_i<c1_n;c1_i++) RenderFaces(c1_dc);`}

      c1_done=c1_req;
    }
    Sleep(1);
  }
}
C1Test;
`;
  const src = '#define TOS_NATIVE 1\n' + readFileSync(SRC, 'latin1').replace(/HolyCraft;\s*$/, '') + driver;
  const id = await launch(src);
  await run(200);
  const G = await globals(id, ['c1_w','c1_h','c1_stride','c1_expected','c1_req', 'c1_done', 'c1_n', 'c1_pose', 'c1_dc', 'c1_body', 'c1_rebuild', 'g_world', 'g_hm', 'g_flo', 'g_fhi', 'g_skyr', 'g_depth']);
  await until(() => rdPtr(G.c1_dc), 400);
  const wp = rdPtr(G.g_world), world = u8().slice(gBase + wp, gBase + wp + WX * WZ * WY);
  if (mode !== 'time') for (const [i, b] of buildScene(world)) u8()[gBase + wp + i] = b;
  const hm = rdPtr(G.g_hm);
  for (let x = 0; x < WX; x++) for (let z = 0; z < WZ; z++) u8()[gBase + hm + x + WX * z] = colTop(world, x, z);
  if (mode !== 'time') {
    for (let k = 0; k < 24 * 6; k++) { u8()[gBase + G.g_flo + k] = CODE0 + k; u8()[gBase + G.g_fhi + k] = CODE0 + k; }
    for (let k = 0; k < 3; k++) u8()[gBase + G.g_skyr + k] = SKY0 + (mode === 'windows' ? 0 : k);
  }
  wrI(G.c1_rebuild, 1);
  if (!(await until(() => !rdI(G.c1_rebuild), 4000, 1))) throw new Error('rebuild timed out');
  if (process.env.HLE === '0') {
    for (const name of ['g_poly3_hle', 'g_raster_n']) wrI(hemuVar(name) - gBase, 0);
  }
  const calls0 = rdI(hemuVar('g_raster_calls') - gBase);
  const dcBody = rdPtr(G.c1_body);
  if (mode === 'windows') {
    let request=0;
    for (const [w,h] of [[640,480],[319,199],[641,481],[52,200],[1,1],[640,16],[320,200]]) {
      wrI(G.c1_w,w);wrI(G.c1_h,h);wrI(G.c1_req,++request);
      assert(await until(()=>rdI(G.c1_done)===request,4000,1), 'Window draw timed out.');
      const actual=rdPtr(G.c1_body),expected=rdPtr(G.c1_expected),stride=rdI(G.c1_stride);
      for (let y=0;y<h;y++)
        assert.deepEqual(u8().subarray(gBase+actual+y*stride,gBase+actual+y*stride+w),
          u8().subarray(gBase+expected+y*stride,gBase+expected+y*stride+w),`${w}x${h} row ${y}: window blit differs`);
    }
    assert.equal(badops.length,0,'HEMU encountered unsupported instructions.');
    console.log('Native DrawIt: 7 sizes, growth/shrink and padded DC blits passed.');
    process.exit(0);
  }
  const KEYS = ['sky', 'far', 'wrong', 'crack', 'over', 'deep', 'edge'], tot = { bad: 0, framesBad: 0 }, lines = [], depths={count:0,low:0,high:0};
  for (const k of KEYS) tot[k] = 0;
  let req = 0;
  if (mode === 'time') {
    const N = Number(process.env.N || 40), P = poses(world).filter((p) => p.name === 'spawn' || p.name.startsWith('open-')).slice(0, Number(process.env.VIEWS || 11));
    const per = []; let sum = 0;
    for (const p of P) {
      [p.x, p.y, p.z, p.yaw, p.pitch].forEach((v, i) => wrF(G.c1_pose + i * 8, v));
      wrI(G.c1_n, 1); wrI(G.c1_req, ++req); assert(await until(() => rdI(G.c1_done) === req, 4000, 1), 'Warmup timed out.');
      wrI(G.c1_n, N); const a = performance.now(), c0 = rdI(hemuVar('g_raster_calls') - gBase);
      wrI(G.c1_req, ++req); assert(await until(() => rdI(G.c1_done) === req, 40000, 1), 'Benchmark timed out.');
      const ms = (performance.now() - a) / N; sum += ms;
      per.push(`${p.name}:${ms.toFixed(2)}ms/${((rdI(hemuVar('g_raster_calls') - gBase) - c0) / N) | 0}spans`);
    }
    console.log(per.join(' '));
    console.log(`MEAN ${(sum / P.length).toFixed(2)} ms host time per RenderFaces over ${P.length} views x ${N} (budget ${budget / 1e6}M/frame)`);
    process.exit(0);
  }
  const solidEye = (p) => p.y < WY && world[Math.floor(p.x) + WX * (Math.floor(p.z) + WZ * Math.floor(p.y))];
  const selected = poses(world).filter(q => !solidEye(q) && (!process.env.POSE || q.name === process.env.POSE));
  assert(selected.length, 'No matching camera pose.');
  for (const p of selected) {
    [p.x, p.y, p.z, p.yaw, p.pitch].forEach((v, i) => wrF(G.c1_pose + i * 8, v));
    wrI(G.c1_req, ++req);
    if (!(await until(() => rdI(G.c1_done) === req, 4000, 1))) throw new Error('render timed out at ' + p.name);
    const got = u8().slice(gBase + dcBody, gBase + dcBody + W * H);
    const depth = rdPtr(G.g_depth);
    const zb = new Int32Array(u8().slice(gBase + depth, gBase + depth + W * H * 4).buffer), fd = new Float64Array(W * H);
    for (let i = 0; i < W * H; i++) fd[i] = zb[i] === 0x7FFFFFFF ? Infinity : NEAR / (1 - zb[i] / ZFAR);
    const expected=refFrame(world,p,W,H),zcheck=depthCheck(p.name,expected,got,zb,hard);
    depths.count+=zcheck.count;depths.low=Math.min(depths.low,zcheck.low);depths.high=Math.max(depths.high,zcheck.high);
    const res = classify(W, H, expected, got, hard, fd, null, (x, y, g) => seenNear(world, p, W, H, x, y, g));
    for (const k of KEYS) tot[k] += res[k];
    tot.bad += res.bad; if (res.bad) tot.framesBad++;
    lines.push(`${p.name.padEnd(22)} bad ${String(res.bad).padStart(6)} (sky ${res.sky}, far ${res.far}, wrong ${res.wrong}, crack ${res.crack})  over ${res.over} deep ${res.deep} edge ${res.edge}`);
    if (process.env.OUT) {
      mkdirSync(process.env.OUT, {recursive:true});
      writeFileSync(resolve(process.env.OUT, 'world.bin'), world);
      writeFileSync(resolve(process.env.OUT, p.name+'.bin'), got);
      writeFileSync(resolve(process.env.OUT, p.name+'-depth.bin'), Buffer.from(fd.buffer));
    }
  }
  console.log(lines.join('\n'));
  assert(depths.count>0,'No pre-fog surface depths were checked.');
  console.log(`Integer depth: ${depths.count} matching pre-fog pixels, error ${depths.low} to ${depths.high} units.`);
  console.log(`TOTAL bad ${tot.bad} (sky ${tot.sky}, far ${tot.far}, wrong ${tot.wrong}, crack ${tot.crack}) in ${tot.framesBad} of ${lines.length} frames; over ${tot.over}, deep ${tot.deep}, edge ${tot.edge}; span fast-path calls ${rdI(hemuVar('g_raster_calls') - gBase) - calls0}; BADOPs ${badops.length}`);
  if (process.env.HLE === '0') assert.equal(rdI(hemuVar('g_raster_calls') - gBase) - calls0, 0, 'Raster fast paths ran during native reference check.');
  assert.equal(badops.length, 0, 'HEMU encountered unsupported instructions.');
  assert.equal(tot.bad + tot.over + tot.deep + tot.edge, 0, 'Native faces or depth differ from exact rays before fog.');
}

