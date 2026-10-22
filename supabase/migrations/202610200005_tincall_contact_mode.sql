-- SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
-- SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

-- Keep a saved MCP identity while its phone contact uses another call mode.
alter table public.tincall_mcp_roles add column call_mode text not null default 'mcp'
  check (call_mode in ('standalone','mcp','backend'));

create function public.tincall_contact_mode(p_action text,p_owner uuid,p_payload jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare saved public.tincall_mcp_roles; c public.tincall_calls;
begin
  if coalesce(auth.role(),'')<>'service_role' or p_owner is null then
    raise exception using errcode='42501',message='forbidden';
  end if;
  if p_action='get' then
    select * into saved from public.tincall_mcp_roles where owner_id=p_owner and contact_id=p_payload->>'contact_id';
  elsif p_action='set' then
    if p_payload->>'call_mode' is null or p_payload->>'call_mode' not in ('standalone','mcp','backend') then
      raise exception using errcode='22023',message='invalid_call_mode';
    end if;
    perform 1 from public.tincall_owners where owner_id=p_owner for update;
    update public.tincall_mcp_roles set call_mode=p_payload->>'call_mode',updated_at=clock_timestamp()
      where owner_id=p_owner and role_id=(p_payload->>'role_id')::uuid returning * into saved;
    if not found then raise exception using errcode='P0002',message='contact_not_found'; end if;
    if saved.call_mode<>'mcp' then
      for c in select * from public.tincall_calls where owner_id=p_owner and contact_id=saved.contact_id and source='mcp' and status='ringing' loop
        perform public.tincall_command('call.end',jsonb_build_object('request_id',gen_random_uuid(),'call_id',c.id,'epoch',c.epoch,'reason','contact_mode_changed'),p_owner);
      end loop;
    end if;
  else raise exception using errcode='22023',message='unknown_action';
  end if;
  return jsonb_build_object('call_mode',saved.call_mode);
end $$;
revoke all on function public.tincall_contact_mode(text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.tincall_contact_mode(text,uuid,jsonb) to service_role;
