-- Short-lived transport mailboxes, shared by independently routed Edge requests.
create table public.tincall_mcp_sse (
  id uuid primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  contact_id text,
  expires_at timestamptz not null,
  sequence bigint not null default 0,
  messages jsonb not null default '[]'
);
create index on public.tincall_mcp_sse(expires_at);
alter table public.tincall_mcp_sse enable row level security;
revoke all on public.tincall_mcp_sse from public, anon, authenticated;

create function public.tincall_mcp_sse_command(p_action text, p_owner uuid, p_contact text, p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  saved public.tincall_mcp_sse;
  sid uuid := (p_payload->>'session_id')::uuid;
  cursor_value bigint;
  pending jsonb;
begin
  if coalesce(auth.role(),'') <> 'service_role' or p_owner is null then
    raise exception using errcode='42501', message='forbidden';
  end if;
  if p_action = 'open' then
    delete from public.tincall_mcp_sse where expires_at <= clock_timestamp();
    if (select count(*) from public.tincall_mcp_sse where owner_id=p_owner) >= 16 then
      raise exception using errcode='P0001', message='sse_session_limit';
    end if;
    insert into public.tincall_mcp_sse(id,owner_id,contact_id,expires_at)
      values(sid,p_owner,p_contact,clock_timestamp()+interval '3 minutes');
    return '{}'::jsonb;
  end if;
  select * into saved from public.tincall_mcp_sse
    where id=sid and owner_id=p_owner and contact_id is not distinct from p_contact
      and expires_at > clock_timestamp() for update;
  if not found then raise exception using errcode='P0001', message='sse_session_not_found'; end if;
  if p_action = 'check' then return '{}'::jsonb; end if;
  if p_action = 'read' then
    cursor_value := (p_payload->>'after')::bigint;
    if cursor_value is null or cursor_value < 0 or cursor_value > saved.sequence
      or cursor_value < saved.sequence-jsonb_array_length(saved.messages) then
      raise exception using errcode='22023', message='invalid_cursor';
    end if;
    select coalesce(jsonb_agg(item order by (item->>'sequence')::bigint),'[]') into pending
      from jsonb_array_elements(saved.messages) as item where (item->>'sequence')::bigint > cursor_value;
    -- Keep recent delivered events as well, so Last-Event-ID can recover a
    -- disconnect between writing to the network and the client receiving it.
    update public.tincall_mcp_sse set messages=(select coalesce(jsonb_agg(item order by (item->>'sequence')::bigint),'[]')
      from jsonb_array_elements(saved.messages) as item where (item->>'sequence')::bigint > greatest(0,cursor_value-64)),
      expires_at=clock_timestamp()+interval '3 minutes' where id=sid;
    return jsonb_build_object('messages',pending);
  elsif p_action = 'push' then
    pending := saved.messages || jsonb_build_array(jsonb_build_object('sequence',saved.sequence+1,'message',p_payload->'message'));
    if jsonb_array_length(pending) > 128 or octet_length(pending::text) > 33554432 then
      raise exception using errcode='P0001', message='sse_queue_full';
    end if;
    update public.tincall_mcp_sse set messages=pending,sequence=sequence+1 where id=sid;
    return '{}'::jsonb;
  end if;
  raise exception using errcode='22023', message='unknown_action';
end $$;
revoke all on function public.tincall_mcp_sse_command(text,uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.tincall_mcp_sse_command(text,uuid,text,jsonb) to service_role;
