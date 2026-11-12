import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';
import {resolve} from 'node:path';
import {holycWasm} from './game.mjs';

const backend=process.env.BACKEND||'qemu',startup=process.env.STARTUP!=='0';
assert(['qemu','hemu','wasm'].includes(backend));
const input=process.env.SRC||new URL('../HolyCraft.HC',import.meta.url),
  before=readFileSync(new URL('./Lifetime.HC',import.meta.url),'latin1'),
  after=readFileSync(new URL(backend==='wasm'?'./LifetimeWeb.HC':'./LifetimeProbe.HC',import.meta.url),'latin1').replace(
    /LifetimeProbe;\s*$/,`LifetimeProbe(${startup?'TRUE':'FALSE'});\n`),
  source=readFileSync(input,'latin1').replace(/HolyCraft;\s*$/,'').replace(/\bDCAlias\b/g,'ProbeDCAlias').replace(
    /\b(MAlloc|Free|DCNew|DCDel)\(/g,(_,name)=>'Probe'+name+'('),
  bytes=Buffer.from((backend==='wasm'?'':'#define TOS_NATIVE 1\n')+before+source+after+
    `\nif (probe_cases!=${backend==='wasm'?5:startup?6:2}) throw('Count',TRUE);\n`,'latin1'),
  sourceSha256=createHash('sha256').update(bytes).digest('hex');
if(backend==='qemu') {
  const compiler=holycWasm();
  assert(compiler,'Set HOLYC_WASM to a compiler checkout with the native oracle.');
  const {QemuRun}=await import(pathToFileURL(resolve(compiler,'tests/oracle/Qemu.mjs'))),
    result=await QemuRun([bytes],{timeout:120});
  console.log(JSON.stringify({...result,sourceSha256}));
  assert.equal(result.results[0].except,'');
  assert.doesNotMatch(result.results[0].out,/WARNING/);
  assert.match(result.results[0].out,new RegExp(`Lifetime:${startup?6:2} faults, clean retries`));
} else if(backend==='hemu') {
  assert(process.env.TEMPLEOS_WEB,'Set TEMPLEOS_WEB to a site checkout with built HEMU.');
  const {GuestHarness}=await import(pathToFileURL(resolve(process.env.TEMPLEOS_WEB,'tools/hemu/GuestHarness.mjs'))),
    h=await GuestHarness({disk:true});
  const wait=async id=>{
    for(let i=0;i<4000&&!['done','failed','error'].includes(h.gx.status(id)?.state);i++)await h.Run();
    assert.equal(h.gx.status(id)?.state,'done',JSON.stringify(h.gx.status(id)));
  };
  await wait(h.gx.writeFile({path:'C:/ORACLE/LIFETIME.HC',bytes}));
  await wait(h.gx.launch({path:'C:/ORACLE/LIFETIME.HC'}));
  console.log(JSON.stringify({backend,sourceSha256,bad:0}));
} else {
  const compiler=holycWasm();
  assert(compiler,'Set HOLYC_WASM to a compiler checkout.');
  const {compileHolyC}=await import(pathToFileURL(resolve(compiler,'src/compiler.js'))),
    {createHost}=await import(pathToFileURL(resolve(compiler,'src/runtime/host.js'))),
    compiled=compileHolyC(bytes.toString('latin1'),{filename:'Lifetime.HC',lenient:false,resilient:false});
  assert.deepEqual(compiled.diagnostics,[]);assert.deepEqual(compiled.warnings,[]);
  let out='',key=27;
  const host=createHost({onText:s=>{out+=s;},scanChar:()=>key,getChar:()=>{const ch=key;key=0;return ch;}}),
    {instance}=await WebAssembly.instantiate(compiled.bytes,{env:host.env});
  host.attach(instance);instance.exports.__rt_init();instance.exports.__main();
  assert.match(out,/Lifetime:5 faults, clean retries/);
  console.log(JSON.stringify({backend,sourceSha256,bad:0}));
}
console.log('Native startup/resize allocation failures restore ownership and permit clean retry.');
