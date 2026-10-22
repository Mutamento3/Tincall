-- MCP facade: bounded reads, a real opening reply, and atomic append/finalize.
-- Existing phone/HTTP commands keep their original contract.
alter table public.tincall_messages add column reply_touched_at timestamptz;

create function public.tincall_mcp(p_action text, p_owner uuid, p_contact text, p_payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c public.tincall_calls;
  m public.tincall_messages;
  old public.tincall_requests;
  j public.tincall_jobs;
  items jsonb;
  target jsonb;
  result jsonb;
  n integer := coalesce((p_payload->>'limit')::integer,50);
  after_value bigint := (p_payload->>'after_sequence')::bigint;
  before_value bigint := (p_payload->>'before_sequence')::bigint;
  more boolean := false;
  status_value text;
  text_value text;
  req uuid;
  cid uuid;
begin
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception using errcode='42501',message='forbidden';
  end if;
  if p_action='expire' then
    for m in select q.* from public.tincall_messages q join public.tincall_calls a on a.id=q.call_id
      where a.source='mcp' and a.status='active' and q.role='assistant' and q.status='generating'
        and coalesce(q.reply_touched_at,q.created_at)<now()-interval '5 minutes'
        and not exists(select 1 from public.tincall_jobs h where h.reply_id=q.id and h.mode='http') order by q.owner_id,q.id loop
      perform 1 from public.tincall_owners where owner_id=m.owner_id for update;
      update public.tincall_messages set status='failed'
        where id=m.id and status='generating' and coalesce(reply_touched_at,created_at)<now()-interval '5 minutes';
      if found then
        update public.tincall_jobs set status='failed' where reply_id=m.id and mode='tools';
        perform public.tincall_emit(m.call_id,'reply.failed',jsonb_build_object('reply_id',m.id,'input_id',m.input_id,'code','platform_timeout'));
      end if;
    end loop;
    return jsonb_build_object('ok',true);
  end if;
  if p_owner is null then raise exception using errcode='42501',message='unauthorized'; end if;
  insert into public.tincall_owners(owner_id) values(p_owner) on conflict do nothing;
  perform 1 from public.tincall_owners where owner_id=p_owner for update;
  if n<1 or n>100 then raise exception using errcode='22023',message='invalid_limit'; end if;
  if p_action='list' then
    select coalesce(jsonb_agg(to_jsonb(q) order by q.started_at desc,q.call_id desc),'[]') into items from
      (select id as call_id,created_at as started_at,ended_at,status,coalesce(length(trim(summary))>0,false) as has_summary
       from public.tincall_calls where owner_id=p_owner and (p_contact is null or contact_id=p_contact)
         and (not(p_payload ? 'before') or (created_at,id)<((p_payload->'before'->>'started_at')::timestamptz,(p_payload->'before'->>'call_id')::uuid))
       order by created_at desc,id desc limit n+1) q;
    more := jsonb_array_length(items)>n;
    if more then items:=items-n; end if;
    return jsonb_build_object('calls',items,'has_more',more,'next_cursor',case when more then
      jsonb_build_object('started_at',items->(n-1)->>'started_at','call_id',items->(n-1)->>'call_id') else null end);
  end if;
  cid := (p_payload->>'call_id')::uuid;
  if cid is null and p_action='snapshot' then
    select * into c from public.tincall_calls where owner_id=p_owner and status<>'ended'
      and (p_contact is null or contact_id=p_contact);
    if c.id is null then return jsonb_build_object('call',null,'messages','[]'::jsonb,'reply',null); end if;
  else
    select * into c from public.tincall_calls where id=cid and owner_id=p_owner
      and (p_contact is null or contact_id=p_contact);
    if c.id is null then raise exception using errcode='P0002',message='call_not_found'; end if;
  end if;
  if p_action='open' then
    if c.status='active' and c.source='mcp' and c.epoch=0
      and not exists(select 1 from public.tincall_messages where call_id=c.id and role='assistant' and epoch=0) then
      insert into public.tincall_messages(id,call_id,owner_id,role,epoch,status,reply_touched_at)
        values(gen_random_uuid(),c.id,p_owner,'assistant',0,'generating',now()) returning * into m;
      perform public.tincall_emit(c.id,'reply.started',jsonb_build_object('reply_id',m.id,'input_id',null,'opening',true));
    end if;
    return jsonb_build_object('ok',true);
  elsif p_action='snapshot' then
    select * into m from public.tincall_messages where call_id=c.id and role='assistant'
      and epoch=c.epoch and status='generating'
      and not exists(select 1 from public.tincall_jobs h where h.reply_id=tincall_messages.id and h.mode='http') order by sequence desc limit 1;
    target := case when m.id is not null then jsonb_build_object('reply_id',m.id,'input_id',m.input_id,'epoch',m.epoch,
      'kind',case when m.input_id is null then 'opening' else 'input' end) else null end;
    if after_value is null then
      select coalesce(jsonb_agg(to_jsonb(q)-'owner_id'-'reply_touched_at' order by q.sequence),'[]') into items from
        (select * from public.tincall_messages where call_id=c.id and (before_value is null or sequence<before_value)
         order by sequence desc limit n+1) q;
      more:=jsonb_array_length(items)>n;
      if more then items:=items-0; end if;
    else
      if after_value>(select coalesce(max(sequence),0) from public.tincall_messages where call_id=c.id) then
        raise exception using errcode='22023',message='invalid_cursor';
      end if;
      select coalesce(jsonb_agg(to_jsonb(q)-'owner_id'-'reply_touched_at' order by q.sequence),'[]') into items from
        (select * from public.tincall_messages where call_id=c.id and role='user' and sequence>after_value
         order by sequence limit n+1) q;
      more:=jsonb_array_length(items)>n;
      if more then items:=items-n; target:=null; end if;
      -- Reading a turn is not acknowledgement: recover an unanswered input even
      -- when a previous tool response advanced the caller's cursor.
      if not more and m.input_id is not null and not exists(select 1 from jsonb_array_elements(items) x where x->>'id'=m.input_id::text) then
        select items || jsonb_build_array(to_jsonb(q)-'owner_id'-'reply_touched_at') into items
          from public.tincall_messages q where id=m.input_id;
      end if;
    end if;
    return jsonb_build_object('call',to_jsonb(c)-'owner_id'-'tts_expression_prompt'-'voice_instructions_sent',
      'messages',items,'reply',target,'has_more',more,
      'next_before_sequence',case when more and after_value is null then (items->0->>'sequence')::bigint else null end,
      'after_sequence',case when after_value is not null then greatest(after_value,coalesce((items->(jsonb_array_length(items)-1)->>'sequence')::bigint,0)) else null end,
      'voice_instructions',case when c.status='active' then '你的回复会被实时朗读成语音，请写适合说出口的口语。' ||
        case when c.tts_expression_prompt='' then '' else E'\n'||c.tts_expression_prompt end else null end);
  elsif p_action='reply' then
    req:=(p_payload->>'request_id')::uuid;
    if req is null then raise exception using errcode='22023',message='invalid_request_id'; end if;
    select * into old from public.tincall_requests where owner_id=p_owner and request_id=req;
    if found then
      if old.retired then raise exception using errcode='P0001',message='operation_retired'; end if;
      if old.action<>'mcp.reply' or old.payload<>p_payload then raise exception using errcode='P0001',message='idempotency_conflict'; end if;
      return old.response;
    end if;
    select * into m from public.tincall_messages where id=(p_payload->>'reply_id')::uuid and call_id=c.id and role='assistant';
    if m.id is null then raise exception using errcode='P0002',message='reply_not_found'; end if;
    select * into j from public.tincall_jobs where reply_id=m.id;
    if c.status<>'active' or m.status<>'generating' or c.epoch<>m.epoch or (p_payload->>'epoch')::integer is distinct from m.epoch
      or (j.id is not null and j.mode<>'tools') or (j.id is null and not(c.source='mcp' and m.input_id is null and m.epoch=0)) then
      raise exception using errcode='P0001',message='stale_epoch';
    end if;
    status_value:=p_payload->>'status'; text_value:=coalesce(p_payload->>'text','');
    if status_value not in ('partial','complete','failed') or status_value is null or length(text_value)+length(m.text)>100000
      or (status_value='partial' and length(trim(text_value))=0) or (status_value='failed' and text_value<>'')
      or (p_payload ? 'error_code' and (status_value<>'failed' or (p_payload->>'error_code') !~ '^[a-z][a-z0-9_]{0,63}$')) then
      raise exception using errcode='22023',message='invalid_reply';
    end if;
    update public.tincall_messages set text=text||text_value,reply_touched_at=now(),
      status=case status_value when 'partial' then 'generating' when 'complete' then 'complete' else 'failed' end
      where id=m.id returning * into m;
    if status_value<>'partial' then update public.tincall_jobs set status=case status_value when 'complete' then 'completed' else 'failed' end where reply_id=m.id; end if;
    perform public.tincall_emit(c.id,case status_value when 'partial' then 'reply.delta' when 'complete' then 'reply.completed' else 'reply.failed' end,
      jsonb_build_object('reply_id',m.id,'input_id',m.input_id,'opening',m.input_id is null) ||
      case status_value when 'partial' then jsonb_build_object('delta',text_value) when 'complete' then jsonb_build_object('text',m.text)
        else jsonb_build_object('code',coalesce(p_payload->>'error_code','generation_failed')) end);
    result:=jsonb_build_object('call',to_jsonb(c)-'owner_id'-'tts_expression_prompt'-'voice_instructions_sent',
      'reply_accepted',true,'cursor',jsonb_build_object('sequence',coalesce((select sequence from public.tincall_messages where id=m.input_id),0),'epoch',m.epoch));
    insert into public.tincall_requests(owner_id,request_id,action,payload,response) values(p_owner,req,'mcp.reply',p_payload,result);
    return result;
  end if;
  raise exception using errcode='22023',message='unknown_action';
end $$;
revoke all on function public.tincall_mcp(text,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.tincall_mcp(text,uuid,text,jsonb) to service_role;
