// The browser build of HolyCraft.HC for the tests: compiled by HolyC-wasm as the site compiles it, with
// a clock the test moves and the page's input globals. HolyC-wasm is looked for in $HOLYC_WASM, then
// beside this repository as HolyC-wasm or holyc-wasm; loadGame returns null when it is not there.
import {existsSync,readFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';

export const WX=128,WZ=128,WY=40,EYE=1.62,PLAYER_R=0.3,PLAYER_TOP=0.2;
export const SC={w:0x11,s:0x1F,a:0x1E,d:0x20,r:0x13,f:0x21};
const here=new URL('..',import.meta.url);
const MS_RB=64+16;   // HolyC-wasm keeps ms at 64; rb is its fifth I32

export function holycWasm(){
  return [process.env.HOLYC_WASM,new URL('../HolyC-wasm/',here).pathname,new URL('../holyc-wasm/',here).pathname]
    .filter(Boolean).find((d)=>existsSync(d+'/src/compiler.js'));
}

export async function loadGame(exports=['Init','HandleInput']){
  const where=holycWasm();
  if(!where)return null;
  const {compileHolyC}=await import(pathToFileURL(where+'/src/compiler.js'));
  const {createHost}=await import(pathToFileURL(where+'/src/runtime/host.js'));
  const source=readFileSync(process.env.SRC||new URL('HolyCraft.HC',here),'latin1').replace(/HolyCraft;\s*$/,'');
  const result=compileHolyC(source,{filename:'HolyCraft.HC',lenient:false,resilient:false,exports});
  if(result.diagnostics.length||result.warnings.length)throw new Error([...result.diagnostics,...result.warnings].join('\n'));
  const typed=[];
  let now=1000;
  const host=createHost({scanChar:()=>typed.length?typed[0]:0,getChar:()=>typed.shift()||0,timeMs:()=>now,onText:()=>{}});
  const {instance}=await WebAssembly.instantiate(result.bytes,{env:host.env});
  host.attach(instance);
  const ex=instance.exports;
  const dv=()=>new DataView(ex.memory.buffer),u8=()=>new Uint8Array(ex.memory.buffer);
  const addr=(name)=>{const g=result.globals.get(name);if(!g)throw new Error('no global '+name);return Number(g.addr);};
  const ptr=(name)=>Number(dv().getBigInt64(addr(name),true));
  const g={
    where,ex,addr,ptr,u8,
    f64:(name)=>dv().getFloat64(addr(name),true),
    setF64:(name,v)=>dv().setFloat64(addr(name),v,true),
    i64:(name)=>Number(dv().getBigInt64(addr(name),true)),
    setI64:(name,v)=>dv().setBigInt64(addr(name),BigInt(v),true),
    key:(sc,down)=>u8()[addr('BrowserKeys')+sc]=down?1:0,
    type:(ch)=>typed.push(ch.charCodeAt(0)),
    rightButton:(down)=>dv().setInt32(MS_RB,down?1:0,true),
    now:()=>now,
    // HandleInput once a frame for ms milliseconds of the clock, calling each(after every frame).
    play:(ms,frameMs=16,each)=>{for(let t=0;t<ms;t+=frameMs){now+=frameMs;ex.HandleInput();if(each)each();}},
    eye:()=>[g.f64('g_px'),g.f64('g_py'),g.f64('g_pz')],
    place:(x,y,z,yaw,pitch)=>{g.setF64('g_px',x);g.setF64('g_py',y);g.setF64('g_pz',z);g.setF64('g_yaw',yaw);g.setF64('g_pitch',pitch);g.setF64('g_vy',0);},
    block:(x,y,z)=>u8()[ptr('g_world')+x+WX*(z+WZ*y)],
    setBlock:(x,y,z,b)=>{u8()[ptr('g_world')+x+WX*(z+WZ*y)]=b;},
  };
  ex.__rt_init();ex.__main();ex.Init();
  return g;
}
