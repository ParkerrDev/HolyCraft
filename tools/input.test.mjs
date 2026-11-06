// HolyCraft's input in the browser build, through the real compiler path without the render loop:
// a still mouse leaves the camera still, one mouse move turns it once, a held key moves the player and
// letting go stops it at once. Needs HolyC-wasm (https://github.com/ParkerrDev/HolyC-wasm); it looks in
// $HOLYC_WASM, then beside this repository as HolyC-wasm or holyc-wasm, and skips if none is there.
//   node tools/input.test.mjs
import assert from 'node:assert/strict';
import {existsSync,readFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';

const here=new URL('..',import.meta.url);
const where=[process.env.HOLYC_WASM,new URL('../HolyC-wasm/',here).pathname,new URL('../holyc-wasm/',here).pathname]
  .filter(Boolean).find((d)=>existsSync(d+'/src/compiler.js'));
if(!where){console.log('HolyCraft input: skipped, HolyC-wasm not found (set HOLYC_WASM to its folder)');process.exit(0);}
const {compileHolyC}=await import(pathToFileURL(where+'/src/compiler.js'));
const {createHost}=await import(pathToFileURL(where+'/src/runtime/host.js'));

const source=readFileSync(new URL('HolyCraft.HC',here),'utf8').replace(/HolyCraft;\s*$/,'');
const result=compileHolyC(source,{lenient:true,resilient:true,exports:['Init','HandleInput']});
const host=createHost({scanChar:()=>0});
const instance=await WebAssembly.instantiate(result.bytes,{env:host.env});host.attach(instance.instance);
const ex=instance.instance.exports,dv=new DataView(ex.memory.buffer);
const addr=(name)=>Number(result.globals.get(name).addr);
const number=(name)=>dv.getFloat64(addr(name),true);
const state=()=>['g_pitch','g_yaw','g_px','g_pz'].map(number);
ex.__rt_init();ex.__main();ex.Init();
const initial=state();
for(let i=0;i<30;i++)ex.HandleInput();
assert.deepEqual(state(),initial,'A still mouse and no keys leave the camera where it is');
dv.setBigInt64(addr('BrowserMouseDX'),30n,true);dv.setBigInt64(addr('BrowserMouseDY'),15n,true);
ex.HandleInput();
const turned=state();
assert(turned[0]<initial[0]&&turned[1]>initial[1],'A mouse move turns and tilts the camera');
for(let i=0;i<30;i++)ex.HandleInput();
assert.deepEqual(state(),turned,'and only once');
dv.setUint8(addr('BrowserKeys')+0x20,1);
for(let i=0;i<10;i++)ex.HandleInput();
const moved=state();
assert(moved[2]!==turned[2]||moved[3]!==turned[3],'A held key moves the player');
dv.setUint8(addr('BrowserKeys')+0x20,0);
for(let i=0;i<30;i++)ex.HandleInput();
assert.deepEqual(state(),moved,'Letting go stops at once');
console.log(`HolyCraft input: ok (HolyC-wasm from ${where})`);
