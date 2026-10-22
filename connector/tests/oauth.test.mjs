import test,{before,after} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync,mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {DatabaseSync} from 'node:sqlite';
import {createSQLiteStore} from '../sqlite-store.mjs';
import {createConnector,createSupabaseStore} from '../../supabase/functions/_shared/tincall/service.mjs';

const postgres=process.env.TINCALL_TEST_STORAGE==='postgres';
const owner='10000000-0000-4000-8000-000000000001';
const directory=mkdtempSync(join(tmpdir(),'tincall-oauth-'));
const container='tincall-oauth-test-'+process.pid;
const base='https://fixture.invalid/functions/v1/tincall';
const callback='https://chatgpt.com/connector_platform_oauth_redirect';
// RFC 7636's published example verifies the protocol proof without test-only
// production paths, external providers or file fingerprinting.
const verifier='dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
const challenge='E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
const clients=[{token:'phone',owner_id:owner},{token:'contact',owner_id:owner,contact_id:'contact-a'}];
let store,connector,db;
const quote=v=>"'"+String(v).replaceAll("'","''")+"'";
function sql(source){return execFileSync('docker',['exec','-i',container,'psql','-h','127.0.0.1','-X','-q','-A','-t','-v','ON_ERROR_STOP=1','-U','postgres'],{input:source,encoding:'utf8',stdio:'pipe'}).trim();}
async function request(path,{method='GET',token,json,form}={}){
  const headers={Accept:'application/json, text/event-stream',...(token?{Authorization:'Bearer '+token}:{}),...(json?{'Content-Type':'application/json'}:{}),...(form?{'Content-Type':'application/x-www-form-urlencoded'}:{})};
  return connector.handle(new Request(path.startsWith('https:')?path:base+path,{method,headers,...(json?{body:JSON.stringify(json)}:{}),...(form?{body:new URLSearchParams(form)}:{})}));
}
const post=(path,json,token)=>request(path,{method:'POST',json,token});
async function register(overrides={}){
  const result=await post('/oauth/register',{redirect_uris:[callback],client_name:'ChatGPT',token_endpoint_auth_method:'none',...overrides});assert.equal(result.status,201);return (await result.json()).client_id;
}
async function pending(client=undefined,overrides={}){
  client??=await register();
  const query=new URLSearchParams({client_id:client,redirect_uri:callback,response_type:'code',state:'synthetic-state',resource:base+'/mcp',scope:'tincall:mcp',code_challenge:challenge,code_challenge_method:'S256',...overrides});
  const response=await request('/oauth/authorize?'+query);assert.equal(response.status,303);
  const location=response.headers.get('location');
  const page=await request(location);assert.equal(page.status,200);assert.match(page.headers.get('content-type'),/text\/plain/);
  const text=await page.text();const code=text.match(/[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}/)[0];
  return {client,code,location};
}
async function approve(p,decision='approve',contact='contact-a'){
  const result=await post('/oauth/requests/decide',{user_code:p.code,contact_id:contact,decision},'phone');assert.equal(result.status,200);
  const consent=await request(p.location);assert.equal(consent.status,303);
  return new URL(consent.headers.get('location'));
}
async function exchange(p,authorization,overrides={}){
  return request('/oauth/token',{method:'POST',form:{grant_type:'authorization_code',client_id:p.client,code:authorization.searchParams.get('code'),redirect_uri:callback,resource:base+'/mcp',code_verifier:verifier,...overrides}});
}
function expire(table,column,where,value){
  if(postgres)sql(`update public.tincall_${table} set ${column}=now()-interval '1 second' where ${where}=${quote(value)};`);
  else db.prepare(`UPDATE tincall_${table} SET ${column}=? WHERE ${where}=?`).run('2000-01-01T00:00:00.000Z',value);
}
before(async()=>{
  if(postgres){
    execFileSync('docker',['run','--rm','-d','--name',container,'-e','POSTGRES_HOST_AUTH_METHOD=trust','postgres:18-alpine'],{stdio:'pipe'});
    let ready=false;for(let i=0;i<60;i++){try{sql('select 1');ready=true;break;}catch{await new Promise(r=>setTimeout(r,100));}}assert.ok(ready);
    sql(readFileSync(new URL('./bootstrap.sql',import.meta.url),'utf8'));
    for(const file of ['202610110001_tincall_connector.sql','202610140001_tincall_mcp_roles.sql','202610200003_tincall_mcp_oauth.sql','202610200004_tincall_call_presence.sql'])sql(readFileSync(new URL('../../supabase/migrations/'+file,import.meta.url),'utf8'));
    store=createSupabaseStore({supabaseURL:'https://local-database.invalid',serviceKey:'fixture',publicKey:'fixture',clients},async(url,init)=>{
      const p=JSON.parse(init.body);let call;
      if(url.endsWith('/tincall_oauth'))call=`tincall_oauth(${quote(p.p_action)},${quote(JSON.stringify(p.p_payload))}::jsonb)`;
      else if(url.endsWith('/tincall_call_presence'))call=`tincall_call_presence(${quote(p.p_action)},${p.p_owner?quote(p.p_owner)+'::uuid':'null'},${p.p_call?quote(p.p_call)+'::uuid':'null'})`;
      else if(url.endsWith('/tincall_mcp_role'))call=`tincall_mcp_role(${quote(p.p_action)},${quote(p.p_owner)}::uuid,${quote(JSON.stringify(p.p_payload))}::jsonb)`;
      else if(url.endsWith('/tincall_mcp_authenticate'))call=`tincall_mcp_authenticate(${quote(p.p_token)})`;
      else throw new Error('Unexpected local RPC');
      try{const result=sql(`set role service_role;set request.jwt.claim.role='service_role';select public.${call};`);return Response.json(result?JSON.parse(result):null);}
      catch(error){return Response.json({message:error.stderr.toString().match(/ERROR:\s+(\w+)/)?.[1]??'database_request_failed'},{status:400});}
    });
  }else{const file=join(directory,'oauth.sqlite');store=createSQLiteStore({clients},file);db=new DatabaseSync(file);}
  connector=createConnector({store,config:{publicURL:base},schedule:()=>{}});
  for(const contact of ['contact-a','contact-b']){
    const result=await post('/mcp/roles/upsert',{role_id:crypto.randomUUID(),contact_id:contact,display_name:contact},'phone');assert.equal(result.status,200);
  }
});
after(()=>{db?.close();store?.close?.();if(postgres)execFileSync('docker',['rm','-f',container],{stdio:'pipe'});rmSync(directory,{recursive:true,force:true});});

