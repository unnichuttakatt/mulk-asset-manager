-- Popups for the person at the computer, and a code they type before remote help opens.
-- Safe to re-run.

drop function if exists public.admin_accept_support(uuid, text);
drop function if exists public.admin_request_support(uuid, text);

create table if not exists public.agent_notices (
  id          uuid primary key default gen_random_uuid(),
  asset_id    uuid not null references public.assets(id) on delete cascade,
  message     text not null,
  created_at  timestamptz not null default now(),
  shown_at    timestamptz,
  constraint agent_notices_len check (char_length(message) between 1 and 400)
);

alter table public.agent_notices enable row level security;
drop policy if exists admins_read on public.agent_notices;
create policy admins_read on public.agent_notices
  for select to authenticated using (public.is_admin());
revoke all on public.agent_notices from anon, authenticated;
grant select on public.agent_notices to authenticated;

create or replace function public.admin_add_notice(p_asset_id uuid, p_message text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_message text := left(btrim(coalesce(p_message, '')), 400);
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;
  if not exists (select 1 from public.assets where id = p_asset_id) then
    raise exception 'Asset not found';
  end if;
  if char_length(v_message) < 1 then
    raise exception 'Write a message';
  end if;
  insert into public.agent_notices (asset_id, message) values (p_asset_id, v_message);
end;
$$;

create or replace function public.agent_take_notice(p_token text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  dev public.agent_devices%rowtype;
  note public.agent_notices%rowtype;
begin
  select * into dev from public.agent_devices where id = public.agent_device_id(p_token);
  if not found then
    return null;
  end if;
  select * into note from public.agent_notices
  where asset_id = dev.asset_id and shown_at is null
  order by created_at
  limit 1
  for update skip locked;
  if not found then
    return null;
  end if;
  update public.agent_notices set shown_at = now() where id = note.id;
  return note.message;
end;
$$;

create or replace function public.admin_accept_support(p_id uuid, p_code text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  job public.support_sessions%rowtype;
  v_code text;
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;
  v_code := public.support_code(p_code);
  if v_code is null then
    v_code := lpad((1 + floor(random() * 999998))::int::text, 6, '0');
  end if;
  select * into job from public.support_sessions where id = p_id and status = 'requested' for update;
  if not found then
    raise exception 'That help request was already handled';
  end if;
  update public.support_sessions
  set status = 'pending', assist_code = v_code, detail = null
  where id = job.id;
  return v_code;
end;
$$;

create or replace function public.admin_request_support(p_asset_id uuid, p_code text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;
  if not exists (select 1 from public.assets where id = p_asset_id and status <> 'disposed') then
    raise exception 'Asset not found';
  end if;
  v_code := public.support_code(p_code);
  if v_code is null then
    v_code := lpad((1 + floor(random() * 999998))::int::text, 6, '0');
  end if;
  update public.support_sessions
  set status = 'failed', ended_at = now(), assist_code = null,
      detail = case when status = 'requested' then 'Timed out before IT connected' else 'Timed out before the person answered' end
  where asset_id = p_asset_id
    and status in ('requested', 'pending')
    and requested_at < now() - interval '2 hours';
  update public.support_sessions
  set status = 'failed', ended_at = now(), assist_code = null, detail = 'The person did not answer'
  where asset_id = p_asset_id and status = 'asking' and prompted_at < now() - interval '10 minutes';
  if exists (
    select 1 from public.support_sessions
    where asset_id = p_asset_id and status in ('requested', 'pending', 'asking')
  ) then
    raise exception 'Remote help is already waiting on that computer';
  end if;
  insert into public.support_sessions (asset_id, assist_code, status, reason)
  values (p_asset_id, v_code, 'pending', 'IT asked to connect');
  return v_code;
end;
$$;

create or replace function public.admin_decline_support(p_id uuid, p_note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  job public.support_sessions%rowtype;
  v_note text;
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;
  v_note := btrim(coalesce(p_note, ''));
  if char_length(v_note) < 8 or char_length(v_note) > 300 then
    raise exception 'Write a short reason they can be told';
  end if;
  select * into job from public.support_sessions where id = p_id and status = 'requested' for update;
  if not found then
    raise exception 'That help request was already handled';
  end if;
  update public.support_sessions
  set status = 'failed', ended_at = now(), detail = v_note, assist_code = null
  where id = job.id;
  insert into public.agent_notices (asset_id, message)
  values (job.asset_id, left('IT did not start remote help. ' || v_note, 400));
end;
$$;

create or replace function public.agent_take_support(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  dev public.agent_devices%rowtype;
  job public.support_sessions%rowtype;
begin
  select * into dev from public.agent_devices where id = public.agent_device_id(p_token);
  if not found then
    raise exception 'This computer is not enrolled';
  end if;
  update public.support_sessions
  set status = 'failed', ended_at = now(), assist_code = null,
      detail = case when status = 'requested' then 'Timed out before IT connected' else 'Timed out before the person answered' end
  where asset_id = dev.asset_id
    and status in ('requested', 'pending')
    and requested_at < now() - interval '2 hours';
  update public.support_sessions
  set status = 'failed', ended_at = now(), assist_code = null, detail = 'The person did not answer'
  where asset_id = dev.asset_id and status = 'asking' and prompted_at < now() - interval '10 minutes';

  select * into job from public.support_sessions
  where asset_id = dev.asset_id and status = 'pending' and assist_code is not null
  order by requested_at
  limit 1
  for update skip locked;
  if not found then
    return null;
  end if;
  update public.support_sessions
  set status = 'asking', prompted_at = now()
  where id = job.id;
  update public.agent_devices set last_seen = now() where id = dev.id;
  return jsonb_build_object('id', job.id);
end;
$$;

create or replace function public.agent_confirm_support(p_token text, p_job uuid, p_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  dev public.agent_devices%rowtype;
  job public.support_sessions%rowtype;
  v_code text := btrim(coalesce(p_code, ''));
begin
  select * into dev from public.agent_devices where id = public.agent_device_id(p_token);
  if not found then
    raise exception 'This computer is not enrolled';
  end if;
  select * into job from public.support_sessions
  where id = p_job and asset_id = dev.asset_id and status = 'asking'
  for update;
  if not found then
    return false;
  end if;
  if v_code !~ '^[0-9]{6,8}$' or job.assist_code is distinct from v_code then
    return false;
  end if;
  update public.support_sessions
  set status = 'opened', opened_at = now(), assist_code = null,
      detail = 'The person entered the code. Quick Assist opened. The screen is not saved.'
  where id = job.id;
  update public.agent_devices set last_seen = now() where id = dev.id;
  return true;
end;
$$;

revoke all on function public.admin_add_notice(uuid, text) from public, anon;
grant execute on function public.admin_add_notice(uuid, text) to authenticated;
revoke all on function public.agent_take_notice(text) from public;
grant execute on function public.agent_take_notice(text) to anon, authenticated;
revoke all on function public.admin_accept_support(uuid, text) from public, anon;
revoke all on function public.admin_request_support(uuid, text) from public, anon;
grant execute on function public.admin_accept_support(uuid, text) to authenticated;
grant execute on function public.admin_request_support(uuid, text) to authenticated;

revoke all on function public.agent_confirm_support(text, uuid, text) from public;
grant execute on function public.agent_confirm_support(text, uuid, text) to anon, authenticated;

notify pgrst, 'reload schema';
