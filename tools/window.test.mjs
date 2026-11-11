import assert from 'node:assert/strict';
import {loadGame} from './game.mjs';

const g=await loadGame(['Init','HandleInput','DrawHUD','CleanUp']);
assert(g,'Set HOLYC_WASM to a HolyC-wasm checkout.');
const cases=[[640,480],[319,199],[641,481],[52,200],[1,1],[0,0],[640,16]];
const base=g.ex.memory.buffer.byteLength;
g.ex.memory.grow(8);
for(const [w,h] of cases){
  const stride=((w+7)&~7)+8, length=stride*h, start=base+64;
  const bytes=g.u8();
  bytes.fill(0xA5,base,start+length+64);
  g.ex.DrawHUD(BigInt(start),BigInt(w),BigInt(h),BigInt(stride));
  assert(bytes.subarray(base,start).every(v=>v===0xA5),`${w}x${h}: wrote before view`);
  assert(bytes.subarray(start+length,start+length+64).every(v=>v===0xA5),`${w}x${h}: wrote after view`);
  for(let y=0;y<h;y++)
    assert(bytes.subarray(start+y*stride+w,start+(y+1)*stride).every(v=>v===0xA5),`${w}x${h}: overwrote row padding`);
  if(w>100&&h>100)
    assert.equal(bytes[start+(Math.floor(h/2)-1)*stride+Math.floor(w/2)-1],15,'missing aiming cross');
}
g.setI64('g_quit',1);g.setI64('g_sel',23);g.setI64('g_plb',1);g.setI64('g_prb',1);
g.ex.CleanUp();
for(const name of ['g_world','g_hm','g_lo','g_fb'])assert.equal(g.ptr(name),0,`${name} retained after cleanup`);
g.ex.Init();
assert.equal(g.i64('g_quit'),0,'new game immediately quits');
assert.equal(g.i64('g_sel'),8,'new game retains the old block selection');
assert.equal(g.i64('g_plb')|g.i64('g_prb'),0,'new game retains old mouse buttons');
console.log(`HolyCraft window: ${cases.length} guarded HUD sizes and restart passed`);