test('MCP OAuth discovery works without a bearer at the Supabase-prefixed URL and advertises PKCE/DCR',async()=>{
  const missing=await request('/mcp');assert.equal(missing.status,401);
  assert.equal(missing.headers.get('www-authenticate'),`Bearer resource_metadata="${base}/.well-known/oauth-protected-resource", scope="tincall:mcp"`);
  const resource=await (await request('/.well-known/oauth-protected-resource')).json();assert.equal(resource.resource,base+'/mcp');assert.deepEqual(resource.authorization_servers,[base]);
  for(const path of ['/.well-known/oauth-authorization-server','/.well-known/openid-configuration']){
    const metadata=await (await request(path)).json();assert.equal(metadata.issuer,base);assert.deepEqual(metadata.code_challenge_methods_supported,['S256']);assert.deepEqual(metadata.token_endpoint_auth_methods_supported,['none']);assert.equal(metadata.registration_endpoint,base+'/oauth/register');assert.equal(metadata.authorization_response_iss_parameter_supported,true);
  }
  const rejected=await post('/oauth/register',{redirect_uris:['https://attacker.invalid/callback']});assert.equal(rejected.status,400);
  const malicious=await post('/oauth/register',{redirect_uris:[callback+'?forward=https://attacker.invalid']});assert.equal(malicious.status,400);
});

