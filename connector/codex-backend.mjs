import {createServer} from 'node:http';
import {spawn} from 'node:child_process';
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

// A local text/voice adapter. Codex credentials stay in its existing auth provider.
// Conversations arrive from the connector; no desktop sessions are read or resumed.
export function createCodexBackend({command, args, cwd, token, timeoutMS = 75000}) {
  if (!command || !Array.isArray(args) || !cwd || !token) throw new Error('backend_config_invalid');
  const jobs = new Map();
  const uuid = /^[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}$/i;
  const failure = (code, status = 502) => ({status, body: {error: {code}}});
  const send = (res, result) => {
    if (res.destroyed || res.writableEnded) return;
    res.writeHead(result.status, {'Content-Type': 'application/json', 'Cache-Control': 'no-store'});
    res.end(JSON.stringify(result.body));
  };
  function remember(id, job) {
    for (const [key, previous] of jobs) {
      if (previous.finished && Date.now() - previous.created > 600000) jobs.delete(key);
    }
    if (jobs.size >= 128) {
      const oldest = [...jobs].find(([, value]) => value.finished);
      if (oldest) jobs.delete(oldest[0]);
    }
    jobs.set(id, job);
    return job;
  }
  function stop(job, reason = 'generation_cancelled') {
    if (job.finished) return job.done;
    job.reason ??= reason;
    try { process.kill(-job.child.pid, 'SIGTERM'); } catch (error) {
      if (error.code !== 'ESRCH') job.child.kill('SIGTERM');
    }
    if (!job.killTimer) {
      job.killTimer = setTimeout(() => {
        try { process.kill(-job.child.pid, 'SIGKILL'); } catch (error) {
          if (error.code !== 'ESRCH') job.child.kill('SIGKILL');
        }
      }, 1500);
      job.killTimer.unref();
    }
    return job.done;
  }
  function start(body) {
    const job = remember(body.job_id, {call: body.call_id, epoch: body.epoch,
      input: JSON.stringify(body), created: Date.now(), finished: false, clients: 0});
    const child = job.child = spawn(command, ['exec', ...args, '--cd', cwd, '-'], {
      cwd, detached: true, stdio: ['pipe', 'pipe', 'ignore'],
    });
    child.stdout.setEncoding('utf8');
    job.done = new Promise(resolveDone => {
      let buffer = '', text = '', completed = false, bytes = 0;
      const timer = setTimeout(() => stop(job, 'generation_timeout'), timeoutMS);
      function finish(code) {
        if (job.finished) return;
        job.finished = true;
        clearTimeout(timer); clearTimeout(job.killTimer);
        const result = job.reason ? failure(job.reason) : code === 0 && completed && text.trim()
          ? {status: 200, body: {text}} : failure('codex_generation_failed');
        resolveDone(result);
      }
      child.on('error', () => { job.reason = 'codex_start_failed'; finish(1); });
      child.on('close', finish);
      child.stdin.on('error', () => { stop(job, 'codex_input_failed'); });
      child.stdout.on('data', chunk => {
        bytes += Buffer.byteLength(chunk);
        if (bytes > 2 * 1024 * 1024) { stop(job, 'codex_output_too_large'); return; }
        buffer += chunk;
        let end;
        while ((end = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
          if (!line.trim()) continue;
          try {
            const event = JSON.parse(line);
            if (event.type === 'item.completed' && event.item?.type === 'agent_message') {
              if (typeof event.item.text !== 'string' || event.item.text.length > 100000) {
                stop(job, 'codex_invalid_output'); return;
              }
              text = event.item.text;
            }
            if (event.type === 'turn.completed') completed = true;
            if (event.type === 'turn.failed' || event.type === 'error') job.reason = 'codex_generation_failed';
          } catch { stop(job, 'codex_invalid_output'); }
        }
      });
    });
    child.stdin.end(JSON.stringify({expression_prompt: body.expression_prompt ?? '', messages: body.messages}));
    return job;
  }
  const server = createServer(async (req, res) => {
    if (req.headers.authorization !== `Bearer ${token}`) { send(res, failure('unauthorized', 401)); return; }
    if (req.method === 'GET' && req.url === '/health') { send(res, {status: 200, body: {ready: true}}); return; }
    if (req.method !== 'POST' || !['/generate', '/cancel'].includes(req.url)) {
      send(res, failure('not_found', 404)); return;
    }
    try {
      let raw = '', bytes = 0;
      req.setEncoding('utf8');
      for await (const chunk of req) {
        bytes += Buffer.byteLength(chunk);
        if (bytes > 1024 * 1024) { send(res, failure('request_too_large', 413)); return; }
        raw += chunk;
      }
      let body;
      try { body = JSON.parse(raw); } catch { send(res, failure('invalid_json', 400)); return; }
      if (!body || !uuid.test(body.job_id) || !uuid.test(body.call_id) || !Number.isSafeInteger(body.epoch) || body.epoch < 0) {
        send(res, failure('invalid_job', 422)); return;
      }
      let job = jobs.get(body.job_id);
      if (job && (job.call !== body.call_id || job.epoch !== body.epoch)) {
        send(res, failure('job_identity_conflict', 409)); return;
      }
      if (req.url === '/cancel') {
        if (job) await stop(job);
        else remember(body.job_id, {call: body.call_id, epoch: body.epoch, created: Date.now(), finished: true,
          done: Promise.resolve(failure('generation_cancelled', 409))});
        send(res, {status: 200, body: {cancelled: true}}); return;
      }
      if (req.headers['idempotency-key'] !== body.job_id) { send(res, failure('invalid_idempotency_key', 422)); return; }
      if (body.version !== 1 || !Array.isArray(body.messages) || !body.messages.length ||
          body.messages.some(message => !message || !['user', 'assistant'].includes(message.role) || typeof message.text !== 'string') ||
          (body.expression_prompt !== undefined && typeof body.expression_prompt !== 'string')) {
        send(res, failure('invalid_messages', 422)); return;
      }
      if (body.messages.some(message => message.images?.length)) { send(res, failure('images_not_supported', 422)); return; }
      if (job?.input && job.input !== JSON.stringify(body)) { send(res, failure('job_input_conflict', 409)); return; }
      if (!job && [...jobs.values()].filter(value => !value.finished).length >= 4) {
        send(res, failure('backend_busy', 429)); return;
      }
      job ??= start(body);
      job.clients++;
      res.once('close', () => {
        job.clients--;
        if (!res.writableEnded && !job.finished && job.clients === 0) void stop(job);
      });
      send(res, await job.done);
    } catch { send(res, failure('backend_request_failed')); }
  });
  server.requestTimeout = 15000;
  return {
    server,
    async close() {
      await Promise.all([...jobs.values()].filter(job => !job.finished).map(job => stop(job)));
      await new Promise(resolveClose => server.close(resolveClose));
    },
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.umask(0o077);
  try {
    const config = JSON.parse(readFileSync(process.argv[2], 'utf8'));
    const backend = createCodexBackend(config);
    backend.server.listen(config.port ?? 8788, '127.0.0.1', () => console.log('tincall_codex_backend_ready'));
    for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => void backend.close());
  } catch { console.error('tincall_codex_backend_start_failed'); process.exitCode = 1; }
}
