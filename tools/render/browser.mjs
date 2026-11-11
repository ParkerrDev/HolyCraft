import assert from 'node:assert/strict';
import {readFile,mkdir,mkdtemp} from 'node:fs/promises';
import {createServer} from 'node:http';
import {once} from 'node:events';
import {createRequire} from 'node:module';
import {resolve,join} from 'node:path';
import {tmpdir} from 'node:os';
import {pathToFileURL,fileURLToPath} from 'node:url';

assert(process.env.TEMPLEOS_WEB,'Set TEMPLEOS_WEB to a built TempleOS-Web checkout.');
const site=resolve(process.env.TEMPLEOS_WEB);
const source=process.env.SRC||fileURLToPath(new URL('../../HolyCraft.HC',import.meta.url));
const output=process.env.OUT||await mkdtemp(join(tmpdir(),'holycraft-browser-'));
const at=path=>import(pathToFileURL(resolve(site,path)));
const {chromium}=createRequire(resolve(site,'package.json'))('playwright-core');
const {ServeReq}=await at('server.mjs');
const {BrowserMachine,MachinePost,MachineReady}=await at('tools/hemu/BrowserMachine.mjs');
const program='#define TOS_NATIVE 1\n'+await readFile(source,'latin1');
const nativeProbe=`
F64 craft_yaw0;
U8 *CraftVar(CTask *task,U8 *name)
{
  CHashGlblVar *tmpg=HashFind(name,task->hash_table,HTT_GLBL_VAR);
  if (!tmpg) return NULL;
  return tmpg->data_addr;
}
U0 CraftReady(CTask *task)
{
  F64 end=tS+20;
  U8 *ptr;
  while (tS<end) {
    ptr=CraftVar(task,"g_view");
    if (ptr && *ptr(CDC **) && task->draw_it) {
      craft_yaw0=*CraftVar(task,"g_yaw")(F64 *);
      return;
    }
    Sleep(20);
  }
  throw('NoDraw');
}
U0 CraftTurnWait(CTask *task)
{
  F64 end=tS+10;
  while (tS<end) {
    if (Abs(*CraftVar(task,"g_yaw")(F64 *)-craft_yaw0)>0.1)
      return;
    Sleep(20);
  }
  throw('NoTurn');
}
`;
await mkdir(output,{recursive:true});
console.log('Browser screenshots:',output);
const server=createServer(ServeReq).listen(0,'127.0.0.1');
await once(server,'listening');
const browser=await chromium.launch({executablePath:process.env.CHROMIUM||'/usr/bin/chromium',
  headless:true,args:['--no-sandbox']});
let request=0;
async function Check(page,src) {
  const id='craft-check-'+(++request);
  await MachinePost(page,{cmd:'osExec',id,src,target:'adam'});
  await page.waitForFunction(id=>window.machine.events.some(m=>m.cmd==='fileResult'&&m.id===id),id,{timeout:45000});
  const result=await page.evaluate(id=>window.machine.events.find(m=>m.cmd==='fileResult'&&m.id===id),id);
  assert.equal(result.ok,true,JSON.stringify(result));
}
try {
  for(const cores of [1,4]) {
    const context=await browser.newContext({viewport:{width:1280,height:900}});
    try {
      await BrowserMachine(context);
      const page=await context.newPage(),errors=[];
      page.on('pageerror',error=>errors.push(error.message));
      await page.goto(`http://127.0.0.1:${server.address().port}/?${cores===1?'single':'smp'}`);
      await MachineReady(page,cores);
      await page.waitForFunction(()=>window.machine.events.some(m=>m.name==='Welcome'&&m.state==='done'),null,{timeout:45000});
      await Check(page,nativeProbe);
      const id='craft-window-'+cores;
      await MachinePost(page,{cmd:'osLaunch',id,name:'HolyCraft native window',src:program});
      await page.waitForFunction(id=>window.machine.events.some(m=>m.id===id&&
        ['running','failed','error'].includes(m.state)),id,{timeout:45000});
      const started=await page.evaluate(id=>window.machine.events.find(m=>m.id===id&&
        ['running','failed','error'].includes(m.state)),id);
      assert.equal(started.state,'running',JSON.stringify(started));
      assert.match(started.task,/^0x[0-9a-f]+$/i);
      await Check(page,`CraftReady(${started.task}(CTask *));`);
      const frames=await page.evaluate(()=>window.machine.frames);
      await page.waitForFunction(n=>window.machine.frames>=n+4,frames,{timeout:15000});
      await page.locator('#canvas').screenshot({path:resolve(output,`craft-${cores}-before.png`)});
      await page.locator('#canvas').click();
      await Check(page,`craft_yaw0=*CraftVar(${started.task}(CTask *),"g_yaw")(F64 *);`);
      await page.keyboard.down('l');
      try {await Check(page,`CraftTurnWait(${started.task}(CTask *));`);}
      finally {await page.keyboard.up('l');}
      await page.locator('#canvas').screenshot({path:resolve(output,`craft-${cores}-turned.png`)});
      await page.evaluate(()=>{if(document.pointerLockElement)document.exitPointerLock();});
      await page.locator('#keysbar').getByRole('button',{name:'Esc',exact:true}).click();
      await page.waitForFunction(id=>window.machine.events.some(m=>m.cmd==='guestResult'&&m.id===id&&
        ['done','failed','error'].includes(m.state)),id,{timeout:45000});
      const finished=await page.evaluate(id=>window.machine.events.find(m=>m.cmd==='guestResult'&&m.id===id&&
        ['done','failed','error'].includes(m.state)),id);
      assert.equal(finished.state,'done',JSON.stringify(finished));
      assert.deepEqual(errors,[]);
      assert.deepEqual(await page.evaluate(()=>window.machine.events.filter(m=>m.cmd==='error')),[]);
      console.log(`${cores}-core browser: native DrawIt allocates its view, real frames reach the canvas, held L changes native yaw and the on-screen Escape exits without a worker fault.`);
    } finally {await context.close();}
  }
} finally {await browser.close();await new Promise(resolve=>server.close(resolve));}
