// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createSQLiteStore} from '../sqlite-store.mjs';
import {createConnector} from '../../supabase/functions/_shared/tincall/service.mjs';

const deadline=promise=>Promise.race([promise,new Promise((_,reject)=>{const timer=setTimeout(()=>reject(new Error('bridge must return without waiting')),2000);timer.unref();})]);
async function frame(reader) {
  const {value,done}=await deadline(reader.read());assert.equal(done,false);
  const text=new TextDecoder().decode(value);
  const data=text.split('\n').find(line=>line.startsWith('data: '));
  return {event:text.split('\n').find(line=>line.startsWith('event: '))?.slice(7),data:data?JSON.parse(data.slice(6)):null};
}

test('wake bridge drives opening and every input without hanging tools, recovers only pending work and isolates credentials',async()=>{
  const directory=mkdtempSync(join(tmpdir(),'tincall-wake-'));
  const owner=crypto.randomUUID(),other=crypto.randomUUID();
  const store=createSQLiteStore({clients:[{token:'phone',owner_id:owner},{token:'other',owner_id:other}]},join(directory,'data.sqlite'));
  let snapshots=0;const snapshot=store.mcpCommand.bind(store);
  store.mcpCommand=async(...args)=>{if(args[2]==='snapshot')snapshots++;return snapshot(...args);};
  const connector=createConnector({store,config:{},schedule:()=>{}});
  let taskCallID;
  const request=(path,token='phone',body,signal)=>new Request('https://fixture.invalid'+path,{
    method:body?'POST':'GET',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',Accept:'application/json, text/event-stream',
      ...(taskCallID && body?.method==='tools/call'?{'Tincall-Call-ID':taskCallID}:{})},
    ...(body?{body:JSON.stringify(body)}:{}),signal,
  });
  const post=async(path,body,token='phone')=>{
    const response=await connector.handle(request(path,token,body));assert.equal(response.status,200);return response.json();
  };
  const tool=async(token,name,args={},path='/mcp/wake')=>(await deadline(post(path,{jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}},token))).result;
  const read=async(token,cursor)=>{
    const query=cursor?'?'+new URLSearchParams(cursor):'';
    const response=await deadline(connector.handle(request('/wake/input'+query,token)));
    assert.equal(response.status,200);return response.json();
  };
  const mutation=payload=>({request_id:crypto.randomUUID(),...payload});
  const abort=new AbortController();let reader,reconnected;
  try {
    const role=await post('/mcp/roles/upsert',{role_id:crypto.randomUUID(),contact_id:'linked',display_name:'Fixture'});
    const config=await post('/wake/config',{contact_id:'linked'});
    assert.deepEqual((await (await connector.handle(request('/wake/contacts'))).json()).contacts,[{contact_id:'linked',display_name:'Fixture'}]);
    const token=config.wake.headers.Authorization.slice(7);
    assert.match(token,/^tcwake_[0-9a-f]{64}$/);assert.notEqual(token,role.token);
    assert.equal(config.wake.url,'https://fixture.invalid/wake/events');
    assert.equal(config.version,2);
    assert.equal(config.input.url,'https://fixture.invalid/wake/input');
    assert.equal(config.mcp.url,'https://fixture.invalid/mcp/wake');
    assert.equal(config.input.headers.Authorization,config.wake.headers.Authorization);
    assert.equal(config.mcp.headers.Authorization,config.wake.headers.Authorization);
    assert.deepEqual(await post('/wake/config',{contact_id:'linked'}),config,'opening saved settings must recover the same configuration');
    for(const path of ['/capabilities','/calls/current','/wake/contacts','/wake/config','/records'])assert.equal((await connector.handle(request(path,token))).status,403);
    assert.equal((await connector.handle(request('/wake/config',role.token,{contact_id:'linked'}))).status,403);
    assert.equal((await connector.handle(request('/wake/events','phone'))).status,403);
    assert.equal((await connector.handle(request('/wake/input','phone'))).status,403);
    assert.equal((await connector.handle(request('/wake/input',role.token))).status,403);
    assert.equal((await connector.handle(request('/mcp/wake',role.token,{jsonrpc:'2.0',id:1,method:'initialize'}))).status,403);
    for(const query of ['?sequence=1','?sequence=oops&epoch=0','?sequence=0&epoch=-1','?call_id=other']){
      assert.equal((await connector.handle(request('/wake/input'+query,token))).status,400);
    }
    assert.equal((await connector.handle(request('/wake/config','other',{contact_id:'linked'}))).status,404);
    const response=await connector.handle(request('/wake/events',token,undefined,abort.signal));assert.equal(response.status,200);
    reader=response.body.getReader();assert.equal((await frame(reader)).event,'ready');
    const callID=crypto.randomUUID();
    taskCallID=callID;
    await post('/calls',mutation({call_id:callID,contact_id:'linked',source:'mcp'}));
    const opening=await frame(reader);assert.equal(opening.event,'wake');assert.equal(opening.data.reason,'answered');
    assert.deepEqual(Object.keys(opening.data).sort(),['version','event_id','call_id','contact_id','reason','reply_to'].sort());
    const initialized=(await post('/mcp/wake',{jsonrpc:'2.0',id:1,method:'initialize'},token)).result;
    assert.equal(initialized.serverInfo.name,'tincall-wake-connector');
    const tools=(await post('/mcp/wake',{jsonrpc:'2.0',id:2,method:'tools/list'},token)).result.tools;
    assert.equal(tools.find(t=>t.name==='tincall_reply').inputSchema.properties.wait_for_input,undefined);
    assert.ok(!tools.some(t=>t.name==='tincall_wait'));
    const countBeforeWait=snapshots;
    for(const path of ['/mcp/wake','/mcp']){
      const completed=await tool(token,'tincall_wait',{timeout_seconds:120},path);
      assert.equal(completed.isError,false);
      assert.match(completed.content[0].text,/无需等待/);
      assert.equal(completed.structuredContent,undefined);
    }
    assert.equal(snapshots,countBeforeWait,'obsolete waits must return immediately without accessing call state');
    const ordinary=(await post('/mcp',{jsonrpc:'2.0',id:3,method:'tools/list'},role.token)).result.tools;
    assert.ok(ordinary.some(t=>t.name==='tincall_wait'),'ordinary MCP keeps its waiting tool');
    const first=(await read(token)).structuredContent;
    assert.equal(first.event,'answered');assert.equal(first.reply.reply_to,opening.data.reply_to);
    assert.ok(first.voice_instructions);
    const reply={text:'Synthetic opening'};
    const accepted=await tool(token,'tincall_reply',reply);
    assert.deepEqual(accepted,{content:[{type:'text',text:'已发送。'}],isError:false});
    assert.equal((await read(token)).structuredContent.event,'idle','input reads must not hang after a finished turn');
    const count=snapshots;await new Promise(resolve=>setTimeout(resolve,270));assert.equal(snapshots,count,'idle bridge must not query current calls');
    const hiddenCall=crypto.randomUUID();
    await store.command(other,'call.create',mutation({call_id:hiddenCall,contact_id:'private-other',source:'mcp'}));
    await snapshot(other,null,'open',{call_id:hiddenCall});
    assert.equal(snapshots,count,'another owner must not cause this subscriber to read or receive anything');
    await post(`/calls/${callID}/input`,mutation({message_id:crypto.randomUUID(),epoch:0,text:'Synthetic private input'}));
    const input=await frame(reader);assert.equal(input.event,'wake');assert.equal(input.data.reason,'input');assert.notEqual(input.data.event_id,opening.data.event_id);
    assert.ok(!JSON.stringify(input).includes('Synthetic private input'));
    await reader.cancel();
    reconnected=(await connector.handle(request('/wake/events',token,undefined,abort.signal))).body.getReader();
    assert.equal((await frame(reconnected)).event,'ready');
    assert.equal((await frame(reconnected)).data.event_id,input.data.event_id,'reconnect must replay unanswered input even with Last-Event-ID');
    const pending=(await read(token)).structuredContent;assert.equal(pending.reply.reply_to,input.data.reply_to);
    assert.equal(pending.voice_instructions,null,'later wakes retain the same conversation and must not repeat voice rules');
    assert.equal((await tool(token,'tincall_reply',{text:'Synthetic answer',wait_for_input:true})).isError,false,'bridge replies never wait, even with an obsolete explicit flag');
    await reconnected.cancel();
    reconnected=(await connector.handle(request('/wake/events',token,undefined,abort.signal))).body.getReader();
    assert.equal((await frame(reconnected)).event,'ready');
    // The next frame must be the next real input, not replay of a finished turn.
    await post(`/calls/${callID}/input`,mutation({message_id:crypto.randomUUID(),epoch:pending.call.epoch,text:'Next input'}));
    const next=await frame(reconnected);assert.notEqual(next.data.event_id,input.data.event_id);
    const reset=await post('/wake/config',{contact_id:'linked',rotate:true});assert.notEqual(reset.wake.headers.Authorization,config.wake.headers.Authorization);
    assert.equal((await connector.handle(request('/wake/events',token))).status,401);
    await post(`/calls/${callID}/input`,mutation({message_id:crypto.randomUUID(),epoch:(await store.command(owner,'call.record',{call_id:callID})).call.epoch,text:'After reset'}));
    assert.equal((await frame(reconnected)).event,'error');assert.equal((await deadline(reconnected.read())).done,true,'reset must retire old live subscribers on the next event');
    const refreshed=reset.wake.headers.Authorization.slice(7);
    await post('/mcp/roles/mode',{role_id:role.role_id,call_mode:'standalone'});
    assert.equal((await connector.handle(request('/wake/events',refreshed))).status,401);
    assert.deepEqual((await (await connector.handle(request('/wake/contacts'))).json()).contacts,[]);
  } finally {abort.abort();await reader?.cancel();await reconnected?.cancel();store.close();rmSync(directory,{recursive:true,force:true});}
});

