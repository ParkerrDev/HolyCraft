import assert from 'node:assert/strict';
import {existsSync,readFileSync} from 'node:fs';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {resolve} from 'node:path';
import {holycWasm} from '../game.mjs';
import {WX,WY,WZ,CODE0,SKY0,buildScene,poses,refFrame} from './ref.mjs';

const compiler=holycWasm(),oracle=compiler&&resolve(compiler,'tests/oracle/Qemu.mjs');
assert(oracle&&existsSync(oracle),'HOLYC_WASM must contain tests/oracle/Qemu.mjs.');
const {QemuRun}=await import(pathToFileURL(oracle));
const mode=process.argv[2]||'check';
assert(['check','time'].includes(mode),'Usage: qemu.mjs [check|time] [baseline.HC]');
const current=process.env.SRC||fileURLToPath(new URL('../../HolyCraft.HC',import.meta.url));
const inputs=mode==='time'&&process.argv[3]?[resolve(process.argv[3]),current]:[current];
const repeats=mode==='time'?Number(process.env.REPEATS||1):1;
assert(Number.isSafeInteger(repeats)&&repeats>0,'REPEATS must be a positive integer.');
const paths=Array.from({length:repeats},()=>inputs).flat();
const source=path=>'#define TOS_NATIVE 1\n'+readFileSync(path,'latin1').replace(/HolyCraft;\s*$/,'');
let driver,selected=[];
if(mode==='time'){
  const count=Number(process.env.N||200);
  assert(Number.isSafeInteger(count)&&count>0,'N must be a positive integer.');
  driver=`
U0 C1Time()
{
  I64 i;
  F64 t0,elapsed;
  CDC *dc;
  Seed(0x7A654321);
  Init;
#ifdef SkyRowsMake
  SkyRowsMake;
#endif
  g_px=64.5;g_pz=64.5;
  g_py=g_hm[64+128*64]+2.62;
  g_yaw=0.7;g_pitch=-0.06;
  dc=DCNew(640,480);
  for (i=0;i<10;i++) RenderFaces(dc);
  t0=tS;
  for (i=0;i<${count};i++) RenderFaces(dc);
  elapsed=tS-t0;
  "spawn %.3f ms/frame, ${count} frames\\n",elapsed*${1000/count};
  DCDel(dc);
}
C1Time;
`;
}else{
  const world=new Uint8Array(WX*WY*WZ);
  buildScene(world);
  const names=['spawn','under-ceiling-up','wall-0.3-up','cliff-0.3-along-up',
    'cliff-0.3-along-down','cliff-top-down','above-41.5','fly18-pitch-1.40'];
  selected=poses(world).filter(p=>names.includes(p.name));
  const runs=[],offsets=[0];
  for(const p of selected){
    const ref=refFrame(world,p,640,480);
    for(let i=0;i<ref.length;){
      const hit=ref[i];
      if(!hit||hit.t>=19.13){i++;continue;}
      const start=i,code=hit.code;
      while(i<ref.length&&ref[i]&&ref[i].t<19.13&&ref[i].code===code)i++;
      runs.push(start,i-start,code);
    }
    offsets.push(runs.length);
  }
  const array=(type,name,values)=>`${type} ${name}[${values.length}]={\n`+
    values.map((v,i)=>(i&&i%12===0?'\n':'')+v).join(',')+'};\n';
  driver=array('I64','c1_runs',runs)+array('I64','c1_offsets',offsets)+
    array('F64','c1_poses',selected.flatMap(p=>[p.x,p.y,p.z,p.yaw,p.pitch]))+`
I64 c1_res[${selected.length*3}]; //Each pose: bad, total and the frame's FNV-1a.

U0 C1Check()
{
  I64 x,y,z,b,p,i,j,bad,total,hash;
  U8 *pix;
  CDC *dc;
  Init;
  MemSet(g_world,0,WX*WY*WZ);
  for (x=44;x<=84;x++)
    for (z=44;z<=84;z++)
      for (y=0;y<14;y++) {
        if (y<11) b=3;
        else if (y<13) b=2;
        else b=1;
        g_world[WIdx(x,y,z)]=b;
      }
  for (x=56;x<=72;x++)
    for (y=14;y<=18;y++) g_world[WIdx(x,y,70)]=3;
  for (x=74;x<=80;x++)
    for (y=14;y<=33;y++) g_world[WIdx(x,y,56)]=3;
  for (x=46;x<=50;x++)
    for (z=76;z<=80;z++) g_world[WIdx(x,16,z)]=4;
  for (y=14;y<=20;y++) g_world[WIdx(60,y,60)]=5;
  for (i=0;i<24*6;i++) {
    g_flo[i]=${CODE0}+i;g_fhi[i]=${CODE0}+i;
  }
  for (i=0;i<3;i++) g_skyr[i]=${SKY0};
  BuildHM;
  SkyRowsMake;
  dc=DCNew(640,480);
  for (p=0;p<${selected.length};p++) {
    g_px=c1_poses[p*5];g_py=c1_poses[p*5+1];g_pz=c1_poses[p*5+2];
    g_yaw=c1_poses[p*5+3];g_pitch=c1_poses[p*5+4];
    RenderFaces(dc);
    bad=0;total=0;
    for (i=c1_offsets[p];i<c1_offsets[p+1];i+=3) {
      pix=dc->body+c1_runs[i];
      for (j=0;j<c1_runs[i+1];j++)
        if (pix[j]!=c1_runs[i+2]) bad++;
      total+=c1_runs[i+1];
    }
    hash=0xCBF29CE484222325;
    for (i=0;i<640*480;i++)
      hash=(hash^dc->body[i])*0x100000001B3;
    c1_res[p*3]=bad;c1_res[p*3+1]=total;c1_res[p*3+2]=hash;
    "pose %d bad %d of %d frame %016X\\n",p,bad,total,hash;
  }
  DCDel(dc);
}
`;
}
const call=mode==='check'?'C1Check;\n':'';
const result=await QemuRun(paths.map(path=>Buffer.from(source(path)+driver+call,'latin1')));
console.log(JSON.stringify(result.backend));
const native=[];
assert.equal(result.results.length,paths.length,'Missing QEMU results.');
result.results.forEach((r,i)=>{
  console.log(paths[i]+'\n'+r.out.trim());
  assert.equal(r.except,'','Native program raised an exception.');
  if(mode==='check'){
    const rows=[...r.out.matchAll(/pose (\d+) bad (\d+) of (\d+) frame ([0-9A-F]{16})/g)];
    assert.equal(rows.length,selected.length,'Missing native camera results.');
    rows.forEach((row,k)=>{
      assert.equal(Number(row[1]),k,'Camera results out of order.');
      assert(Number(row[3])>0,'Empty reference mask.');
      // GrFillPoly3 fans GrFillTri0, which leaves single pixels on shared diagonals.
      assert(Number(row[2])*100<=Number(row[3]),`${selected[k].name}: QEMU pixels differ from exact rays`);
      native.push([Number(row[2]),Number(row[3]),row[4]]);
    });
  }else assert.match(r.out,/spawn [\d.]+ ms\/frame/,'Missing native timing.');
});
console.log('Evidence: '+result.evidence);
if(mode==='check'&&process.env.TEMPLEOS_WEB){
  // The same source and camera poses in HEMU must give the native frames bit for bit.
  const {GuestHarness}=await import(pathToFileURL(resolve(process.env.TEMPLEOS_WEB,'tools/hemu/GuestHarness.mjs'))),
    h=await GuestHarness({disk:true}),ptr=h.gx.scratch.base+0x1400;
  const id=h.gx.writeFile({path:'C:/ORACLE/C1CHECK.HC',bytes:Buffer.from(source(current)+driver,'latin1')});
  for(let i=0;i<4000&&!['done','failed','error'].includes(h.gx.status(id)?.state);i++)await h.Run();
  assert.equal(h.gx.status(id)?.state,'done',JSON.stringify(h.gx.status(id)));
  await h.Exec('#include "C:/ORACLE/C1CHECK.HC";');
  await h.Exec('C1Check;*('+ptr+')(I64*)=c1_res;');
  const view=new DataView(h.ex.memory.buffer),res=Number(view.getBigUint64(h.base+ptr,true));
  selected.forEach((p,k)=>{
    const at=h.base+res+k*24,frame=view.getBigUint64(at+16,true).toString(16).toUpperCase().padStart(16,'0'),
      hemu=[Number(view.getBigInt64(at,true)),Number(view.getBigInt64(at+8,true)),frame];
    assert.deepEqual(hemu,native[k],`${p.name}: HEMU frame differs from native TempleOS`);
    console.log(`${p.name}: HEMU frame ${frame} equals native TempleOS`);
  });
}
