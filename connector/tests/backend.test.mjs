// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import test, {before, after} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createServer} from 'node:http';
import {createSQLiteStore} from '../sqlite-store.mjs';
import {createConnector} from '../../supabase/functions/_shared/tincall/service.mjs';

const directory = mkdtempSync(join(tmpdir(), 'tincall-backend-check-'));
const owner = crypto.randomUUID();
const store = createSQLiteStore({clients:[{token:'synthetic-owner',owner_id:owner}]}, join(directory, 'checks.sqlite'));
const tasks = [];
let connector, bindings, upstream, generated, hold = false, cancelFailures = 0, cancellations = [];
before(async () => {
  upstream = createServer(async (req, res) => {
    let body = ''; for await (const chunk of req) body += chunk;
    const payload = JSON.parse(body);
    if (req.url === '/cancel') {
      cancellations.push(payload);
      res.writeHead(cancelFailures-- > 0 ? 503 : 200, {'Content-Type':'application/json'});
      res.end('{}'); return;
    }
    generated = payload;
    if (hold) {
      res.writeHead(200, {'Content-Type':'application/x-ndjson'});
      res.write('{"type":"delta","delta":"synthetic partial"}\n');
    } else {
      res.writeHead(200, {'Content-Type':'application/json'});
      res.end('{"text":"synthetic reply"}');
    }
  });
  await new Promise(resolve => upstream.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${upstream.address().port}`;
  bindings = [
    {owner_id:owner,contact_id:'valid',mode:'http',generation_url:base+'/generate',cancel_url:base+'/cancel',allow_local_http:true},
    {owner_id:owner,contact_id:'missing-cancel',mode:'http',generation_url:base+'/generate',allow_local_http:true},
    {owner_id:owner,contact_id:'wrong-origin',mode:'http',generation_url:base+'/generate',cancel_url:'https://other.invalid/cancel',allow_local_http:true},
    {owner_id:owner,contact_id:'malformed-url',mode:'http',generation_url:'invalid URL',cancel_url:'invalid URL'},
  ];
  connector = createConnector({store, schedule:task => tasks.push(task), config:{bindings}});
});
after(async () => {
  await Promise.allSettled(tasks); upstream.closeAllConnections();
  await new Promise(resolve => upstream.close(resolve)); store.close(); rmSync(directory, {recursive:true,force:true});
});
async function api(path, body) {
  const response = await connector.handle(new Request('http://localhost'+path, {method:body === undefined ? 'GET' : 'POST',
    headers:{Authorization:'Bearer synthetic-owner','Content-Type':'application/json'}, ...(body === undefined ? {} : {body:JSON.stringify(body)})}));
  return {status:response.status,body:await response.json()};
}
const mutation = body => ({request_id:crypto.randomUUID(),...body});
async function end(callID, epoch) { await api(`/calls/${callID}/end`, mutation({epoch,reason:'hangup'})); }

test('backend rejects a retained MCP identity before creating a call or input', async () => {
  const role = crypto.randomUUID();
  await api('/mcp/roles/upsert', {role_id:role,contact_id:'old-mcp',display_name:'Synthetic'});
  await api('/mcp/roles/mode', {role_id:role,call_mode:'backend'});
  const id = crypto.randomUUID();
  const result = await api('/calls', mutation({call_id:id,contact_id:'old-mcp',source:'backend'}));
  try {
    assert.equal(result.status,422);
    assert.equal(result.body.error.code,'backend_binding_required');
    assert.equal((await api('/calls/current')).body.call,null);
  } finally { if (result.status === 200) await end(id,0); }
  // A call created by an older service must not accept another tools input.
  const legacy = crypto.randomUUID();
  await store.command(owner,'call.create',mutation({call_id:legacy,contact_id:'old-mcp',source:'backend'}));
  try {
    const input = await api(`/calls/${legacy}/input`,mutation({message_id:crypto.randomUUID(),epoch:0,text:'synthetic input'}));
    assert.equal(input.status,422);
    assert.equal(input.body.error.code,'backend_binding_required');
    assert.deepEqual((await api(`/calls/${legacy}/record`)).body.messages,[]);
  } finally { await end(legacy,0); }
  // An explicit HTTP adapter takes precedence over the same enrolled MCP identity.
  bindings.push({...bindings[0],contact_id:'old-mcp'});
  const configured = crypto.randomUUID();
  try {
    const directory = (await api('/capabilities')).body;
    assert.equal(directory.bindings.find(item => item.contact_id === 'old-mcp').mode,'http');
    assert.equal((await api('/calls',mutation({call_id:configured,contact_id:'old-mcp',source:'backend'}))).status,200);
    assert.equal((await api(`/calls/${configured}/input`,mutation({message_id:crypto.randomUUID(),epoch:0,text:'synthetic input'}))).status,200);
    await Promise.all(tasks);
    assert.equal(generated.contact_id,'old-mcp');
  } finally { await end(configured,1); bindings.pop(); }
});

test('backend directory advertises only adapters that pass call validation', async () => {
  const result = await api('/capabilities');
  assert.equal(result.status,200);
  for (const contact of ['valid','missing-cancel','wrong-origin','malformed-url']) {
    const binding = result.body.bindings.find(item => item.contact_id === contact);
    assert.equal(binding.generation_configured,contact === 'valid',contact);
    assert.equal(binding.wake_supported,contact === 'valid',contact);
  }
});

test('backend generation forwards the saved speech expression prompt', async () => {
  const id = crypto.randomUUID();
  await api('/calls',mutation({call_id:id,contact_id:'valid',source:'backend',expression_prompt:'SYNTHETIC_VOICE_RULE'}));
  try {
    await api(`/calls/${id}/input`,mutation({message_id:crypto.randomUUID(),epoch:0,text:'synthetic input'}));
    await Promise.all(tasks);
    assert.equal(generated.expression_prompt,'SYNTHETIC_VOICE_RULE');
  } finally { await end(id,1); }
});

for (const failureCount of [2,Infinity]) test(`backend cancellation retries and reports ${failureCount === 2 ? 'recovery' : 'final failure'}`, async () => {
  const id = crypto.randomUUID();
  hold = true; cancelFailures = failureCount; cancellations = [];
  await api('/calls',mutation({call_id:id,contact_id:'valid',source:'backend'}));
  await api(`/calls/${id}/input`,mutation({message_id:crypto.randomUUID(),epoch:0,text:'synthetic pending input'}));
  try {
    for (let i=0;i<100;i++) {
      if ((await api(`/calls/${id}/record`)).body.messages.at(-1).text) break;
      await new Promise(resolve => setTimeout(resolve,20));
    }
    const action = failureCount === 2 ? 'interrupt' : 'end';
    assert.equal((await api(`/calls/${id}/${action}`,mutation({epoch:1,reason:action === 'end' ? 'hangup' : 'interrupted'}))).status,200);
    await Promise.all(tasks);
    assert.equal(cancellations.length,3);
    assert.ok(cancellations.every(value => value.job_id === cancellations[0].job_id && value.epoch === 1));
    const events = (await api(`/calls/${id}/events`)).body.events.filter(event => event.type === 'generation.cancel_result');
    assert.equal(events.length,1);
    assert.equal(events[0].payload.code,failureCount === 2 ? 'cancel_accepted' : 'cancel_delivery_failed');
  } finally { hold = false; await end(id,2); }
});
