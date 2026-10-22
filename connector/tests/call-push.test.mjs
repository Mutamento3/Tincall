import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createSQLiteStore} from '../sqlite-store.mjs';
import {createCallJobs} from '../../supabase/functions/_shared/tincall/call-jobs.mjs';

test('push jobs continue after one device fails and remove only confirmed obsolete bindings',async t=>{
  const directory=mkdtempSync(join(tmpdir(),'tincall-call-push-'));
  const store=createSQLiteStore({clients:[]},join(directory,'calls.sqlite'));
  t.after(()=>{store.close();rmSync(directory,{recursive:true,force:true});});
  const owner=crypto.randomUUID();const old='10000000-0000-4000-8000-000000000001';const good='10000000-0000-4000-8000-000000000002';
  const mutate=(action,payload)=>store.command(owner,action,{request_id:crypto.randomUUID(),...payload});
  await mutate('device.put',{device_id:old,binding_id:'old-binding'});
  await mutate('device.put',{device_id:good,binding_id:'good-binding'});
  let failure='device_not_registered';const sent=[];
  const jobs=createCallJobs({store,config:{pushURL:'https://fixture.invalid',pushToken:'synthetic-token'},fetcher:async(_,init)=>{
    const body=JSON.parse(init.body);sent.push(body.binding_id);
    if(body.binding_id==='old-binding'){
      if(failure==='network')throw Error('synthetic network failure');
      return Response.json({error:{code:failure}},{status:failure==='device_not_registered'?404:502});
    }
    return Response.json({accepted_by_apns:true});
  }});
  const ring=async()=>{const id=crypto.randomUUID();await mutate('call.incoming',{call_id:id,contact_id:'synthetic',source:'mcp'});await jobs.runOwner(owner);return id;};
  const first=await ring();
  assert.deepEqual(sent,['old-binding','good-binding']);
  assert.equal((await store.command(owner,'call.record',{call_id:first})).push.status,'sent');
  await mutate('call.end',{call_id:first,epoch:0,reason:'ended'});
  sent.length=0;const second=await ring();assert.deepEqual(sent,['good-binding'],'obsolete binding must not be retried');
  await mutate('call.end',{call_id:second,epoch:0,reason:'ended'});
  for(const code of ['apns_rejected','network']){
    await mutate('device.put',{device_id:old,binding_id:'old-binding'});failure=code;sent.length=0;
    const id=await ring();assert.ok(sent.includes('good-binding'));
    await mutate('call.end',{call_id:id,epoch:0,reason:'ended'});
    sent.length=0;const retry=await ring();assert.ok(sent.includes('old-binding'),'temporary errors must retain the binding');
    await mutate('call.end',{call_id:retry,epoch:0,reason:'ended'});
  }
});