test('wake adapter reads complete input pages before the AI can reply and returns ended without waiting',async()=>{
  const directory=mkdtempSync(join(tmpdir(),'tincall-wake-input-'));
  const owner=crypto.randomUUID();
  const store=createSQLiteStore({clients:[{token:'phone',owner_id:owner}]},join(directory,'data.sqlite'));
  const connector=createConnector({store,config:{},schedule:()=>{}});
  async function send(path,token='phone',body){
    const response=await deadline(connector.handle(new Request('https://fixture.invalid'+path,{
      method:body?'POST':'GET',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',Accept:'application/json, text/event-stream'},
      ...(body?{body:JSON.stringify(body)}:{}),
    })));
    assert.equal(response.status,200);return response.json();
  }
  try {
    await send('/mcp/roles/upsert','phone',{role_id:crypto.randomUUID(),contact_id:'linked',display_name:'Fixture'});
    const config=await send('/wake/config','phone',{contact_id:'linked'});
    const token=config.input.headers.Authorization.slice(7);
    assert.equal((await send('/wake/input',token)).structuredContent.event,'ended');
    const id=crypto.randomUUID();
    await send('/calls','phone',{request_id:crypto.randomUUID(),call_id:id,contact_id:'linked',source:'mcp'});
    for(let epoch=0;epoch<51;epoch++){
      await send(`/calls/${id}/input`,'phone',{request_id:crypto.randomUUID(),message_id:crypto.randomUUID(),epoch,text:'Synthetic input '+epoch});
    }
    const first=(await send('/wake/input',token)).structuredContent;
    assert.equal(first.has_more,true);assert.equal(first.reply,null);assert.equal(first.messages.length,50);
    const second=await send('/wake/input?'+new URLSearchParams(first.cursor),token);
    const last=second.structuredContent;
    assert.equal(last.has_more,false);assert.equal(last.messages.length,1);assert.equal(last.reply.kind,'input');
    assert.equal(last.reply.input_id,last.messages[0].id);
    assert.match(last.voice_instructions,/语音/);
    assert.doesNotMatch(second.content[0].text,/reply_to|epoch|cursor/);
    assert.deepEqual([...first.messages,...last.messages].map(message=>message.text),Array.from({length:51},(_,i)=>'Synthetic input '+i));
    await store.command(owner,'call.end',{request_id:crypto.randomUUID(),call_id:id,epoch:last.call.epoch,reason:'synthetic'});
    assert.equal((await send('/wake/input',token)).structuredContent.event,'ended');
  } finally {store.close();rmSync(directory,{recursive:true,force:true});}
});

