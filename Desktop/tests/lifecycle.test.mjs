import test from 'node:test';
import assert from 'node:assert/strict';
import { installedPaths, ensureDaemon } from '../lifecycle.mjs';
test('installed paths use Workshop data and bundled daemon', () => {
 const p=installedPaths('/app/Resources','/private/tmp/user','/test-home');
 assert.equal(p.home,'/test-home/Library/Application Support/Workshop');
 assert.equal(p.socket,'/private/tmp/user/workshop/service.sock');
 assert.equal(p.daemon,'/app/Resources/workshop-daemon');
 assert.throws(()=>installedPaths('relative','/tmp'));
});
test('already available daemon is never replaced',async()=>{
 let launched=0;assert.deepEqual(await ensureDaemon({},async()=>{},async()=>{launched++;}),{started:false});assert.equal(launched,0);
});
test('missing daemon starts once and waits for readiness',async()=>{
 let probes=0,launches=0;const result=await ensureDaemon({},async()=>{if(++probes<3)throw Error('offline');},async()=>{launches++;},{wait:async()=>{}});
 assert.equal(launches,1);assert.equal(probes,3);assert.equal(result.started,true);
});
test('startup failures surface without unbounded restart loop',async()=>{
 let launches=0;await assert.rejects(ensureDaemon({},async()=>{throw Error('offline');},async()=>{launches++;},{attempts:2,wait:async()=>{}}),/did not become available/);assert.equal(launches,1);
});
