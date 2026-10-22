import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createSQLiteStore} from '../sqlite-store.mjs';
import {createConnector} from '../../supabase/functions/_shared/tincall/service.mjs';

for (const mode of ['ordinary','bridge'])for (const operation of ['tincall_reply','tincall_end']) {
  test(`${mode}: late ${operation} bound to ended call A cannot mutate new call B`,async()=>{
    const directory=mkdtempSync(join(tmpdir(),'tincall-isolation-')),owner=crypto.randomUUID();
    const store=createSQLiteStore({clients:[{token:'contact',owner_id:owner,contact_id:'linked'}]},join(directory,'db.sqlite'));
    const connector=createConnector({store,config:{bindings:[{owner_id:owner,contact_id:'linked',mode:'tools'}]},schedule:()=>{}});
    const mutation=p=>({request_id:crypto.randomUUID(),...p});
    await store.mcpRoleCommand(owner,'upsert',{role_id:crypto.randomUUID(),contact_id:'linked',display_name:'Synthetic contact',token:'tcmcp_'+'a'.repeat(64)});
    const {token}=await store.wakeCommand('configuration',owner,{contact_id:'linked',token:'tcwake_'+'b'.repeat(64)});
    async function tool(name,args={},callID) {
      const response=await connector.handle(new Request('https://fixture.invalid/mcp',{method:'POST',headers:{
        Authorization:'Bearer '+(mode==='bridge'?token:'contact'),'Content-Type':'application/json',Accept:'application/json, text/event-stream',
        ...(callID?{'Tincall-Call-ID':callID}:{}),
      },body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}})}));
      return (await response.json()).result;
    }
    try {
      const a=crypto.randomUUID(),b=crypto.randomUUID();
      await store.command(owner,'call.create',mutation({call_id:a,contact_id:'linked',source:'mcp'}));
      const first=await tool('tincall_get_call');
      const marker=mode==='ordinary'?first.content.find(block=>block.text?.startsWith('call: ')).text.slice(6):undefined;
      if(marker)assert.match(marker,/^[A-Za-z0-9_-]{8}$/);
      await store.command(owner,'call.end',mutation({call_id:a,epoch:0}));
      await store.command(owner,'call.create',mutation({call_id:b,contact_id:'linked',source:'mcp'}));
      const before=await store.command(owner,'call.record',{call_id:b});
      const result=await tool(operation,{...(marker?{call:marker}:{}),...(operation==='tincall_reply'?{text:'Late reply from A',wait_for_input:false}:{})},mode==='bridge'?a:undefined);
      assert.equal(result.isError,true,'late call A operation must be rejected');
      assert.deepEqual(await store.command(owner,'call.record',{call_id:b}),before,'call B must stay unchanged');
      const unbound=await tool(operation,operation==='tincall_reply'?{text:'Unbound late reply',wait_for_input:false}:{});
      assert.equal(unbound.isError,true,'unbound mutation must never select a new current call');
      assert.deepEqual(await store.command(owner,'call.record',{call_id:b}),before);
      const current=await tool('tincall_get_call');
      const nextMarker=mode==='ordinary'?current.content.find(block=>block.text?.startsWith('call: ')).text.slice(6):undefined;
      const fresh=await tool(operation,{...(nextMarker?{call:nextMarker}:{}),...(operation==='tincall_reply'?{text:'Correct call B reply',wait_for_input:false}:{})},mode==='bridge'?b:undefined);
      assert.equal(fresh.isError,false,'a correctly bound call B operation must still succeed');
    } finally {store.close();rmSync(directory,{recursive:true,force:true});}
  });
}
