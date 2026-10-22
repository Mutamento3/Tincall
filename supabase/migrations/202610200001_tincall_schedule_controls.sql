-- SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
-- SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

alter table public.tincall_schedules add column week_day smallint
  check (week_day is null or (week_day between 1 and 7 and daily_time is not null));

-- Align both saved times and the existing worker's next daily candidate to the
-- selected local weekday. Calendar arithmetic preserves the local clock over DST.
create function public.tincall_schedule_next() returns trigger
language plpgsql set search_path = '' as $$
declare local_day date; due timestamptz;
begin
  if new.week_day is not null then
    local_day := (new.next_at at time zone new.time_zone)::date;
    local_day := local_day + ((new.week_day-extract(isodow from local_day)::integer+7)%7);
    due := (local_day+new.daily_time) at time zone new.time_zone;
    if due<new.next_at then due := ((local_day+7)+new.daily_time) at time zone new.time_zone; end if;
    new.next_at := due;
  end if;
  return new;
end $$;
revoke all on function public.tincall_schedule_next() from public,anon,authenticated;
create trigger tincall_schedule_next before insert or update of next_at,week_day,daily_time,time_zone
  on public.tincall_schedules for each row execute function public.tincall_schedule_next();

-- Keep schedule edits and enable/disable writes atomic with the existing owner
-- lock and request ledger, so retrying an old write cannot undo a newer switch.
create function public.tincall_schedule_command(p_action text, p_payload jsonb, p_owner uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  old public.tincall_requests;
  s public.tincall_schedules;
  req uuid := (p_payload->>'request_id')::uuid;
  result jsonb;
begin
  if coalesce(auth.role(),'') <> 'service_role' or p_owner is null then
    raise exception using errcode='42501',message='forbidden';
  end if;
  if p_action not in ('schedule.put','schedule.enabled') or req is null then
    raise exception using errcode='22023',message='invalid_schedule';
  end if;
  if (p_action='schedule.enabled' or p_payload ? 'enabled') and
    jsonb_typeof(p_payload->'enabled') is distinct from 'boolean' then
    raise exception using errcode='22023',message='invalid_enabled';
  end if;
  insert into public.tincall_owners(owner_id) values(p_owner) on conflict do nothing;
  perform 1 from public.tincall_owners where owner_id=p_owner for update;
  select * into old from public.tincall_requests where owner_id=p_owner and request_id=req;
  if found then
    if old.retired then raise exception using errcode='P0001',message='operation_retired'; end if;
    if old.action<>p_action or old.payload<>p_payload then
      raise exception using errcode='P0001',message='idempotency_conflict';
    end if;
    return old.response;
  end if;
  if p_action='schedule.put' then
    result := public.tincall_command(p_action,p_payload,p_owner);
    if p_payload ? 'enabled' then
      update public.tincall_schedules set enabled=(p_payload->>'enabled')::boolean
        where id=(p_payload->>'schedule_id')::uuid and owner_id=p_owner;
    end if;
    update public.tincall_schedules set week_day=(p_payload->>'week_day')::smallint,
      next_at=case when daily_time is not null then public.tincall_next_daily(daily_time,time_zone,now()) else next_at end
      where id=(p_payload->>'schedule_id')::uuid and owner_id=p_owner;
  else
    select * into s from public.tincall_schedules
      where id=(p_payload->>'schedule_id')::uuid and owner_id=p_owner for update;
    if not found then raise exception using errcode='P0002',message='schedule_not_found'; end if;
    update public.tincall_schedules set enabled=(p_payload->>'enabled')::boolean,
      next_at=case when (p_payload->>'enabled')::boolean and not s.enabled and s.daily_time is not null
        then public.tincall_next_daily(s.daily_time,s.time_zone,now()) else s.next_at end
      where id=s.id;
    result := jsonb_build_object('ok',true);
    insert into public.tincall_requests(owner_id,request_id,action,payload,response)
      values(p_owner,req,p_action,p_payload,result);
  end if;
  return result;
end $$;
revoke all on function public.tincall_schedule_command(text,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.tincall_schedule_command(text,jsonb,uuid) to service_role;