test('bridge MCP over SSE keeps bridge tools and returns after replying',async()=>{
  const directory=mkdtempSync(join(tmpdir(),'tincall-wake-sse-'));
  const store=createSQLiteStore({clients:[{token:'phone',owner_id:crypto.randomUUID()}]},join(directory,'data.sqlite'));
  const scheduled=[];
  const connector=createConnector({store,config:{},schedule:task=>scheduled.push(task)});
  const abort=new AbortController();let reader;
  let taskCallID;
  const request=(path,token,body)=>new Request('https://fixture.invalid'+path,{
    method:body?'POST':'GET',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',Accept:'application/json, text/event-stream',
      ...(taskCallID && body?.method==='tools/call'?{'Tincall-Call-ID':taskCallID}:{})},
    ...(body?{body:JSON.stringify(body)}:{}),signal:abort.signal,
  });
  const post=async(path,token,body)=>{
    const result=await connector.handle(request(path,token,body));assert.equal(result.status,200);return result.json();
  };
  try {
    await post('/mcp/roles/upsert','phone',{role_id:crypto.randomUUID(),contact_id:'linked',display_name:'Fixture'});
    const config=await post('/wake/config','phone',{contact_id:'linked'});
    const token=config.mcp.headers.Authorization.slice(7);
    const response=await connector.handle(request('/mcp/sse',token));assert.equal(response.status,200);
    reader=response.body.getReader();
    const endpointFrame=new TextDecoder().decode((await deadline(reader.read())).value);
    assert.match(endpointFrame,/event: endpoint/);
    const endpoint=new URL(endpointFrame.split('\n').find(line=>line.startsWith('data: ')).slice(6),'https://fixture.invalid/mcp/sse');
    let id=0;
    const rpc=async(method,params)=>{
      const accepted=await connector.handle(request(endpoint.pathname+endpoint.search,token,{jsonrpc:'2.0',id:++id,method,params}));
      assert.equal(accepted.status,202);
      await deadline(Promise.all(scheduled.splice(0)));
      const message=await frame(reader);assert.equal(message.event,'message');assert.equal(message.data.id,id);
      assert.equal(message.data.error,undefined);return message.data.result;
    };
    assert.equal((await rpc('initialize',{protocolVersion:'2024-11-05',capabilities:{},clientInfo:{name:'Fixture',version:'1'}})).serverInfo.name,'tincall-wake-connector');
    const tools=(await rpc('tools/list')).tools;
    assert.ok(!tools.some(tool=>tool.name==='tincall_wait'));
    assert.equal(tools.find(tool=>tool.name==='tincall_reply').inputSchema.properties.wait_for_input,undefined);
    const obsolete=await rpc('tools/call',{name:'tincall_wait',arguments:{}});
    assert.equal(obsolete.isError,false);assert.match(obsolete.content[0].text,/无需等待/);
    await post('/calls','phone',{request_id:crypto.randomUUID(),call_id:crypto.randomUUID(),contact_id:'linked',source:'mcp'});
    const input=await (await connector.handle(request('/wake/input',token))).json();
    taskCallID=input.structuredContent.call.id;
    const reply=await rpc('tools/call',{name:'tincall_reply',arguments:{text:'Synthetic SSE reply'}});
    assert.equal(reply.isError,false);assert.deepEqual(reply.content,[{type:'text',text:'已发送。'}]);
    assert.equal((await (await connector.handle(request('/wake/input',token))).json()).structuredContent.event,'idle');
  } finally {
    abort.abort();if(reader)await reader.cancel();await Promise.allSettled(scheduled);store.close();rmSync(directory,{recursive:true,force:true});
  }
});