test('owner approval exchanges once, binds one contact, survives service restart and cannot read management APIs',async()=>{
  const p=await pending();
  const lookup=await post('/oauth/requests/lookup',{user_code:p.code},'phone');assert.equal(lookup.status,200);assert.equal((await lookup.json()).contacts.length,2);
  assert.equal((await post('/oauth/requests/lookup',{user_code:p.code},'contact')).status,403);
  assert.equal((await post('/oauth/requests/decide',{user_code:p.code,contact_id:'unregistered',decision:'approve'},'phone')).status,400);
  const authorization=await approve(p);assert.equal(authorization.origin,'https://chatgpt.com');assert.equal(authorization.searchParams.get('state'),'synthetic-state');assert.equal(authorization.searchParams.get('iss'),base);
  assert.equal((await exchange(p,authorization,{code_verifier:'x'.repeat(43)})).status,400);
  assert.equal((await exchange(p,authorization,{resource:'https://attacker.invalid/mcp'})).status,400);
  const exchanged=await exchange(p,authorization);assert.equal(exchanged.status,200);const tokens=await exchanged.json();assert.equal(tokens.token_type,'Bearer');assert.equal(tokens.expires_in,3600);
  assert.equal((await exchange(p,authorization)).status,400);
  connector=createConnector({store,config:{publicURL:base},schedule:()=>{}});
  const tools=await post('/mcp',{jsonrpc:'2.0',id:1,method:'tools/list'},tokens.access_token);assert.equal(tools.status,200);
  const definition=(await tools.json()).result.tools.find(t=>t.name==='tincall_call');assert.ok(!definition.inputSchema.required.includes('contact_id'));
  const denied=await post('/mcp',{jsonrpc:'2.0',id:2,method:'tools/call',params:{name:'tincall_call',arguments:{request_id:crypto.randomUUID(),call_id:crypto.randomUUID(),contact_id:'contact-b'}}},tokens.access_token);assert.match(JSON.stringify(await denied.json()),/forbidden/);
  for(const path of ['/records','/capabilities','/calls/current'])assert.equal((await request(path,{token:tokens.access_token})).status,403);
  assert.equal((await post('/oauth/requests/lookup',{user_code:p.code},tokens.access_token)).status,403);
  const wrongAudience=createConnector({store,config:{publicURL:'https://different.invalid'},schedule:()=>{}});
  assert.equal((await wrongAudience.handle(new Request('https://different.invalid/mcp',{headers:{Authorization:'Bearer '+tokens.access_token}}))).status,401);
  const refresh=await request('/oauth/token',{method:'POST',form:{grant_type:'refresh_token',client_id:p.client,refresh_token:tokens.refresh_token,resource:base+'/mcp'}});assert.equal(refresh.status,200);const next=await refresh.json();assert.notEqual(next.access_token,tokens.access_token);
  assert.equal((await post('/mcp',{jsonrpc:'2.0',id:1,method:'ping'},tokens.access_token)).status,401);
  assert.equal((await request('/oauth/token',{method:'POST',form:{grant_type:'refresh_token',client_id:p.client,refresh_token:tokens.refresh_token}})).status,400);
  assert.equal((await request('/oauth/revoke',{method:'POST',form:{client_id:p.client,token:next.refresh_token}})).status,200);
  assert.equal((await post('/mcp',{jsonrpc:'2.0',id:1,method:'ping'},next.access_token)).status,401);
});

test('denial, expiration, wrong client and redirect cannot mint tokens; concurrent code exchange only succeeds once',async()=>{
  const denied=await pending();const refusal=await approve(denied,'deny');assert.equal(refusal.searchParams.get('error'),'access_denied');assert.equal(refusal.searchParams.get('iss'),base);assert.equal(refusal.searchParams.has('code'),false);
  const expired=await pending();expire('oauth_requests','expires_at','id',new URL(expired.location).searchParams.get('request'));assert.equal((await request(expired.location)).status,410);
  const p=await pending();const authorization=await approve(p);
  assert.equal((await exchange(p,authorization,{client_id:await register()})).status,400);
  assert.equal((await exchange(p,authorization,{redirect_uri:'https://chatgpt.com/connector/oauth/other'})).status,400);
  const concurrent=await Promise.all([exchange(p,authorization),exchange(p,authorization)]);assert.deepEqual(concurrent.map(r=>r.status).sort(),[200,400]);
  const tokens=await concurrent.find(r=>r.status===200).json();expire('oauth_grants','access_expires_at','access_token',tokens.access_token);
  assert.equal((await post('/mcp',{jsonrpc:'2.0',id:1,method:'ping'},tokens.access_token)).status,401);
  expire('oauth_grants','refresh_expires_at','refresh_token',tokens.refresh_token);
  assert.equal((await request('/oauth/token',{method:'POST',form:{grant_type:'refresh_token',client_id:p.client,refresh_token:tokens.refresh_token}})).status,400);
});
