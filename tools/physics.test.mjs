// HolyCraft's player in the browser build: it walks as far in a second at any frame rate, its box keeps
// the eye out of walls and ceilings and inside the world, and a block is not placed where it stands.
//   node tools/physics.test.mjs
import assert from 'node:assert/strict';
import {loadGame,SC,WY,EYE,PLAYER_R,PLAYER_TOP} from './game.mjs';

const g=await loadGame();
if(!g){console.log('HolyCraft physics: skipped, HolyC-wasm not found (set HOLYC_WASM to its folder)');process.exit(0);}
// Flat ground with its top at y=14, a wall along z=70 and a ceiling block layer at y=16.
for(let x=44;x<=84;x++)for(let z=44;z<=84;z++)for(let y=0;y<WY;y++)g.setBlock(x,y,z,y<14?3:0);
for(let x=56;x<=72;x++)for(let y=14;y<=18;y++)g.setBlock(x,y,70,3);
for(let x=46;x<=50;x++)for(let z=76;z<=80;z++)g.setBlock(x,16,z,4);
const ground=14+EYE;
const inAir=()=>{const [x,y,z]=g.eye();return !g.block(Math.floor(x),Math.floor(y),Math.floor(z));};

const walk=(frameMs)=>{
  g.place(50.5,ground,60.5,Math.PI/2,0);
  g.play(100,frameMs);
  const x0=g.f64('g_px');
  g.key(SC.w,true);g.play(1000,frameMs);g.key(SC.w,false);g.play(frameMs,frameMs);
  return g.f64('g_px')-x0;
};
const fast=walk(16),slow=walk(100);
assert(Math.abs(fast-4.8)<0.2,`walks 4.8 cells a second (${fast})`);
assert(Math.abs(fast-slow)<=0.081,`at 10 frames a second as at 60 (${slow} against ${fast})`);

for(const yaw of [0,0.7]){
  g.place(64.5,ground,68.5,yaw,0);
  g.key(SC.w,true);
  g.play(1500,16,()=>assert(g.f64('g_pz')<=70-PLAYER_R+1e-9&&inAir(),'A wall stops the box touching it'));
  g.key(SC.w,false);
  assert(g.f64('g_pz')>70-PLAYER_R-0.01,`and lets it come close (${g.f64('g_pz')})`);
}

g.place(48.5,ground,78.5,0,0);
g.play(100);
g.type(' ');
let top=0;
g.play(1000,16,()=>{top=Math.max(top,g.f64('g_py'));assert(g.f64('g_py')<=16-PLAYER_TOP+1e-9&&inAir(),'A jump stops at the ceiling');});
assert(top>ground&&Math.abs(g.f64('g_py')-ground)<1e-9,'and lands again');

for(let x=0;x<=12;x++)for(let z=60;z<=68;z++)for(let y=28;y<WY;y++)g.setBlock(x,y,z,0);
g.setI64('g_fly',1);
g.place(6.5,34,64.5,-Math.PI/2,0);
g.key(SC.w,true);g.play(2000);g.key(SC.w,false);
assert(g.f64('g_px')>=PLAYER_R-1e-9&&g.f64('g_px')<PLAYER_R+0.01,`The world's side stops the box (${g.f64('g_px')})`);
g.key(SC.r,true);g.play(2000);g.key(SC.r,false);
assert(g.f64('g_py')<=WY-PLAYER_TOP+1e-9&&g.f64('g_py')>WY-PLAYER_TOP-0.01,`and so does its top (${g.f64('g_py')})`);
g.setI64('g_fly',0);

const click=()=>{g.rightButton(true);g.play(16);g.rightButton(false);g.play(16);};
g.place(60.5,ground,60.5,0,-1.45);
g.play(100);
click();
assert.equal(g.block(60,14,60),0,'No block is placed in the player');
g.place(64.5,ground,67.5,0,0);
g.play(100);
click();
assert.equal(g.block(64,15,69),g.i64('g_sel'),'but one is placed in front of the player');
console.log(`HolyCraft physics: ok (HolyC-wasm from ${g.where})`);
