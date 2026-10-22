// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createSQLiteStore} from '../sqlite-store.mjs';
import {createConnector} from '../../supabase/functions/_shared/tincall/service.mjs';

const owner='10000000-0000-4000-8000-000000000001';
const other='10000000-0000-4000-8000-000000000002';
const deadline=p=>Promise.race([p,new Promise((_,reject)=>{const timer=setTimeout(()=>reject(new Error('event delivery timeout')),2000);timer.unref();})]);
async function frame(reader) {
  while(true){const {value,done}=await deadline(reader.read());assert.equal(done,false);const text=new TextDecoder().decode(value);const data=text.split('\n').find(line=>line.startsWith('data: '));if(data)return JSON.parse(data.slice(6));}
}

test('incoming subscription delivers committed owner events without periodic current reads or private content',async()=>{
  const directory=mkdtempSync(join(tmpdir(),'tincall-incoming-'));
  const store=createSQLiteStore({clients:[{token:'phone',owner_id:owner},{token:'role',owner_id:owner,contact_id:'synthetic'}]},join(directory,'data.sqlite'));
  let reads=0;const command=store.command.bind(store);
  store.command=async(...args)=>{if(args[1]==='call.current')reads++;return command(...args);};
  const connector=createConnector({store,config:{}});
  const abort=new AbortController();let reader;
  try {
    const response=await connector.handle(new Request('https://fixture.invalid/calls/incoming/events',{headers:{Authorization:'Bearer phone',Accept:'text/event-stream'},signal:abort.signal}));
    assert.equal(response.status,200);assert.match(response.headers.get('content-type'),/text\/event-stream/);
    reader=response.body.getReader();assert.deepEqual(await frame(reader),{call:null});assert.equal(reads,1);
    const id=crypto.randomUUID();
    await command(other,'call.incoming',{request_id:crypto.randomUUID(),call_id:crypto.randomUUID(),contact_id:'other',source:'mcp'});
    await command(owner,'call.incoming',{request_id:crypto.randomUUID(),call_id:id,contact_id:'synthetic',source:'mcp'});
    const incoming=await frame(reader);assert.equal(incoming.call.id,id);assert.equal(incoming.call.status,'ringing');
    assert.deepEqual(Object.keys(incoming.call).sort(),['contact_id','epoch','id','last_sequence','source','status'].sort());
    await new Promise(resolve=>setTimeout(resolve,270));assert.equal(reads,1,'idle subscription must not query the database');
    await command(owner,'call.end',{request_id:crypto.randomUUID(),call_id:id,epoch:0,reason:'synthetic'});
    assert.equal((await frame(reader)).call.status,'ended');assert.equal(reads,1);
    const denied=await connector.handle(new Request('https://fixture.invalid/calls/incoming/events',{headers:{Authorization:'Bearer role',Accept:'text/event-stream'}}));
    assert.equal(denied.status,403);
    abort.abort();assert.equal((await deadline(reader.read())).done,true);
    const count=reads;
    await command(owner,'call.incoming',{request_id:crypto.randomUUID(),call_id:crypto.randomUUID(),contact_id:'synthetic',source:'mcp'});
    assert.equal(reads,count,'closed subscriptions must not perform reads');
  } finally {abort.abort();await reader?.cancel();store.close();rmSync(directory,{recursive:true,force:true});}
});

test('Supabase subscription uses a private owner channel, forwards metadata and releases the socket',async()=>{
  const {createSupabaseStore}=await import('../../supabase/functions/_shared/tincall/service.mjs');
  const original=globalThis.WebSocket;let socket;
  class Socket extends EventTarget {
    readyState=1;sent=[];closed=false;
    constructor(){super();socket=this;queueMicrotask(()=>this.dispatchEvent(new Event('open')));}
    send(value){const message=JSON.parse(value);this.sent.push(message);if(message.event==='phx_join')queueMicrotask(()=>this.message({topic:message.topic,event:'phx_reply',payload:{status:'ok'},ref:message.ref}));}
    message(value){this.dispatchEvent(new MessageEvent('message',{data:JSON.stringify(value)}));}
    close(){this.closed=true;}
  }
  globalThis.WebSocket=Socket;
  const abort=new AbortController();
  try {
    const store=createSupabaseStore({supabaseURL:'https://fixture.invalid',publicKey:'public-fixture',serviceKey:'service-fixture'});
    const events=[];let failures=0;
    const stop=await store.subscribeIncoming(owner,call=>events.push(call),()=>failures++,abort.signal);
    const join=socket.sent[0];assert.equal(join.topic,`realtime:tincall:incoming:${owner}`);assert.equal(join.payload.config.private,true);
    assert.equal(join.payload.access_token,'service-fixture');
    const call={id:crypto.randomUUID(),contact_id:'synthetic',source:'mcp',status:'ringing',epoch:0,last_sequence:1,summary:'must not leave server'};
    socket.message({topic:`realtime:tincall:incoming:${other}`,event:'broadcast',payload:{event:'call_state',payload:{call}}});assert.equal(events.length,0);
    socket.message({topic:join.topic,event:'broadcast',payload:{event:'call_state',payload:{call}}});assert.equal(events.length,1);assert.equal(events[0].summary,undefined);
    abort.abort();assert.equal(socket.closed,true);stop();assert.equal(failures,0);
  }finally{abort.abort();globalThis.WebSocket=original;}
});

test('Supabase private incoming and wake subscriptions retain service authorization with opaque API keys',async()=>{
  const {createSupabaseStore}=await import('../../supabase/functions/_shared/tincall/service.mjs');
  const original=globalThis.WebSocket;
  const serviceKey='sb_secret_synthetic_service_key';
  const publicKey='sb_publishable_synthetic_public_key';
  const sockets=[];
  class Socket extends EventTarget {
    readyState=1;closed=false;
    constructor(url){
      super();
      // The gateway maps an opaque API key to the connection's JWT identity.
      this.gatewayRole=new URL(url).searchParams.get('apikey')===serviceKey?'service_role':'anon';
      sockets.push(this);
      queueMicrotask(()=>this.dispatchEvent(new Event('open')));
    }
    send(value){
      const message=JSON.parse(value);
      if(message.event!=='phx_join')return;
      assert.equal(message.payload.config.private,true);
      assert.equal(message.payload.access_token,serviceKey);
      // Realtime's assign_access_token uses the handshake identity for sb_* keys.
      // A secret in the join body cannot upgrade an anonymous handshake.
      const permitted=this.gatewayRole==='service_role';
      queueMicrotask(()=>this.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({
        topic:message.topic,event:'phx_reply',ref:message.ref,
        payload:permitted?{status:'ok',response:{}}:{status:'error',response:{reason:'You do not have permissions to read from this Channel topic'}},
      })})));
    }
    close(){this.closed=true;}
  }
  globalThis.WebSocket=Socket;
  try {
    const store=createSupabaseStore({supabaseURL:'https://fixture.invalid',publicKey,serviceKey});
    for(const subscribe of ['subscribeIncoming','subscribeWake']){
      const abort=new AbortController();
      try {
        const stop=await store[subscribe](owner,()=>{},()=>assert.fail('Authorized subscription failed'),abort.signal);
        stop();
        assert.equal(sockets.at(-1).closed,true);
      } finally {abort.abort();}
    }
  } finally {globalThis.WebSocket=original;}
});
