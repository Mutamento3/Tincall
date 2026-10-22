-- A phone already reads active-call events at least every 25 seconds. Reuse
-- those reads as presence; MCP reads/replies and idle subscriptions do not
-- renew this lease. A terminated/offline phone cannot hold the account forever.
alter table public.tincall_calls add column phone_seen_at timestamptz not null default now();
create function public.tincall_call_presence(p_action text,p_owner uuid default null,p_call uuid default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c public.tincall_calls;
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception using errcode='42501',message='forbidden'; end if;
  if p_action='touch' then
    update public.tincall_calls set phone_seen_at=now() where id=p_call and owner_id=p_owner and status='active';
  elsif p_action='expire' then
    for c in select * from public.tincall_calls where ((status='active' and phone_seen_at<now()-interval '3 minutes') or (status='ringing' and created_at<now()-interval '60 seconds'))
      and (p_owner is null or owner_id=p_owner) order by owner_id,id loop
      perform 1 from public.tincall_owners where owner_id=c.owner_id for update;
      -- Recheck after locking. A concurrent phone read must win over an old scan.
      select * into c from public.tincall_calls where id=c.id and ((status='active' and phone_seen_at<now()-interval '3 minutes') or (status='ringing' and created_at<now()-interval '60 seconds')) for update;
      if found then
        perform public.tincall_command('call.end',jsonb_build_object('request_id',gen_random_uuid(),'call_id',c.id,'epoch',c.epoch,'reason',case when c.status='ringing' then 'missed' else 'phone_disconnected' end),c.owner_id);
      end if;
    end loop;
  else raise exception using errcode='22023',message='unknown_action';
  end if;
  return '{}'::jsonb;
end $$;
revoke all on function public.tincall_call_presence(text,uuid,uuid) from public,anon,authenticated;
grant execute on function public.tincall_call_presence(text,uuid,uuid) to service_role;
