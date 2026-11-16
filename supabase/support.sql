-- Visible remote support. Run once after it-admin.sql. Safe to re-run.
-- The person must choose Allow before Quick Assist opens. The screen is not saved.

create table if not exists public.support_sessions (
  id            uuid primary key default gen_random_uuid(),
  asset_id      uuid not null references public.assets(id) on delete cascade,
  status        text not null default 'requested',
  requested_by  text not null default public.current_email(),
  reason        text,
  assist_code   text,
  detail        text,
  requested_at  timestamptz not null default now(),
  prompted_at   timestamptz,
  opened_at     timestamptz,
  ended_at      timestamptz
);

alter table public.support_sessions add column if not exists reason text;
alter table public.support_sessions add column if not exists prompted_at timestamptz;

alter table public.support_sessions drop constraint if exists support_sessions_status_check;
alter table public.support_sessions add constraint support_sessions_status_check
  check (status in ('requested', 'pending', 'asking', 'opened', 'ended', 'failed'));

alter table public.support_sessions drop constraint if exists support_sessions_code_len;
alter table public.support_sessions add constraint support_sessions_code_len
  check (assist_code is null or assist_code ~ '^[0-9]{6,8}$');

alter table public.support_sessions drop constraint if exists support_sessions_detail_len;
alter table public.support_sessions add constraint support_sessions_detail_len
  check (detail is null or char_length(detail) <= 300);

alter table public.support_sessions drop constraint if exists support_sessions_reason_len;
alter table public.support_sessions add constraint support_sessions_reason_len
  check (reason is null or char_length(reason) <= 500);

alter table public.support_sessions enable row level security;

drop policy if exists admins_read on public.support_sessions;
create policy admins_read on public.support_sessions
  for select to authenticated using (public.is_admin());

revoke all on public.support_sessions from anon, authenticated;
grant select (id, asset_id, status, requested_by, reason, detail, requested_at, prompted_at, opened_at, ended_at)
  on public.support_sessions to authenticated;

create or replace function public.support_code(p_code text)
returns text
language plpgsql
immutable
as $$
declare
  v_code text;
begin
  v_code := nullif(btrim(coalesce(p_code, '')), '');
  if v_code is not null and v_code !~ '^[0-9]{6,8}$' then
    raise exception 'The Quick Assist code is 6 to 8 digits';
  end if;
  return v_code;
end;
$$;

revoke all on function public.support_code(text) from public, anon, authenticated;

create or replace function public.agent_request_support(p_token text, p_requested_by text, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  dev public.agent_devices%rowtype;
begin
  select * into dev from public.agent_devices where id = public.agent_device_id(p_token);
  if not found then
    raise exception 'This computer is not enrolled';
  end if;
  if exists (select 1 from public.laptop_controls where asset_id = dev.asset_id and locked) then
    raise exception 'This computer is locked. IT has to unlock it before remote help';
  end if;
  if p_requested_by is null or length(trim(p_requested_by)) < 2 then
    raise exception 'Name the person who is asking';
  end if;
  if p_reason is null or char_length(trim(p_reason)) < 8 or char_length(trim(p_reason)) > 500 then
    raise exception 'Write what you need help with, between a sentence and a short paragraph';
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
  if exists (
    select 1 from public.support_sessions
    where asset_id = dev.asset_id and status in ('requested', 'pending', 'asking')
  ) then
    raise exception 'Help is already waiting for IT';
  end if;
  insert into public.support_sessions (asset_id, requested_by, reason, status)
  values (dev.asset_id, left(trim(p_requested_by), 120), trim(p_reason), 'requested');
  update public.agent_devices set last_seen = now() where id = dev.id;
end;
$$;

create or replace function public.admin_request_support(p_asset_id uuid, p_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  job uuid;
  v_code text;
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;
  if not exists (select 1 from public.assets where id = p_asset_id and status <> 'disposed') then
    raise exception 'Asset not found';
  end if;
  if exists (select 1 from public.laptop_controls where asset_id = p_asset_id and locked) then
    raise exception 'Unlock the computer before starting remote support';
  end if;
  v_code := public.support_code(p_code);
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
  values (p_asset_id, v_code, 'pending', 'IT asked to connect')
  returning id into job;
  return job;
end;
$$;

create or replace function public.admin_accept_support(p_id uuid, p_code text)
returns uuid
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
  select * into job from public.support_sessions where id = p_id and status = 'requested' for update;
  if not found then
    raise exception 'That help request was already handled';
  end if;
  if exists (select 1 from public.laptop_controls where asset_id = job.asset_id and locked) then
    raise exception 'Unlock the computer before starting remote support';
  end if;
  update public.support_sessions
  set status = 'pending', assist_code = v_code
  where id = job.id;
  return job.id;
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
  where asset_id = dev.asset_id and status = 'pending'
  order by requested_at
  limit 1
  for update skip locked;
  if not found then
    return null;
  end if;
  update public.support_sessions
  set status = 'asking', prompted_at = now(), assist_code = null
  where id = job.id;
  update public.agent_devices set last_seen = now() where id = dev.id;
  return jsonb_build_object('id', job.id, 'assist_code', coalesce(job.assist_code, ''));
end;
$$;

create or replace function public.agent_finish_support(p_token text, p_job uuid, p_ok boolean, p_detail text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  dev public.agent_devices%rowtype;
begin
  select * into dev from public.agent_devices where id = public.agent_device_id(p_token);
  if not found then
    raise exception 'This computer is not enrolled';
  end if;
  update public.support_sessions
  set status = case when coalesce(p_ok, false) then 'opened' else 'failed' end,
      opened_at = case when coalesce(p_ok, false) then now() else null end,
      ended_at = case when coalesce(p_ok, false) then null else now() end,
      detail = left(coalesce(p_detail, ''), 300),
      assist_code = null
  where id = p_job and asset_id = dev.asset_id and status = 'asking';
  update public.agent_devices set last_seen = now() where id = dev.id;
end;
$$;

revoke all on function public.agent_request_support(text, text, text) from public;
grant execute on function public.agent_request_support(text, text, text) to anon, authenticated;
revoke all on function public.admin_request_support(uuid, text) from public, anon;
grant execute on function public.admin_request_support(uuid, text) to authenticated;
revoke all on function public.admin_accept_support(uuid, text) from public, anon;
grant execute on function public.admin_accept_support(uuid, text) to authenticated;
revoke all on function public.admin_decline_support(uuid, text) from public, anon;
grant execute on function public.admin_decline_support(uuid, text) to authenticated;
revoke all on function public.agent_take_support(text) from public;
grant execute on function public.agent_take_support(text) to anon, authenticated;
revoke all on function public.agent_finish_support(text, uuid, boolean, text) from public;
grant execute on function public.agent_finish_support(text, uuid, boolean, text) to anon, authenticated;

notify pgrst, 'reload schema';
