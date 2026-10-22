-- SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
-- SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

-- Resolve a compact call reference within the authenticated owner/contact only.
-- Ambiguous prefixes fail closed, including collisions with ended calls.
create function public.tincall_resolve_call_context(p_owner uuid,p_contact text,p_prefix text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare ids uuid[];
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception using errcode='42501',message='forbidden'; end if;
  if p_prefix is null or p_prefix !~ '^[0-9a-f]{12}$' then raise exception using errcode='22023',message='invalid_call_context'; end if;
  select array_agg(id) into ids from (
    select id from public.tincall_calls where owner_id=p_owner and (p_contact is null or contact_id=p_contact)
      and left(replace(id::text,'-',''),12)=p_prefix limit 2
  ) matches;
  if coalesce(array_length(ids,1),0)<>1 then raise exception using errcode='P0001',message='call_context_not_found'; end if;
  return jsonb_build_object('call_id',ids[1]);
end $$;
revoke all on function public.tincall_resolve_call_context(uuid,text,text) from public,anon,authenticated;
grant execute on function public.tincall_resolve_call_context(uuid,text,text) to service_role;

-- Bound anonymous registration and reclaim idle state without invalidating live grants or requests.
create or replace function public.tincall_oauth(p_action text,p_payload jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  q public.tincall_oauth_requests;
  g public.tincall_oauth_grants;
  result jsonb;
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception using errcode='42501',message='forbidden'; end if;
  if p_action='client.create' then
    -- Serialize the unauthenticated DCR quota, including concurrent instances.
    perform pg_advisory_xact_lock(742811031);
    delete from public.tincall_oauth_requests where expires_at<=now();
    delete from public.tincall_oauth_grants where refresh_expires_at<=now();
    delete from public.tincall_oauth_clients c where created_at<now()-interval '10 minutes'
      and not exists(select 1 from public.tincall_oauth_requests r where r.client_id=c.client_id)
      and not exists(select 1 from public.tincall_oauth_grants live_grant where live_grant.client_id=c.client_id);
    if (select count(*) from public.tincall_oauth_clients where created_at>now()-interval '1 minute')>=20 then
      raise exception using errcode='P0001',message='oauth_limit';
    end if;
    if (select count(*) from public.tincall_oauth_clients)>=1000 then
      -- Keep a short grace period between registration and authorization.
      delete from public.tincall_oauth_clients where client_id in (
        select c.client_id from public.tincall_oauth_clients c where c.created_at<now()-interval '1 minute'
          and not exists(select 1 from public.tincall_oauth_requests r where r.client_id=c.client_id)
          and not exists(select 1 from public.tincall_oauth_grants live_grant where live_grant.client_id=c.client_id)
        order by c.created_at,c.client_id limit 1
      );
    end if;
    if (select count(*) from public.tincall_oauth_clients)>=1000 then raise exception using errcode='P0001',message='oauth_limit'; end if;
    insert into public.tincall_oauth_clients(client_id,client_name,redirect_uris)
      values(p_payload->>'client_id',p_payload->>'client_name',p_payload->'redirect_uris');
    return '{}'::jsonb;
  elsif p_action='client.get' then
    select to_jsonb(c) into result from public.tincall_oauth_clients c where client_id=p_payload->>'client_id';return result;
  elsif p_action='request.create' then
    perform 1 from public.tincall_oauth_clients where client_id=p_payload->>'client_id' for update;
    delete from public.tincall_oauth_requests where expires_at<=now();
    if (select count(*) from public.tincall_oauth_requests where client_id=p_payload->>'client_id')>=20 then raise exception using errcode='P0001',message='oauth_limit'; end if;
    insert into public.tincall_oauth_requests(id,user_code,client_id,redirect_uri,state,resource,code_challenge)
      values(p_payload->>'id',p_payload->>'user_code',p_payload->>'client_id',p_payload->>'redirect_uri',p_payload->>'state',p_payload->>'resource',p_payload->>'code_challenge');
    return '{}'::jsonb;
  elsif p_action='request.get' then
    select to_jsonb(r) into result from public.tincall_oauth_requests r where expires_at>now()
      and case when p_payload ? 'id' then id=p_payload->>'id'
        when p_payload ? 'code' then code=p_payload->>'code' else user_code=p_payload->>'user_code' end;
    return result;
  elsif p_action='request.decide' then
    update public.tincall_oauth_requests set owner_id=(p_payload->>'owner_id')::uuid,contact_id=p_payload->>'contact_id',
      denied=(p_payload->>'denied')::boolean,code=case when (p_payload->>'denied')::boolean then null else p_payload->>'code' end
      where user_code=p_payload->>'user_code' and expires_at>now() and code is null and not denied returning * into q;
    return case when q.id is null then null else '{}'::jsonb end;
  elsif p_action='exchange' then
    delete from public.tincall_oauth_requests where code=p_payload->>'code' and expires_at>now() and not denied
      and client_id=p_payload->>'client_id' and redirect_uri=p_payload->>'redirect_uri' and resource=p_payload->>'resource'
      returning * into q;
    if q.id is null then return null; end if;
    if not exists(select 1 from public.tincall_mcp_roles where owner_id=q.owner_id and contact_id=q.contact_id) then return null; end if;
    delete from public.tincall_oauth_grants where refresh_expires_at<=now();
    insert into public.tincall_oauth_grants(access_token,refresh_token,client_id,owner_id,contact_id,resource)
      values(p_payload->>'access_token',p_payload->>'refresh_token',q.client_id,q.owner_id,q.contact_id,q.resource);
    return '{}'::jsonb;
  elsif p_action='refresh' then
    update public.tincall_oauth_grants set access_token=p_payload->>'access_token',refresh_token=p_payload->>'next_refresh_token',access_expires_at=now()+interval '1 hour'
      where refresh_token=p_payload->>'refresh_token' and client_id=p_payload->>'client_id' and resource=p_payload->>'resource' and refresh_expires_at>now()
      and exists(select 1 from public.tincall_mcp_roles r where r.owner_id=tincall_oauth_grants.owner_id and r.contact_id=tincall_oauth_grants.contact_id)
      returning * into g;
    return case when g.access_token is null then null else '{}'::jsonb end;
  elsif p_action='authenticate' then
    select jsonb_build_object('owner_id',a.owner_id,'contact_id',a.contact_id) into result
      from public.tincall_oauth_grants a join public.tincall_mcp_roles r on r.owner_id=a.owner_id and r.contact_id=a.contact_id
      where access_token=p_payload->>'access_token' and resource=p_payload->>'resource' and access_expires_at>now() and refresh_expires_at>now();
    return result;
  elsif p_action='revoke' then
    delete from public.tincall_oauth_grants where client_id=p_payload->>'client_id' and (access_token=p_payload->>'token' or refresh_token=p_payload->>'token');
    return '{}'::jsonb;
  end if;
  raise exception using errcode='22023',message='unknown_action';
end $$;
revoke all on function public.tincall_oauth(text,jsonb) from public,anon,authenticated;
grant execute on function public.tincall_oauth(text,jsonb) to service_role;
