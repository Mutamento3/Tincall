-- SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
-- SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

-- Only routing metadata reaches the private owner channel. The authenticated
-- data service subscribes on behalf of its phone; no service key enters the App.
create function public.tincall_broadcast_incoming() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' or new.status is distinct from old.status then
    perform realtime.send(
      jsonb_build_object('call',jsonb_build_object(
        'id',new.id,'contact_id',new.contact_id,'source',new.source,
        'status',new.status,'epoch',new.epoch,'last_sequence',new.last_sequence)),
      'call_state','tincall:incoming:' || new.owner_id::text,true);
  end if;
  return null;
end $$;
revoke all on function public.tincall_broadcast_incoming() from public,anon,authenticated;
create trigger tincall_incoming_changed
after insert or update of status on public.tincall_calls
for each row execute function public.tincall_broadcast_incoming();
