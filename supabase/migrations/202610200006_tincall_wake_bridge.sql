-- SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
-- SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

-- A bridge credential grants one contact's MCP tools and wake stream only.
create table public.tincall_wake_bridges (
  owner_id uuid not null,
  contact_id text not null,
  token text not null unique check (token ~ '^tcwake_[0-9a-f]{64}$'),
  primary key (owner_id,contact_id),
  foreign key (owner_id,contact_id) references public.tincall_mcp_roles(owner_id,contact_id) on delete cascade
);
alter table public.tincall_wake_bridges enable row level security;
revoke all on public.tincall_wake_bridges from public,anon,authenticated;

create function public.tincall_wake_bridge(p_action text,p_owner uuid default null,p_payload jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb; saved text;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception using errcode='42501',message='forbidden'; end if;
  if p_action='authenticate' then
    select jsonb_build_object('owner_id',b.owner_id,'contact_id',b.contact_id,'wake_bridge',true)
      into result from public.tincall_wake_bridges b join public.tincall_mcp_roles r using(owner_id,contact_id)
      where b.token=p_payload->>'token' and r.call_mode='mcp';
    return result;
  end if;
  if p_owner is null then raise exception using errcode='42501',message='unauthorized'; end if;
  if p_action='list' then
    select coalesce(jsonb_agg(jsonb_build_object('contact_id',contact_id,'display_name',display_name)
      order by created_at,role_id),'[]') into result from public.tincall_mcp_roles
      where owner_id=p_owner and call_mode='mcp';
    return jsonb_build_object('contacts',result);
  end if;
  if p_action <> 'configuration' then raise exception using errcode='22023',message='unknown_action'; end if;
  perform 1 from public.tincall_mcp_roles where owner_id=p_owner and contact_id=p_payload->>'contact_id' and call_mode='mcp' for update;
  if not found then raise exception using errcode='P0002',message='contact_not_found'; end if;
  if coalesce(p_payload->>'token','') !~ '^tcwake_[0-9a-f]{64}$' then raise exception using errcode='22023',message='invalid_token'; end if;
  insert into public.tincall_wake_bridges(owner_id,contact_id,token)
    values(p_owner,p_payload->>'contact_id',p_payload->>'token') on conflict(owner_id,contact_id) do nothing;
  if coalesce((p_payload->>'rotate')::boolean,false) then
    update public.tincall_wake_bridges set token=p_payload->>'token' where owner_id=p_owner and contact_id=p_payload->>'contact_id';
  end if;
  select token into saved from public.tincall_wake_bridges where owner_id=p_owner and contact_id=p_payload->>'contact_id';
  return jsonb_build_object('token',saved);
end $$;
revoke all on function public.tincall_wake_bridge(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.tincall_wake_bridge(text,uuid,jsonb) to service_role;

-- Notify only when a real reply target exists, including every new user turn.
-- No text, recordings or credentials enter the realtime channel.
create function public.tincall_broadcast_wake() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c public.tincall_calls;
begin
  if new.type='reply.started' then
    select * into c from public.tincall_calls where id=new.call_id;
    if c.source='mcp' and c.status='active' then
      perform realtime.send(jsonb_build_object('call',jsonb_build_object(
        'id',c.id,'contact_id',c.contact_id,'source',c.source,'status',c.status,
        'epoch',c.epoch,'last_sequence',c.last_sequence)),
        'wake','tincall:wake:' || c.owner_id::text,true);
    end if;
  end if;
  return null;
end $$;
revoke all on function public.tincall_broadcast_wake() from public,anon,authenticated;
create trigger tincall_reply_wake after insert on public.tincall_events
for each row execute function public.tincall_broadcast_wake();
