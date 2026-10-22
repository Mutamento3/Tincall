// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import test from 'node:test';
import assert from 'node:assert/strict';
import {copyFileSync,mkdirSync,mkdtempSync,readFileSync,writeFileSync,statSync,rmSync,existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {writeServiceFiles} from '../local-service.mjs';

// Every service manager and launcher is replaced. No real Docker, launchd,
// systemd, nohup, cloudflared, or connector process is started by these tests.
function fixture(t) {
  const directory=mkdtempSync(join(tmpdir(),'tincall-install space-&-'));
  t.after(()=>rmSync(directory,{recursive:true,force:true}));
  const bin=join(directory,'bin');mkdirSync(bin);
  const home=join(directory,'home');mkdirSync(home);
  const script=join(directory,'install-local.sh');
  for(const name of ['install-local.sh','local-service.mjs'])copyFileSync(new URL('../'+name,import.meta.url),join(directory,name));
  const log=join(directory,'commands.log');
  const mock=(name,body)=>writeFileSync(join(bin,name),'#!/bin/sh\nprintf "%s %s\\n" "'+name+'" "$*" >> "$INSTALL_TEST_LOG"\n'+body,{mode:0o700});
  mock('docker',`case "$*" in
  'volume inspect '*) exit 1 ;;
  'compose version') [ "$INSTALL_TEST_DOCKER" != missing ] ;;
  *' up '*) [ "$INSTALL_TEST_FAIL" != up ] ;;
  *' logs '*) echo 'https://offline-fixture.trycloudflare.com' ;;
esac
`);
  mock('node',`case "$*" in
  *process.versions.node*)
    case "$INSTALL_TEST_NODE:$1" in plain:*) exit 0;; flag:--experimental-sqlite) exit 0;; *) exit 1;; esac ;;
  '-p process.execPath') printf '%s/node\\n' "$INSTALL_TEST_BIN" ;;
  *'local-service.mjs check '*) exit 0 ;;
  *) exec "$INSTALL_TEST_REAL_NODE" "$@" ;;
esac
`);
  mock('uname','echo "$INSTALL_TEST_OS"\n');
  mock('launchctl',`case "$*" in *bootstrap*tunnel.plist*) echo 'https://native-fixture.trycloudflare.com' >> "$INSTALL_TEST_DIRECTORY/.local/tunnel.log";; esac
`);
  mock('systemctl',`case "$*" in
  *show-environment*) [ "$INSTALL_TEST_MANAGER" != nohup ] ;;
  *'enable --now tincall-tunnel.service'*) echo 'https://native-fixture.trycloudflare.com' >> "$INSTALL_TEST_DIRECTORY/.local/tunnel.log" ;;
esac
`);
  mock('loginctl','exit 0\n');
  mock('nohup','exit 0\n');
  mock('cloudflared','exit 0\n');
  const run=(args=[],extra={})=>spawnSync('/bin/sh',[script,...args],{cwd:tmpdir(),encoding:'utf8',env:{...process.env,
    HOME:home,PATH:`${bin}:/usr/bin:/bin`,TINCALL_LOCAL_PORT:'',INSTALL_TEST_LOG:log,
    INSTALL_TEST_BIN:bin,INSTALL_TEST_DIRECTORY:directory,INSTALL_TEST_REAL_NODE:process.execPath,
    INSTALL_TEST_OS:'Darwin',INSTALL_TEST_NODE:'plain',...extra}});
  const envFile=join(directory,'.local/local.env');
  return {directory,home,bin,run,envFile,commands:()=>existsSync(log)?readFileSync(log,'utf8'):''};
}
function savedCredentials(f) {
  const saved=readFileSync(f.envFile,'utf8');
  const env=Object.fromEntries(saved.trim().split('\n').map(line=>{const i=line.indexOf('=');return [line.slice(0,i),line.slice(i+1)];}));
  assert.equal(statSync(f.envFile).mode & 0o777,0o600);
  assert.equal(statSync(join(f.directory,'.local')).mode & 0o777,0o700);
  assert.match(env.TINCALL_LOCAL_PHONE_TOKEN,/^[0-9a-f]{64}$/);
  assert.match(env.TINCALL_WORKER_TOKEN,/^[0-9a-f]{64}$/);
  assert.notEqual(env.TINCALL_LOCAL_PHONE_TOKEN,env.TINCALL_WORKER_TOKEN);
  const [client]=JSON.parse(env.TINCALL_CLIENTS);
  assert.equal(client.token,env.TINCALL_LOCAL_PHONE_TOKEN);
  assert.match(client.owner_id,/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-8[0-9a-f]{3}-[0-9a-f]{12}$/);
  return saved;
}

test('Node is preferred, launchd definitions are valid, updates and stop preserve credentials and data',t=>{
  const f=fixture(t);
  const first=f.run();assert.equal(first.status,0,first.stderr);
  const saved=savedCredentials(f);
  const data=join(f.directory,'.local/data');mkdirSync(data);
  writeFileSync(join(data,'retained.txt'),'synthetic retained data');
  const tunnel=f.run(['--node','--tunnel']);assert.equal(tunnel.status,0,tunnel.stderr);
  assert.match(tunnel.stdout,/https:\/\/native-fixture.trycloudflare.com/);
  for(const name of ['connector','tunnel']) {
    const plist=join(f.directory,'.local',name+'.plist');
    if(process.platform==='darwin') {
      const checked=spawnSync('plutil',['-lint',plist],{encoding:'utf8'});
      assert.equal(checked.status,0,checked.stdout+checked.stderr);
    }
    const content=readFileSync(plist,'utf8');
    assert.ok(content.includes('&amp;'));
    assert.ok(content.includes('KeepAlive'));
  }
  const local=f.run([],{TINCALL_LOCAL_PORT:'9797'});assert.equal(local.status,0,local.stderr);
  assert.match(local.stdout,/http:\/\/127.0.0.1:9797/);
  const stop=f.run(['--stop']);assert.equal(stop.status,0,stop.stderr);
  assert.equal(existsSync(join(f.home,'Library/LaunchAgents/com.tincall.connector.plist')),false);
  assert.equal(existsSync(join(f.home,'Library/LaunchAgents/com.tincall.tunnel.plist')),false);
  assert.equal(readFileSync(f.envFile,'utf8'),saved);
  assert.equal(readFileSync(join(data,'retained.txt'),'utf8'),'synthetic retained data');
  assert.match(f.commands(),/launchctl bootout/);
  assert.doesNotMatch(f.commands(),/docker .*\b(up|pull|build|info)\b/);
});

test('older Node probe retains the experimental SQLite flag in its service',t=>{
  const f=fixture(t);
  const result=f.run(['--node'],{INSTALL_TEST_NODE:'flag'});assert.equal(result.status,0,result.stderr);
  assert.match(readFileSync(join(f.directory,'.local/connector.plist'),'utf8'),/--experimental-sqlite/);
});

test('Linux systemd user services are enabled and removed; unavailable user manager uses nohup',t=>{
  const f=fixture(t);
  let result=f.run(['--node','--tunnel'],{INSTALL_TEST_OS:'Linux'});
  assert.equal(result.status,0,result.stderr);
  const saved=savedCredentials(f);
  assert.match(result.stdout,/https:\/\/native-fixture.trycloudflare.com/);
  assert.equal(f.run(['--stop'],{INSTALL_TEST_OS:'Linux'}).status,0);
  assert.equal(existsSync(join(f.home,'.config/systemd/user/tincall-connector.service')),false);
  assert.equal(existsSync(join(f.home,'.config/systemd/user/tincall-tunnel.service')),false);
  assert.match(f.commands(),/systemctl --user disable --now tincall-connector.service/);
  assert.match(f.commands(),/loginctl enable-linger/);
  result=f.run(['--node'],{INSTALL_TEST_OS:'Linux',INSTALL_TEST_MANAGER:'nohup'});
  assert.equal(result.status,0,result.stderr);assert.match(result.stdout,/nohup/);
  assert.equal(readFileSync(f.envFile,'utf8'),saved);
  assert.equal(f.run(['--stop'],{INSTALL_TEST_OS:'Linux'}).status,0);
  assert.match(f.commands(),/nohup .*local-service.mjs serve/);
});

test('Docker is a fallback and can be forced; updates, tunnel and stop retain credentials',t=>{
  const f=fixture(t);
  const first=f.run([],{INSTALL_TEST_NODE:'missing'});assert.equal(first.status,0,first.stderr);
  const saved=savedCredentials(f);
  const tunnel=f.run(['--docker','--tunnel']);assert.equal(tunnel.status,0,tunnel.stderr);
  assert.match(tunnel.stdout,/https:\/\/offline-fixture.trycloudflare.com/);
  assert.equal(f.run(['--stop']).status,0);
  assert.equal(readFileSync(f.envFile,'utf8'),saved);
  assert.match(f.commands(),/--profile tunnel up -d --build --force-recreate --wait/);
  assert.doesNotMatch(f.commands(),/\b(down|pull|volume rm)\b/);
  const switchMode=f.run(['--node']);assert.notEqual(switchMode.status,0);
  assert.match(switchMode.stderr,/迁移/);
});

test('failed Docker startup keeps generated credentials for retry',t=>{
  const f=fixture(t);
  const failed=f.run(['--docker'],{INSTALL_TEST_FAIL:'up'});assert.notEqual(failed.status,0);
  const saved=readFileSync(f.envFile,'utf8');
  assert.equal(f.run(['--docker']).status,0);
  assert.equal(readFileSync(f.envFile,'utf8'),saved);
});

test('missing cloudflared skips the native tunnel without installing anything',t=>{
  const f=fixture(t);rmSync(join(f.bin,'cloudflared'));
  const result=f.run(['--node','--tunnel']);assert.equal(result.status,0,result.stderr);
  assert.match(result.stdout,/已跳过隧道/);
  assert.equal(existsSync(join(f.home,'Library/LaunchAgents/com.tincall.tunnel.plist')),false);
});

test('missing runtimes, invalid options, and stopping a fresh install do not generate credentials',t=>{
  const f=fixture(t);
  const noRuntime=f.run([],{INSTALL_TEST_NODE:'missing',INSTALL_TEST_DOCKER:'missing'});
  assert.notEqual(noRuntime.status,0);assert.match(noRuntime.stderr,/https:\/\/nodejs.org\//);
  assert.notEqual(f.run(['--node'],{INSTALL_TEST_NODE:'missing'}).status,0);
  assert.equal(f.run(['--unknown']).status,2);
  assert.equal(f.run(['--node','--docker']).status,2);
  assert.equal(f.run(['--stop','--tunnel']).status,2);
  assert.equal(f.run(['--stop']).status,0);
  assert.equal(existsSync(f.envFile),false);
});

test('systemd rendering escapes specifiers and dollar expansion in executable paths',t=>{
  const f=fixture(t);
  writeServiceFiles({manager:'systemd',directory:f.directory,port:8787,nodeBinary:'/a space/%/$/node'});
  const unit=readFileSync(join(f.directory,'tincall-connector.service'),'utf8');
  assert.match(unit,/ExecStart="\/a space\/%%\/\$\$\/node"/);
});

test('stop leaves an unrelated process alive when a stale pid has been reused',t=>{
  const f=fixture(t);
  assert.equal(f.run(['--node']).status,0);
  writeFileSync(join(f.directory,'.local/serve.pid'),String(process.pid)+'\n');
  const stopped=f.run(['--stop']);assert.equal(stopped.status,0,stopped.stderr);
  assert.match(stopped.stderr,/未终止该进程/);
  assert.equal(existsSync(join(f.directory,'.local/serve.pid')),false);
});