test('bridge dial waits for answer in its initiating task without a duplicate opening wake',async()=>{
  const directory=mkdtempSync(join(tmpdir(),'tincall-wake-dial-')),owner=crypto.randomUUID();
  const store=createSQLiteStore({clients:[{token:'phone',owner_id:owner}]},join(directory,'db.sqlite'));
  const connector=createConnector({store,config:{},schedule:()=>{}});
  let reader;
  const taskCallID=crypto.randomUUID();
  const request=(path,token,body)=>new Request('https://fixture.invalid'+path,{method:body?'POST':'GET',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json',Accept:'application/json, text/event-stream',...(body?.method==='tools/call'?{'Tincall-Call-ID':taskCallID}:{})},...(body?{body:JSON.stringify(body)}:{})});
  const post=async(path,token,body)=>(await connector.handle(request(path,token,body))).json();
  try {
    await post('/mcp/roles/upsert','phone',{role_id:crypto.randomUUID(),contact_id:'linked',display_name:'Fixture'});
    const config=await post('/wake/config','phone',{contact_id:'linked'}),token=config.mcp.headers.Authorization.slice(7);
    reader=(await connector.handle(request('/wake/events',token))).body.getReader();assert.equal((await frame(reader)).event,'ready');
    let settled=false;
    const pending=post('/mcp/wake',token,{jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'tincall_call',arguments:{timeout_seconds:3}}}).then(result=>{settled=true;return result;});
    let call;
    for(let i=0;i<100;i++) {call=(await store.command(owner,'call.current')).call;if(call)break;await new Promise(resolve=>setTimeout(resolve,10));}
    assert.equal(settled,false);assert.equal(call.status,'ringing');assert.equal(call.id,taskCallID);
    await post(`/calls/${call.id}/answer`,'phone',{request_id:crypto.randomUUID(),epoch:0,user_name:'小白',expression_prompt:'Synthetic first-call instruction'});
    const answered=(await pending).result;assert.match(answered.content[0].text,/已接通/);assert.match(answered.content[0].text,/Synthetic first-call instruction/);
    assert.equal((await post('/mcp/wake',token,{jsonrpc:'2.0',id:2,method:'tools/call',params:{name:'tincall_reply',arguments:{text:'Hello'}}})).result.isError,false);
    await post(`/calls/${call.id}/input`,'phone',{request_id:crypto.randomUUID(),message_id:crypto.randomUUID(),epoch:0,text:'Next input'});
    assert.equal((await frame(reader)).data.reason,'input','answer belongs to the waiting dial task');
  } finally {await reader?.cancel();store.close();rmSync(directory,{recursive:true,force:true});}
});
