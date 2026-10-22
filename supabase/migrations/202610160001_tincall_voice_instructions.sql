alter table public.tincall_calls
  add column tts_expression_prompt text not null default '',
  add column voice_instructions_sent boolean not null default false;

-- The phone may retry this write after a lost response. It is deliberately
-- idempotent and keeps the sent marker unchanged once a wait has claimed it.
create function public.tincall_set_voice_prompt(p_call uuid, p_prompt text, p_owner uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  u uuid := auth.uid();
  c public.tincall_calls;
begin
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception using errcode='42501', message='forbidden';
  end if;
  u := p_owner;
  if u is null then raise exception using errcode='42501', message='unauthorized'; end if;
  if p_prompt is null or length(p_prompt) > 100000 then
    raise exception using errcode='22023', message='invalid_expression_prompt';
  end if;
  insert into public.tincall_owners(owner_id) values(u) on conflict do nothing;
  perform 1 from public.tincall_owners where owner_id=u for update;
  update public.tincall_calls
    set tts_expression_prompt=p_prompt
    where id=p_call and owner_id=u and status <> 'ended'
    returning * into c;
  if c.id is null then raise exception using errcode='P0002', message='call_not_found'; end if;
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.tincall_set_voice_prompt(uuid,text,uuid) from public, anon, authenticated;
grant execute on function public.tincall_set_voice_prompt(uuid,text,uuid) to service_role;

-- Claiming is a single conditional UPDATE under the owner lock. Exactly one
-- concurrent waiter receives the stored prompt and flips the marker.
create function public.tincall_claim_voice_instructions(p_call uuid, p_owner uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  u uuid := auth.uid();
  prompt text;
begin
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception using errcode='42501', message='forbidden';
  end if;
  u := p_owner;
  if u is null then raise exception using errcode='42501', message='unauthorized'; end if;
  insert into public.tincall_owners(owner_id) values(u) on conflict do nothing;
  perform 1 from public.tincall_owners where owner_id=u for update;
  update public.tincall_calls
    set voice_instructions_sent=true
    where id=p_call and owner_id=u and status='active' and not voice_instructions_sent
    returning tts_expression_prompt into prompt;
  if not found then return jsonb_build_object('voice_instructions',null); end if;
  return jsonb_build_object('voice_instructions',
    case when coalesce(prompt,'')='' then
      '你的回复会被实时朗读成语音，请写适合说出口的口语。'
    else
      '你的回复会被实时朗读成语音，请写适合说出口的口语。' || E'\n' || prompt
    end);
end $$;
revoke all on function public.tincall_claim_voice_instructions(uuid,uuid) from public, anon, authenticated;
grant execute on function public.tincall_claim_voice_instructions(uuid,uuid) to service_role;
