// HolyCraft's input in the browser build, without the render loop: a still mouse leaves the camera
// still, one mouse move turns it once, a held key moves the player and letting go stops it at once.
//   node tools/input.test.mjs
import assert from 'node:assert/strict';
import {loadGame,SC} from './game.mjs';

const g=await loadGame();
if(!g){console.log('HolyCraft input: skipped, HolyC-wasm not found (set HOLYC_WASM to its folder)');process.exit(0);}
const state=()=>['g_pitch','g_yaw','g_px','g_pz'].map(g.f64);
g.play(500);
const initial=state();
g.play(500);
assert.deepEqual(state(),initial,'A still mouse and no keys leave the camera where it is');
g.setI64('BrowserMouseDX',30);g.setI64('BrowserMouseDY',15);
g.play(16);
const turned=state();
assert(turned[0]<initial[0]&&turned[1]>initial[1],'A mouse move turns and tilts the camera');
g.play(500);
assert.deepEqual(state(),turned,'and only once');
g.key(SC.d,true);
g.play(160);
const moved=state();
assert(moved[2]!==turned[2]||moved[3]!==turned[3],'A held key moves the player');
g.key(SC.d,false);
g.play(500);
assert.deepEqual(state(),moved,'Letting go stops at once');
console.log(`HolyCraft input: ok (HolyC-wasm from ${g.where})`);
