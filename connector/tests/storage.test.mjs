import test from 'node:test';
import assert from 'node:assert/strict';
import {createSupabaseStore} from '../../supabase/functions/_shared/tincall/service.mjs';

test('event database reads abort with the disconnected request',async()=>{
  let reading;
  const entered=new Promise(resolve=>{reading=resolve;});
  const store=createSupabaseStore({supabaseURL:'https://fixture.supabase.invalid',publicKey:'public-fixture',serviceKey:'server-fixture'},async(url,init)=>{
    reading();
    return new Promise((resolve,reject)=>init.signal.addEventListener('abort',()=>reject(init.signal.reason),{once:true}));
  });
  const controller=new AbortController();
  const pending=store.command('fixture-owner','call.events',{call_id:'fixture-call'},{signal:controller.signal});
  await entered;
  controller.abort();
  await assert.rejects(pending,{code:'wait_cancelled'});
});

test('media proxy streams private owner paths and uses the Storage remove contract',async()=>{
  const owner='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',record='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',asset='cccccccc-cccc-4ccc-8ccc-cccccccccccc';const seen=[];let listed=false;
  const store=createSupabaseStore({supabaseURL:'https://fixture.supabase.invalid',publicKey:'public-fixture',serviceKey:'server-fixture'},async(url,init)=>{
    const body=init.body ? await new Response(init.body).text() : null;seen.push({url,method:init.method,body,headers:init.headers});
    if(url.endsWith('/object/list/tincall-private')){const files=listed?[]:[{name:asset}];listed=true;return Response.json(files);}
    return new Response(init.method==='GET'?'synthetic media':'{}',{headers:{'Content-Type':init.method==='GET'?'audio/wav':'application/json'}});
  });
  const uploaded=await store.media(owner.toUpperCase(),record.toUpperCase(),asset.toUpperCase(),new Request('http://localhost/media',{method:'PUT',headers:{'Content-Type':'audio/wav'},body:'synthetic media'}));
  assert.equal(uploaded.status,200);assert.equal(seen[0].body,'synthetic media');assert.equal(seen[0].headers['x-upsert'],'false');assert.ok(seen[0].url.endsWith(`/tincall-private/${owner}/${record}/${asset}`));
  const downloaded=await store.media(owner,record,asset,new Request('http://localhost/media'));assert.equal(await downloaded.text(),'synthetic media');assert.equal(downloaded.headers.get('location'),null);
  assert.equal(seen[1].url,seen[0].url);
  await store.media(owner,record,asset,new Request('http://localhost/media',{method:'DELETE'}));
  assert.ok(seen.at(-1).url.endsWith('/object/tincall-private'));assert.deepEqual(JSON.parse(seen.at(-1).body),{prefixes:[`${owner}/${record}/${asset}`]});
  await store.deleteRecordMedia(owner.toUpperCase(),record.toUpperCase());
  assert.deepEqual(JSON.parse(seen[3].body),{prefix:`${owner}/${record}/`,limit:100,offset:0,sortBy:{column:'name',order:'asc'}});
  assert.deepEqual(JSON.parse(seen[4].body),{prefixes:[`${owner}/${record}/${asset}`]});
  assert.equal(seen.length,5);
});

test('a valid but unenrolled Supabase Auth user cannot become a Tincall owner',async()=>{
  let requests=0;
  const owner='10000000-0000-4000-8000-000000000001';
  const store=createSupabaseStore({supabaseURL:'https://fixture.supabase.invalid',publicKey:'public-fixture',serviceKey:'server-fixture',clients:[{token:'configured-phone',owner_id:owner}]},async()=>{
    requests++;return Response.json({id:'10000000-0000-4000-8000-000000000002'});
  });
  assert.deepEqual(await store.authenticate('configured-phone'),{owner_id:owner,contact_id:null});
  await assert.rejects(store.authenticate('synthetic-supabase-access-token'),{code:'unauthorized',status:401});
  assert.equal(requests,0,'unknown tokens must not fall back to Supabase login');
});
