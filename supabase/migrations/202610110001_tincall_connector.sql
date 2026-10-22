-- All data belongs to the deployer's Supabase project. No publisher service is involved.
create table public.tincall_owners (
  owner_id uuid primary key references auth.users(id) on delete cascade
);
create table public.tincall_calls (
  id uuid primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  contact_id text not null check (length(contact_id) between 1 and 200),
  source text not null check (source in ('backend','mcp','independent')),
  status text not null check (status in ('active','ringing','ended')),
  epoch integer not null default 0,
  last_sequence bigint not null default 0,
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  summary text
);
create unique index tincall_one_live_call on public.tincall_calls(owner_id) where status <> 'ended';
create table public.tincall_messages (
  id uuid primary key,
  sequence bigint generated always as identity,
  call_id uuid not null references public.tincall_calls(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  input_id uuid,
  role text not null check (role in ('user','assistant')),
  epoch integer not null,
  text text not null default '',
  status text not null check (status in ('complete','generating','interrupted','failed')),
  interruption_reason text,
  created_at timestamptz not null default now()
);
create table public.tincall_events (
  call_id uuid not null references public.tincall_calls(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  sequence bigint not null,
  epoch integer not null,
  type text not null,
  payload jsonb not null,
  created_at timestamptz not null default now(),
  primary key(call_id, sequence)
);
create table public.tincall_requests (
  owner_id uuid not null references auth.users(id) on delete cascade,
  request_id uuid not null,
  action text not null,
  payload jsonb not null,
  response jsonb not null,
  retired boolean not null default false,
  created_at timestamptz not null default now(),
  primary key(owner_id, request_id)
);
create table public.tincall_jobs (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  call_id uuid not null references public.tincall_calls(id) on delete cascade,
  input_id uuid not null references public.tincall_messages(id),
  reply_id uuid not null references public.tincall_messages(id),
  epoch integer not null,
  mode text not null check (mode in ('http','tools')),
  status text not null default 'pending' check(status in ('pending','running','completed','failed','cancelled')),
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  unique(call_id,epoch)
);
create index tincall_pending_jobs on public.tincall_jobs(created_at) where status = 'pending';
create table public.tincall_devices (
  owner_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  -- This is the deployer's push gateway binding, not an APNs private key.
  binding_id text not null check(length(binding_id) between 1 and 500),
  enabled boolean not null default true,
  primary key(owner_id,id)
);
create table public.tincall_schedules (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  contact_id text not null check(length(contact_id) between 1 and 200),
  source text not null check(source in ('backend','mcp','independent')),
  next_at timestamptz not null,
  repeat_seconds integer check(repeat_seconds >= 300),
  daily_time time,
  time_zone text,
  check (daily_time is null or (time_zone is not null and repeat_seconds is null)),
  enabled boolean not null default true
);
create table public.tincall_push_jobs (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  call_id uuid not null references public.tincall_calls(id) on delete cascade,
  status text not null default 'pending' check(status in ('pending','running','sent','failed','cancelled')),
  error_code text,
  created_at timestamptz not null default now(),
  claimed_at timestamptz
);
-- Revision + tombstone stop an old device from resurrecting a deleted backup.
create table public.tincall_records (
  owner_id uuid not null references auth.users(id) on delete cascade,
  id uuid not null,
  revision bigint not null default 1,
  deleted boolean not null default false,
  record jsonb,
  updated_at timestamptz not null default now(),
  primary key(owner_id,id)
);

do $$
declare t text;
begin
  foreach t in array array['tincall_owners','tincall_calls','tincall_messages','tincall_events',
    'tincall_requests','tincall_jobs','tincall_devices','tincall_schedules','tincall_push_jobs','tincall_records'] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('create policy owner_read on public.%I for select to authenticated using (owner_id = (select auth.uid()))',t);
    execute format('revoke all on public.%I from anon, authenticated',t);
    execute format('grant select on public.%I to authenticated',t);
  end loop;
end $$;

create function public.tincall_emit(p_call uuid, p_type text, p_payload jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.tincall_calls;
begin
  update public.tincall_calls set last_sequence = last_sequence + 1 where id = p_call returning * into c;
  insert into public.tincall_events(call_id,owner_id,sequence,epoch,type,payload)
    values(c.id,c.owner_id,c.last_sequence,c.epoch,p_type,p_payload);
end $$;
revoke all on function public.tincall_emit(uuid,text,jsonb) from public,anon,authenticated;

create function public.tincall_stop_reply(p_call uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare m public.tincall_messages;
begin
  for m in update public.tincall_messages set status = 'interrupted', interruption_reason = p_reason
    where call_id=p_call and role='assistant' and status='generating' returning * loop
    perform public.tincall_emit(p_call,'reply.interrupted',jsonb_build_object('reply_id',m.id,'input_id',m.input_id,'reason',p_reason));
  end loop;
  update public.tincall_jobs set status='cancelled' where call_id=p_call and status in ('pending','running');
end $$;
revoke all on function public.tincall_stop_reply(uuid,text) from public,anon,authenticated;

create function public.tincall_next_daily(p_time time,p_zone text,p_after timestamptz) returns timestamptz
language plpgsql set search_path = '' as $$
declare next_date date := (p_after at time zone p_zone)::date; due timestamptz;
begin
  due := (next_date+p_time) at time zone p_zone;
  if due<=p_after then due := ((next_date+1)+p_time) at time zone p_zone; end if;
  return due;
end $$;
revoke all on function public.tincall_next_daily(time,text,timestamptz) from public,anon,authenticated;

-- All mutations of one owner serialize on its owner row. Request bodies are compared
-- directly, without fingerprints. A reused request ID with a changed body is a conflict.
create function public.tincall_command(p_action text, p_payload jsonb default '{}', p_owner uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  u uuid := auth.uid();
  service boolean := coalesce(auth.role(),'') = 'service_role';
  c public.tincall_calls;
  j public.tincall_jobs;
  m public.tincall_messages;
  old public.tincall_requests;
  r public.tincall_records;
  req uuid;
  cid uuid;
  rid uuid;
  result jsonb;
  items jsonb;
  cursor_value bigint;
  limit_value integer;
  reason_value text;
  s public.tincall_schedules;
  pj public.tincall_push_jobs;
  tail_record jsonb;
begin
  if service then u := p_owner; elsif p_owner is not null and p_owner <> u then
    raise exception using errcode='42501',message='forbidden';
  end if;
  if u is null then raise exception using errcode='42501',message='unauthorized'; end if;
  insert into public.tincall_owners(owner_id) values(u) on conflict do nothing;
  perform 1 from public.tincall_owners where owner_id=u for update;
  if p_action='device.lookup' then
    select * into old from public.tincall_requests where owner_id=u and request_id=(p_payload->>'request_id')::uuid;
    if old.request_id is null then return jsonb_build_object('response',null); end if;
    if old.action<>'device.put' or old.payload-'binding_id'<>p_payload then raise exception using errcode='P0001',message='idempotency_conflict'; end if;
    return jsonb_build_object('response',old.response);
  end if;

  if p_action in ('call.create','call.incoming','call.accept','call.input','call.interrupt','call.end',
    'reply.delta','reply.completed','reply.failed','device.put','device.delete','schedule.put','schedule.delete','record.put','record.delete','summary.put') then
    req := (p_payload->>'request_id')::uuid;
    if req is null then raise exception using errcode='22023',message='request_id_required'; end if;
    select * into old from public.tincall_requests where owner_id=u and request_id=req;
    if found then
      if old.retired then raise exception using errcode='P0001',message='operation_retired'; end if;
      if old.action <> p_action or old.payload <> p_payload then
        raise exception using errcode='P0001',message='idempotency_conflict';
      end if;
      return old.response;
    end if;
  end if;

  if p_action in ('call.create','call.incoming') then
    if exists(select 1 from public.tincall_calls where owner_id=u and status <> 'ended') then
      raise exception using errcode='P0001',message='call_busy';
    end if;
    cid := (p_payload->>'call_id')::uuid;
    if cid is null then raise exception using errcode='22023',message='call_id_required'; end if;
    insert into public.tincall_calls(id,owner_id,contact_id,source,status)
      values(cid,u,p_payload->>'contact_id',p_payload->>'source',case when p_action='call.incoming' then 'ringing' else 'active' end);
    perform public.tincall_emit(cid,case when p_action='call.incoming' then 'call.ringing' else 'call.started' end,'{}');
    if p_action='call.incoming' then insert into public.tincall_push_jobs(owner_id,call_id) values(u,cid); end if;
    select * into c from public.tincall_calls where id=cid;
    result := jsonb_build_object('call',to_jsonb(c)-'owner_id');
  elsif p_action='call.current' then
    select * into c from public.tincall_calls where owner_id=u and status <> 'ended';
    return jsonb_build_object('call',case when c.id is null then null else to_jsonb(c)-'owner_id' end);
  elsif p_action='call.list' then
    select coalesce(jsonb_agg(x),'[]') into items from (select to_jsonb(q)-'owner_id' as x from
      (select * from public.tincall_calls where owner_id=u order by created_at desc limit 100) q) v;
    return jsonb_build_object('calls',items);
  elsif p_action in ('device.put','device.delete') then
    if p_action='device.put' then
      if not exists(select 1 from public.tincall_devices where owner_id=u and id=(p_payload->>'device_id')::uuid)
        and (select count(*) from public.tincall_devices where owner_id=u)>=5 then
        raise exception using errcode='P0001',message='device_limit';
      end if;
      insert into public.tincall_devices(owner_id,id,binding_id) values(u,(p_payload->>'device_id')::uuid,p_payload->>'binding_id')
        on conflict(owner_id,id) do update set binding_id=excluded.binding_id,enabled=true;
    else delete from public.tincall_devices where owner_id=u and id=(p_payload->>'device_id')::uuid; end if;
    result := jsonb_build_object('ok',true,'binding_id',p_payload->>'binding_id');
  elsif p_action in ('schedule.put','schedule.delete') then
    if p_action='schedule.put' then
      insert into public.tincall_schedules(id,owner_id,contact_id,source,next_at,repeat_seconds,daily_time,time_zone)
        values((p_payload->>'schedule_id')::uuid,u,p_payload->>'contact_id',p_payload->>'source',
          case when p_payload->>'daily_time' is not null then public.tincall_next_daily((p_payload->>'daily_time')::time,p_payload->>'time_zone',now())
            else (p_payload->>'next_at')::timestamptz end,(p_payload->>'repeat_seconds')::integer,(p_payload->>'daily_time')::time,p_payload->>'time_zone')
        on conflict(id) do update set contact_id=excluded.contact_id,source=excluded.source,next_at=excluded.next_at,
          repeat_seconds=excluded.repeat_seconds,daily_time=excluded.daily_time,time_zone=excluded.time_zone,enabled=true where tincall_schedules.owner_id=u;
      if not found then raise exception using errcode='42501',message='forbidden'; end if;
    else delete from public.tincall_schedules where owner_id=u and id=(p_payload->>'schedule_id')::uuid; end if;
    result := jsonb_build_object('ok',true);
  elsif p_action='schedule.list' then
    select coalesce(jsonb_agg(to_jsonb(q)-'owner_id'),'[]') into items from public.tincall_schedules q where owner_id=u;
    return jsonb_build_object('schedules',items);
  elsif p_action in ('record.put','record.delete','record.get','record.list') then
    if p_action='record.list' then
      select coalesce(jsonb_agg(to_jsonb(q)),'[]') into items from
        (select id,revision,deleted,updated_at from public.tincall_records where owner_id=u and (updated_at,id) >
          (coalesce((p_payload->>'after')::timestamptz,'1970-01-01'),coalesce((p_payload->>'after_id')::uuid,'00000000-0000-0000-0000-000000000000'))
          order by updated_at,id limit 101) q;
      if jsonb_array_length(items)>100 then items:=items-100; end if;
      tail_record:=items->(jsonb_array_length(items)-1);
      return jsonb_build_object('records',items,'next_cursor',case when tail_record is null then null else
        jsonb_build_object('after',tail_record->>'updated_at','after_id',tail_record->>'id') end);
    end if;
    rid := (p_payload->>'record_id')::uuid;
    select * into r from public.tincall_records where owner_id=u and id=rid;
    if p_action='record.get' then return jsonb_build_object('record',case when r.id is null then null else to_jsonb(r)-'owner_id' end); end if;
    if coalesce(r.revision,0) <> (p_payload->>'expected_revision')::bigint or p_payload->>'expected_revision' is null then
      raise exception using errcode='P0001',message='revision_conflict';
    end if;
    insert into public.tincall_records(owner_id,id,revision,deleted,record)
      values(u,rid,coalesce(r.revision,0)+1,p_action='record.delete',case when p_action='record.delete' then null else p_payload->'record' end)
      on conflict(owner_id,id) do update set revision=excluded.revision,deleted=excluded.deleted,record=excluded.record,updated_at=clock_timestamp()
      returning * into r;
    result := jsonb_build_object('record',to_jsonb(r)-'owner_id');
    if p_action='record.delete' then
      update public.tincall_requests set retired=true,
        payload=jsonb_build_object('record_id',rid),response='{}'
        where owner_id=u and action='record.put' and lower(payload->>'record_id')=rid::text;
    end if;
  elsif p_action='job.claim' then
    if not service then raise exception using errcode='42501',message='forbidden'; end if;
    select * into j from public.tincall_jobs where owner_id=u and mode='http' and status='pending' order by created_at limit 1;
    if j.id is null then return jsonb_build_object('job',null); end if;
    update public.tincall_jobs set status='running',claimed_at=now() where id=j.id returning * into j;
    select * into c from public.tincall_calls where id=j.call_id;
    select coalesce(jsonb_agg(to_jsonb(q)-'owner_id'),'[]') into items from
      (select * from public.tincall_messages where call_id=c.id and id<>j.reply_id order by sequence) q;
    return jsonb_build_object('job',to_jsonb(j),'call',to_jsonb(c)-'owner_id','messages',items);
  elsif p_action='push.claim' then
    if not service then raise exception using errcode='42501',message='forbidden'; end if;
    update public.tincall_push_jobs set status='cancelled' where owner_id=u and status='pending'
      and not exists(select 1 from public.tincall_calls c2 where c2.id=tincall_push_jobs.call_id and c2.status='ringing');
    select * into pj from public.tincall_push_jobs where owner_id=u and status='pending' order by created_at limit 1;
    if pj.id is null then return jsonb_build_object('push',null); end if;
    update public.tincall_push_jobs set status='running',claimed_at=now() where id=pj.id;
    select * into c from public.tincall_calls where id=pj.call_id;
    select coalesce(jsonb_agg(jsonb_build_object('device_id',id,'binding_id',binding_id)),'[]') into items
      from public.tincall_devices where owner_id=u and enabled;
    return jsonb_build_object('push',jsonb_build_object('id',pj.id,'call_id',pj.call_id,'contact_id',c.contact_id,'source',c.source,'devices',items));
  elsif p_action='push.finish' then
    if not service then raise exception using errcode='42501',message='forbidden'; end if;
    update public.tincall_push_jobs set status=case when p_payload->>'error_code' is null then 'sent' else 'failed' end,
      error_code=p_payload->>'error_code' where owner_id=u and id=(p_payload->>'push_id')::uuid and status='running';
    return jsonb_build_object('ok',true);
  else
    cid := (p_payload->>'call_id')::uuid;
    select * into c from public.tincall_calls where id=cid and owner_id=u;
    if c.id is null then raise exception using errcode='P0002',message='call_not_found'; end if;
    if p_action='call.events' then
      cursor_value := greatest(coalesce((p_payload->>'after')::bigint,0),0);
      if cursor_value>c.last_sequence then raise exception using errcode='P0001',message='invalid_cursor'; end if;
      limit_value := least(greatest(coalesce((p_payload->>'limit')::integer,100),1),100);
      select coalesce(jsonb_agg(to_jsonb(q)-'owner_id' order by sequence),'[]'),coalesce(max(sequence),cursor_value)
        into items,cursor_value from (select * from public.tincall_events where call_id=cid and sequence>cursor_value order by sequence limit limit_value) q;
      return jsonb_build_object('call',to_jsonb(c)-'owner_id','events',items,'cursor',cursor_value,'has_more',cursor_value<c.last_sequence);
    elsif p_action in ('call.record','call.inputs') then
      select coalesce(jsonb_agg(to_jsonb(q)-'owner_id' order by sequence),'[]') into items from public.tincall_messages q
        where call_id=cid and (p_action='call.record' or role='user');
      select * into j from public.tincall_jobs where call_id=cid and epoch=c.epoch and status in ('pending','running');
      select * into pj from public.tincall_push_jobs where call_id=cid order by created_at desc limit 1;
      return jsonb_build_object('call',to_jsonb(c)-'owner_id','messages',items,'job',case when j.id is null then null else to_jsonb(j)-'owner_id' end,
        'push',case when pj.id is null then null else jsonb_build_object('status',pj.status,'error_code',pj.error_code) end);
    elsif p_action='call.accept' then
      if c.status <> 'ringing' then raise exception using errcode='P0001',message='call_not_ringing'; end if;
      if (p_payload->>'epoch')::integer is distinct from c.epoch then raise exception using errcode='P0001',message='stale_epoch'; end if;
      update public.tincall_calls set status='active' where id=cid;
      perform public.tincall_emit(cid,'call.started','{}');
    elsif p_action='job.cancel_result' then
      if not service then raise exception using errcode='42501',message='forbidden'; end if;
      perform public.tincall_emit(cid,'generation.cancel_result',jsonb_build_object('epoch',(p_payload->>'epoch')::integer,'code',p_payload->>'code'));
    elsif p_action='summary.put' then
      if length(p_payload->>'text')>100000 then raise exception using errcode='22023',message='text_too_long'; end if;
      update public.tincall_calls set summary=p_payload->>'text' where id=cid;
    elsif p_action in ('call.input','call.interrupt','call.end') then
      if c.status='ended' then raise exception using errcode='P0001',message='call_ended'; end if;
      if (p_payload->>'epoch')::integer is distinct from c.epoch then raise exception using errcode='P0001',message='stale_epoch'; end if;
      reason_value := case when p_action='call.end' then 'hangup' else 'interrupted' end;
      if p_action='call.input' then
        if c.status<>'active' then raise exception using errcode='P0001',message='call_not_active'; end if;
        if p_payload->>'text' is null or length(trim(p_payload->>'text')) not between 1 and 20000 then
          raise exception using errcode='22023',message='invalid_text';
        end if;
      end if;
      perform public.tincall_stop_reply(cid,reason_value);
      update public.tincall_calls set epoch=epoch+1 where id=cid returning * into c;
      if p_action='call.input' then
        rid := gen_random_uuid();
        insert into public.tincall_messages(id,call_id,owner_id,role,epoch,text,status)
          values((p_payload->>'message_id')::uuid,cid,u,'user',c.epoch,p_payload->>'text','complete');
        insert into public.tincall_messages(id,call_id,owner_id,input_id,role,epoch,status)
          values(rid,cid,u,(p_payload->>'message_id')::uuid,'assistant',c.epoch,'generating');
        insert into public.tincall_jobs(owner_id,call_id,input_id,reply_id,epoch,mode)
          values(u,cid,(p_payload->>'message_id')::uuid,rid,c.epoch,p_payload->>'mode') returning * into j;
        perform public.tincall_emit(cid,'input.accepted',jsonb_build_object('input_id',j.input_id,'reply_id',rid));
        perform public.tincall_emit(cid,'reply.started',jsonb_build_object('input_id',j.input_id,'reply_id',rid));
      elsif p_action='call.end' then
        update public.tincall_calls set status='ended',ended_at=now() where id=cid;
        perform public.tincall_emit(cid,'call.ended',jsonb_build_object('reason',coalesce(p_payload->>'reason','hangup')));
      else perform public.tincall_emit(cid,'call.interrupted',jsonb_build_object('reason','interrupted')); end if;
    elsif p_action in ('reply.delta','reply.completed','reply.failed') then
      select * into j from public.tincall_jobs where owner_id=u and call_id=cid and reply_id=(p_payload->>'reply_id')::uuid;
      if j.id is null then raise exception using errcode='P0002',message='reply_not_found'; end if;
      if c.status<>'active' or c.epoch<>j.epoch or (p_payload->>'epoch')::integer is distinct from j.epoch or j.status not in ('pending','running') then
        raise exception using errcode='P0001',message='stale_epoch';
      end if;
      select * into m from public.tincall_messages where id=j.reply_id;
      if p_action='reply.delta' then
        if length(coalesce(p_payload->>'delta','')) not between 1 and 20000 or length(m.text)+length(p_payload->>'delta')>100000 then
          raise exception using errcode='22023',message='invalid_delta';
        end if;
        update public.tincall_messages set text=text || (p_payload->>'delta') where id=m.id;
        items := jsonb_build_object('delta',p_payload->>'delta');
      elsif p_action='reply.completed' then
        if p_payload ? 'text' and (length(p_payload->>'text')>100000 or left(p_payload->>'text',length(m.text))<>m.text) then
          raise exception using errcode='P0001',message='final_text_rewrite';
        end if;
        update public.tincall_messages set text=coalesce(p_payload->>'text',text),status='complete' where id=m.id returning * into m;
        update public.tincall_jobs set status='completed' where id=j.id;
        items := jsonb_build_object('text',m.text);
      else
        update public.tincall_messages set status='failed' where id=m.id;
        update public.tincall_jobs set status='failed' where id=j.id;
        items := jsonb_build_object('code',left(coalesce(p_payload->>'code','generation_failed'),100));
      end if;
      perform public.tincall_emit(cid,p_action,items || jsonb_build_object('reply_id',j.reply_id,'input_id',j.input_id));
    else raise exception using errcode='22023',message='unknown_action'; end if;
    select * into c from public.tincall_calls where id=cid;
    result := jsonb_build_object('call',to_jsonb(c)-'owner_id');
    if p_action='call.input' then result := result || jsonb_build_object('input_id',j.input_id,'reply_id',rid,'epoch',c.epoch); end if;
  end if;
  if req is not null then insert into public.tincall_requests(owner_id,request_id,action,payload,response) values(u,req,p_action,p_payload,result); end if;
  return result;
end $$;
revoke all on function public.tincall_command(text,jsonb,uuid) from public,anon;
grant execute on function public.tincall_command(text,jsonb,uuid) to authenticated,service_role;

-- Called by the bounded worker. No generation is started twice after a lost lease.
create function public.tincall_worker_owners() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare j public.tincall_jobs; c public.tincall_calls; s public.tincall_schedules; cid uuid; result jsonb;
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception using errcode='42501',message='forbidden'; end if;
  for j in select * from public.tincall_jobs where status='running' and claimed_at<now()-interval '110 seconds' loop
    perform 1 from public.tincall_owners where owner_id=j.owner_id for update;
    if exists(select 1 from public.tincall_jobs where id=j.id and status='running') then
      perform public.tincall_command('reply.failed',jsonb_build_object('request_id',gen_random_uuid(),'call_id',j.call_id,
        'reply_id',j.reply_id,'epoch',j.epoch,'code','worker_expired'),j.owner_id);
    end if;
  end loop;
  update public.tincall_push_jobs set status='failed',error_code='worker_expired' where status='running' and claimed_at<now()-interval '110 seconds';
  for s in select * from public.tincall_schedules where enabled and next_at<=now() order by next_at limit 20 loop
    insert into public.tincall_owners(owner_id) values(s.owner_id) on conflict do nothing;
    perform 1 from public.tincall_owners where owner_id=s.owner_id for update;
    select * into s from public.tincall_schedules where id=s.id and enabled and next_at<=now();
    if not found then continue; end if;
    if not exists(select 1 from public.tincall_calls where owner_id=s.owner_id and status<>'ended') then
      cid := gen_random_uuid();
      perform public.tincall_command('call.incoming',jsonb_build_object('request_id',gen_random_uuid(),'call_id',cid,
        'contact_id',s.contact_id,'source',s.source),s.owner_id);
    end if;
    update public.tincall_schedules set enabled=(repeat_seconds is not null or daily_time is not null),
      next_at=case when daily_time is not null then public.tincall_next_daily(daily_time,time_zone,now())
        when repeat_seconds is null then next_at else now()+make_interval(secs=>repeat_seconds) end where id=s.id;
  end loop;
  -- A missed ring expires; it must never keep the one-live-call slot forever.
  for c in select * from public.tincall_calls where status='ringing' and created_at<now()-interval '60 seconds' loop
    perform 1 from public.tincall_owners where owner_id=c.owner_id for update;
    if exists(select 1 from public.tincall_calls where id=c.id and status='ringing') then
      perform public.tincall_command('call.end',jsonb_build_object('request_id',gen_random_uuid(),'call_id',c.id,'epoch',c.epoch,'reason','missed'),c.owner_id);
    end if;
  end loop;
  select coalesce(jsonb_agg(owner_id),'[]') into result from
    (select owner_id from public.tincall_jobs where status='pending' and mode='http'
      union select owner_id from public.tincall_push_jobs where status='pending' limit 3) q;
  return result;
end $$;
revoke all on function public.tincall_worker_owners() from public,anon,authenticated;
grant execute on function public.tincall_worker_owners() to service_role;

insert into storage.buckets(id,name,public) values('tincall-private','tincall-private',false)
  on conflict(id) do update set public=false;
create policy tincall_media_read on storage.objects for select to authenticated
  using(bucket_id='tincall-private' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy tincall_media_insert on storage.objects for insert to authenticated
  with check(bucket_id='tincall-private' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy tincall_media_update on storage.objects for update to authenticated
  using(bucket_id='tincall-private' and (storage.foldername(name))[1]=(select auth.uid())::text)
  with check(bucket_id='tincall-private' and (storage.foldername(name))[1]=(select auth.uid())::text);
create policy tincall_media_delete on storage.objects for delete to authenticated
  using(bucket_id='tincall-private' and (storage.foldername(name))[1]=(select auth.uid())::text);
