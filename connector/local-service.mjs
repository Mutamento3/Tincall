import {readFileSync,writeFileSync,unlinkSync} from 'node:fs';
import {join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {parseEnv} from 'node:util';
import {spawn} from 'node:child_process';

const entry=fileURLToPath(import.meta.url);
const xml=value=>String(value).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'",'&apos;');
const unitQuote=value=>'"'+String(value).replaceAll('\\','\\\\').replaceAll('"','\\"').replaceAll('%','%%').replaceAll('$',()=>'$$').replaceAll('\n','\\n').replaceAll('\r','\\r')+'"';

// Only writes definitions. Loading/enabling them belongs to install-local.sh.
export function writeServiceFiles({manager,directory,port,nodeBinary=process.execPath,sqliteFlag='',cloudflared=''}) {
  for(const kind of ['serve',...(cloudflared?['tunnel']:[])]) {
    const name=kind==='serve'?'connector':'tunnel';
    const args=[nodeBinary,...(sqliteFlag?[sqliteFlag]:[]),entry,kind,directory,String(port),...(kind==='tunnel'?[cloudflared]:[])];
    if(manager==='launchd') {
      writeFileSync(join(directory,`${name}.plist`),`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.tincall.${name}</string>
<key>ProgramArguments</key><array>${args.map(arg=>`<string>${xml(arg)}</string>`).join('')}</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>5</integer>
<key>StandardOutPath</key><string>${xml(join(directory,`${name}.log`))}</string>
<key>StandardErrorPath</key><string>${xml(join(directory,`${name}.log`))}</string>
<key>Umask</key><integer>63</integer>
</dict></plist>
`,{mode:0o600});
    } else if(manager==='systemd') {
      // The wrapper inherits stdout/stderr; append both to a private log.
      writeFileSync(join(directory,`tincall-${name}.service`),`[Unit]
Description=Tincall ${name}
[Service]
ExecStart=${args.map(unitQuote).join(' ')}
Restart=on-failure
RestartSec=5
UMask=0077
StandardOutput=append:${join(directory,`${name}.log`).replaceAll('%','%%')}
StandardError=inherit
[Install]
WantedBy=default.target
`,{mode:0o600});
    } else throw new Error('unsupported_service_manager');
  }
}

function credentials(directory) {
  return parseEnv(readFileSync(join(directory,'local.env'),'utf8'));
}
function track(directory,kind) {
  const path=join(directory,kind+'.pid');
  writeFileSync(path,String(process.pid)+'\n',{mode:0o600});
  process.on('exit',()=>{
    try{if(readFileSync(path,'utf8').trim()===String(process.pid))unlinkSync(path);}catch(error){if(error.code!=='ENOENT')process.stderr.write('tincall_pid_cleanup_failed\n');}
  });
}
async function main([action,directory,port,option,cloudflared]) {
  if(action==='render') {
    writeServiceFiles({manager:option,directory,port,sqliteFlag:process.env.TINCALL_SQLITE_FLAG||'',cloudflared:cloudflared||''});
  } else if(action==='check') {
    const env=credentials(directory);
    const [client]=JSON.parse(env.TINCALL_CLIENTS);
    const response=await fetch(`http://127.0.0.1:${port}/capabilities`,{headers:{Authorization:`Bearer ${client.token}`},signal:AbortSignal.timeout(2000)});
    if(!response.ok)throw new Error('connector_not_ready');
    await response.body?.cancel();
  } else if(action==='serve') {
    process.umask(0o077);
    Object.assign(process.env,credentials(directory),{HOST:'127.0.0.1',PORT:String(port),TINCALL_STORAGE:'sqlite',TINCALL_SQLITE_PATH:join(directory,'data','tincall.sqlite')});
    track(directory,'serve');
    await import('./server.mjs');
  } else if(action==='tunnel') {
    process.umask(0o077);
    const child=spawn(option,['tunnel','--no-autoupdate','--protocol','http2','--url',`http://127.0.0.1:${port}`],{stdio:'inherit'});
    track(directory,'tunnel');
    let stopping=false;
    for(const signal of ['SIGTERM','SIGINT'])process.on(signal,()=>{
      stopping=true;child.kill(signal);
      const timer=setTimeout(()=>child.kill('SIGKILL'),10000);timer.unref();
      child.once('exit',()=>clearTimeout(timer));
    });
    child.on('error',()=>{process.stderr.write('tincall_tunnel_start_failed\n');process.exitCode=1;});
    child.on('exit',code=>{process.exitCode=stopping?0:(code||1);});
  } else throw new Error('invalid_local_service_command');
}
if(process.argv[1] && resolve(process.argv[1])===entry) {
  main(process.argv.slice(2)).catch(()=>{process.stderr.write('tincall_local_service_failed\n');process.exitCode=1;});
}
