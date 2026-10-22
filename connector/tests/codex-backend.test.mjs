// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createCodexBackend} from '../codex-backend.mjs';

async function fixture(t, {timeoutMS = 5000} = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'tincall-codex-check-'));
  const command = join(directory, 'codex');
  writeFileSync(command, `#!${process.execPath}
const fs=require('node:fs');
fs.appendFileSync('starts', String(process.pid)+'\\n');
let input='';process.stdin.on('data',chunk=>input+=chunk);process.stdin.on('end',()=>{
  const body=JSON.parse(input);
  if(body.messages.at(-1).text==='wait'){setInterval(()=>{},1000);return;}
  if(body.messages.at(-1).text==='fail'){process.stderr.write('private upstream error');process.exit(1);}
  const text=body.expression_prompt+'：'+body.messages.map(m=>m.text).join('、');
  const output=Buffer.from(JSON.stringify({type:'item.completed',item:{type:'agent_message',text}})+'\\n'+JSON.stringify({type:'turn.completed'})+'\\n');
  // Force UTF-8 code points across stream chunks.
  let i=0;const timer=setInterval(()=>{if(i<output.length)process.stdout.write(output.subarray(i,i+=2));else clearInterval(timer);},1);
});
`, {mode: 0o700});
  const backend = createCodexBackend({command, args: [], cwd: directory, token: 'fixture-only', timeoutMS});
  await new Promise(resolve => backend.server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await backend.close(); rmSync(directory, {recursive: true, force: true}); });
  const endpoint = `http://127.0.0.1:${backend.server.address().port}`;
  async function request(path, body, token = 'fixture-only', signal) {
    const response = await fetch(endpoint + path, {method: 'POST', headers: {
      Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'Idempotency-Key': body.job_id,
    }, body: JSON.stringify(body), signal});
    return {status: response.status, body: await response.json()};
  }
  const body = (text = '你好') => ({version: 1, job_id: crypto.randomUUID(), call_id: crypto.randomUUID(), epoch: 1,
    expression_prompt: '简短中文', messages: [{role: 'user', text}]});
  async function started(count = 1) {
    const file = join(directory, 'starts');
    for (let n = 0; n < 100; n++) {
      if (existsSync(file)) {
        const pids = readFileSync(file, 'utf8').trim().split('\n').map(Number);
        if (pids.length >= count) return pids;
      }
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    assert.fail('process did not start');
  }
  return {request, body, started, directory};
}

test('Codex adapter authenticates, carries conversation/expression, preserves Chinese and deduplicates jobs', async t => {
  const f = await fixture(t);
  const body = f.body();
  body.messages.push({role: 'assistant', text: '你好呀'}, {role: 'user', text: '继续'});
  assert.equal((await f.request('/generate', body, 'wrong')).status, 401);
  assert.equal(existsSync(join(f.directory, 'starts')), false);
  const first = await f.request('/generate', body);
  assert.deepEqual(first, {status: 200, body: {text: '简短中文：你好、你好呀、继续'}});
  assert.deepEqual(await f.request('/generate', body), first);
  assert.equal((await f.started()).length, 1);
  assert.equal((await f.request('/generate', {...body, messages: [{role: 'user', text: 'changed'}]})).status, 409);
});

test('Codex cancellation waits for process exit and rejects cancelled or conflicting jobs', async t => {
  const f = await fixture(t);
  const body = f.body('wait');
  const generation = f.request('/generate', body);
  const [pid] = await f.started();
  assert.equal((await f.request('/cancel', {...body, epoch: 2})).status, 409);
  assert.equal((await f.request('/cancel', body)).status, 200);
  assert.throws(() => process.kill(pid, 0), {code: 'ESRCH'});
  assert.equal((await generation).body.error.code, 'generation_cancelled');
  const early = f.body();
  assert.equal((await f.request('/cancel', early)).status, 200);
  assert.equal((await f.request('/generate', early)).body.error.code, 'generation_cancelled');
  assert.equal((await f.started()).length, 1);
});

test('Codex disconnect and timeout stop the child; provider errors never return stderr or a fake reply', async t => {
  const f = await fixture(t, {timeoutMS: 600});
  const controller = new AbortController();
  const pending = f.request('/generate', f.body('wait'), 'fixture-only', controller.signal).catch(() => null);
  const [pid] = await f.started();
  controller.abort(); await pending;
  let alive = true;
  for (let n = 0; n < 100 && alive; n++) {
    try { process.kill(pid, 0); await new Promise(resolve => setTimeout(resolve, 10)); }
    catch (error) { assert.equal(error.code, 'ESRCH'); alive = false; }
  }
  assert.equal(alive, false);
  assert.equal((await f.request('/generate', f.body('wait'))).body.error.code, 'generation_timeout');
  assert.deepEqual(await f.request('/generate', f.body('fail')), {status: 502, body: {error: {code: 'codex_generation_failed'}}});
});
