import test from 'node:test';
import assert from 'node:assert/strict';
import * as workerModule from '../push-worker.mjs';
import { createConnector } from '../../supabase/functions/_shared/tincall/service.mjs';

const project = 'a'.repeat(20);
const token = `tcpush_${project}_${'b'.repeat(64)}`;
const rotated = `tcpush_${project}_${'c'.repeat(64)}`;
const pushURL = 'https://tincall-push.tincall-app.workers.dev';

function fixture(t) {
  const config = { pushURL, pushToken: token };
  let authCalls = 0, routed = 0, proofCalls = 0, redirect = false, corrupt = false;
  const connector = createConnector({ config, store: {
    authenticate: async () => { authCalls++; throw Error('Push credentials cannot access user data'); }
  } });
  const records = new Map(), services = new Map();
  const env = {
    PUSH_SERVICES: {
      idFromName: name => name,
      get(name) {
        if (!services.has(name)) {
          const data = new Map(); records.set(name, data);
          let queue = Promise.resolve();
          const ctx = {
            storage: { get: async key => data.get(key), put: async (key, value) => { data.set(key, value); } },
            blockConcurrencyWhile(task) { const result = queue.then(task); queue = result.catch(() => {}); return result; }
          };
          services.set(name, new workerModule.PushService(ctx));
        }
        return services.get(name);
      }
    },
    PUSH_REGISTRIES: { idFromName: name => name, get: name => ({ fetch: async () => { routed++; return Response.json({ registry: name }); } }) }
  };
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    proofCalls++;
    assert.equal(String(url), `https://${project}.supabase.co/functions/v1/tincall/push/verify`);
    assert.equal(init.redirect, 'manual');
    if (redirect) return new Response(null, { status: 307, headers: { location: 'https://other.invalid' } });
    if (corrupt) return Response.json({ challenge: 'stale', verified: true });
    return connector.handle(new Request(url, init));
  });
  return {
    config, records, connector,
    post: (path, credential = token, body = {}) => workerModule.default.fetch(new Request(pushURL + path, {
      method: 'POST', headers: { authorization: `Bearer ${credential}`, 'content-type': 'application/json' }, body: JSON.stringify(body)
    }), env),
    get counters() { return { authCalls, routed, proofCalls }; },
    set redirect(value) { redirect = value; }, set corrupt(value) { corrupt = value; }
  };
}

test('a new Supabase project enrolls with a dedicated push credential and keeps its registry on rotation', async t => {
  const f = fixture(t), owner = crypto.randomUUID();
  assert.equal((await f.post('/devices', token, { owner_id: owner })).status, 401);
  assert.equal((await f.post('/services/register')).status, 200);
  const first = await f.post('/devices', token, { owner_id: owner });
  assert.equal(first.status, 200);
  const registry = (await first.json()).registry;
  assert.deepEqual(JSON.parse(registry), [`supabase:${project}`, owner]);
  assert.equal((await f.post('/services/register')).status, 200, 'lost registration response can be retried');
  f.config.pushToken = rotated;
  assert.equal((await f.post('/services/register', rotated)).status, 200);
  assert.equal((await f.post('/devices', token, { owner_id: owner })).status, 401);
  assert.equal((await f.post('/devices', rotated, { owner_id: owner })).status, 200);
  assert.equal(f.counters.proofCalls, 3, 'ordinary push requests authenticate locally without calling Supabase');
  assert.equal(f.counters.authCalls, 0, 'enrollment must never read user data');
});

test('unverified projects, stale proofs and redirects cannot replace a working service credential', async t => {
  const f = fixture(t);
  assert.equal((await f.post('/services/register')).status, 200);
  assert.notEqual((await f.post('/services/register', rotated)).status, 200);
  assert.equal(f.records.get(project).get('credential'), token);
  f.config.pushToken = rotated;
  f.redirect = true;
  assert.notEqual((await f.post('/services/register', rotated)).status, 200);
  f.redirect = false; f.corrupt = true;
  assert.notEqual((await f.post('/services/register', rotated)).status, 200);
  assert.equal(f.records.get(project).get('credential'), token);
  const before = f.counters.proofCalls;
  assert.equal((await f.post('/services/register', 'tcpush_https://other.invalid_secret')).status, 401);
  assert.equal(f.counters.proofCalls, before, 'untrusted input cannot select an arbitrary verification URL');
});

test('push verification is scoped to its credential and cannot authenticate ordinary data routes', async t => {
  const f = fixture(t), challenge = crypto.randomUUID();
  const request = (path, credential, method = 'POST') => new Request(`https://${project}.supabase.co/functions/v1/tincall${path}`, {
    method, headers: { authorization: `Bearer ${credential}`, 'x-tincall-push-challenge': challenge }
  });
  assert.equal((await f.connector.handle(request('/push/verify', 'phone-token'))).status, 403);
  assert.equal((await f.connector.handle(request('/push/verify', token, 'GET'))).status, 405);
  assert.deepEqual(await (await f.connector.handle(request('/push/verify', token))).json(), { verified: true, challenge });
  assert.notEqual((await f.connector.handle(request('/calls', token, 'GET'))).status, 200);
  assert.equal(f.counters.authCalls, 1);
});
