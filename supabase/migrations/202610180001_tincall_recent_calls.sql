-- Only the connector may select an owner/contact scope; role credentials are
-- authenticated and scoped by the shared HTTP/MCP service before this RPC.
create function public.tincall_recent_calls(p_owner uuid, p_contact text default null, p_limit integer default 10)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception using errcode='42501', message='forbidden';
  end if;
  if p_owner is null then raise exception using errcode='42501', message='unauthorized'; end if;
  if p_limit is null or p_limit < 1 or p_limit > 50 then
    raise exception using errcode='22023', message='invalid_limit';
  end if;
  return jsonb_build_object('calls', (select coalesce(jsonb_agg(to_jsonb(q) order by q.started_at desc,q.call_id desc),'[]'::jsonb)
    from (select id as call_id,created_at as started_at,ended_at,status,
      coalesce(length(trim(summary))>0,false) as has_summary
      from public.tincall_calls where owner_id=p_owner and (p_contact is null or contact_id=p_contact)
      order by created_at desc,id desc limit p_limit) q));
end $$;
revoke all on function public.tincall_recent_calls(uuid,text,integer) from public, anon, authenticated;
grant execute on function public.tincall_recent_calls(uuid,text,integer) to service_role;
