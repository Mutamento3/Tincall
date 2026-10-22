-- Included by both CLI migrations and the App's deployment/update flow.
-- IF NOT EXISTS / CREATE OR REPLACE also adopt the former manually applied image SQL.
alter table public.tincall_messages add column if not exists images jsonb;

-- Reuse the existing locked, idempotent command instead of duplicating its lifecycle.
-- Its text-only validation requires a nonempty value. The temporary label is confined
-- to this transaction; the real (possibly empty) text is restored before commit.
create or replace function public.tincall_image_command(p_action text, p_payload jsonb, p_owner uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  result jsonb;
  normalized jsonb := p_payload;
begin
  if coalesce(auth.role(),'') <> 'service_role' or p_owner is null then
    raise exception using errcode='42501',message='forbidden';
  end if;
  if p_action = 'call.input' then
    if jsonb_typeof(p_payload->'images') is distinct from 'array' then
      raise exception using errcode='22023',message='invalid_images';
    end if;
    if jsonb_array_length(p_payload->'images') not between 1 and 4
      or jsonb_typeof(p_payload->'text') is distinct from 'string' then
      raise exception using errcode='22023',message='invalid_images';
    end if;
    if length(trim(p_payload->>'text')) = 0 then
      normalized := jsonb_set(normalized, '{text}', '"[图片]"'::jsonb);
      -- Preserve exact input text in the idempotency comparison too.
      normalized := normalized || jsonb_build_object('image_input_text', p_payload->>'text');
    end if;
    result := public.tincall_command(p_action, normalized, p_owner);
    update public.tincall_messages set text = p_payload->>'text', images = p_payload->'images'
      where owner_id = p_owner and call_id = (p_payload->>'call_id')::uuid
        and id = (result->>'input_id')::uuid;
  elsif p_action = 'record.delete' then
    result := public.tincall_command(p_action, p_payload, p_owner);
    -- The optional backup and connector call share their call UUID media namespace.
    update public.tincall_messages set images = null
      where owner_id = p_owner and call_id = (p_payload->>'record_id')::uuid;
  else
    raise exception using errcode='22023',message='unknown_action';
  end if;
  return result;
end $$;
revoke all on function public.tincall_image_command(text,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.tincall_image_command(text,jsonb,uuid) to service_role;
