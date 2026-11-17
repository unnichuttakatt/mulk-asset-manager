-- A computer installs without a code. It waits here until an admin assigns it to an asset.
-- Safe to re-run.

create table if not exists public.agent_pending (
  id             uuid primary key default gen_random_uuid(),
  token_hash     text not null unique,
  hostname       text not null,
  windows_user   text not null,
  account_names  text,
  created_at     timestamptz not null default now(),
  seen_at        timestamptz not null default now(),
  constraint agent_pending_host_len check (char_length(hostname) between 1 and 80),
  constraint agent_pending_user_len check (char_length(windows_user) between 2 and 120),
  constraint agent_pending_accounts_len check (account_names is null or char_length(account_names) <= 400)
);

create unique index if not exists agent_pending_host_user
  on public.agent_pending (lower(hostname), lower(windows_user));

alter table public.agent_pending enable row level security;

drop policy if exists admins_read on public.agent_pending;
create policy admins_read on public.agent_pending
  for select to authenticated using (public.is_admin());

revoke all on public.agent_pending from anon, authenticated;
grant select on public.agent_pending to authenticated;

create or replace function public.agent_register(
  p_hostname text,
  p_windows_user text,
  p_accounts text
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_host text := left(btrim(coalesce(p_hostname, '')), 80);
  v_user text := left(btrim(coalesce(p_windows_user, '')), 120);
  v_accounts text := nullif(left(btrim(coalesce(p_accounts, '')), 400), '');
  token text := encode(gen_random_bytes(32), 'hex');
  v_hash text;
begin
  if v_host = '' or char_length(v_host) > 80 or v_host ~ '[^A-Za-z0-9._-]' then
    raise exception 'The computer name is not valid';
  end if;
  if char_length(v_user) < 2 or char_length(v_user) > 120 or v_user ~ '[^A-Za-z0-9 ._@\\-]' then
    raise exception 'The Windows account is not valid';
  end if;
  if v_accounts is not null and v_accounts ~ '[^A-Za-z0-9 ._,@\\-]' then
    v_accounts := null;
  end if;
  if (select count(*) from public.agent_pending) >= 300
     and not exists (
       select 1 from public.agent_pending
       where lower(hostname) = lower(v_host) and lower(windows_user) = lower(v_user)
     ) then
    raise exception 'Too many computers are waiting. Assign or dismiss one in Control.';
  end if;
  v_hash := encode(digest(token, 'sha256'), 'hex');
  insert into public.agent_pending (token_hash, hostname, windows_user, account_names, seen_at)
  values (v_hash, v_host, v_user, v_accounts, now())
  on conflict ((lower(hostname)), (lower(windows_user))) do update
  set token_hash = excluded.token_hash,
      hostname = excluded.hostname,
      windows_user = excluded.windows_user,
      account_names = excluded.account_names,
      seen_at = now();
  return jsonb_build_object(
    'token', token,
    'hostname', v_host,
    'windows_user', v_user,
    'pending', true
  );
end;
$$;

create or replace function public.agent_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_hash text := encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
  waiting public.agent_pending%rowtype;
begin
  if exists (select 1 from public.agent_devices where token_hash = v_hash) then
    return jsonb_build_object('state', 'assigned');
  end if;
  select * into waiting from public.agent_pending where token_hash = v_hash;
  if not found then
    return jsonb_build_object('state', 'unknown');
  end if;
  update public.agent_pending set seen_at = now() where id = waiting.id;
  return jsonb_build_object(
    'state', 'pending',
    'hostname', waiting.hostname,
    'windows_user', waiting.windows_user
  );
end;
$$;

create or replace function public.admin_assign_pending(p_id uuid, p_asset_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  waiting public.agent_pending%rowtype;
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;
  if not exists (select 1 from public.assets where id = p_asset_id and status <> 'disposed') then
    raise exception 'Asset not found';
  end if;
  select * into waiting from public.agent_pending where id = p_id for update;
  if not found then
    raise exception 'That computer is no longer waiting';
  end if;
  delete from public.agent_devices where asset_id = p_asset_id;
  insert into public.agent_devices (asset_id, token_hash, hostname, windows_user, last_seen)
  values (p_asset_id, waiting.token_hash, waiting.hostname, waiting.windows_user, now());
  insert into public.laptop_controls (asset_id, connection)
  values (p_asset_id, 'enrolled')
  on conflict (asset_id) do update
  set connection = 'enrolled', updated_at = now();
  delete from public.agent_pending where id = waiting.id;
end;
$$;

create or replace function public.admin_dismiss_pending(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;
  delete from public.agent_pending where id = p_id;
end;
$$;

revoke all on function public.agent_register(text, text, text) from public;
revoke all on function public.agent_state(text) from public;
revoke all on function public.admin_assign_pending(uuid, uuid) from public, anon;
revoke all on function public.admin_dismiss_pending(uuid) from public, anon;

grant execute on function public.agent_register(text, text, text) to anon, authenticated;
grant execute on function public.agent_state(text) to anon, authenticated;
grant execute on function public.admin_assign_pending(uuid, uuid) to authenticated;
grant execute on function public.admin_dismiss_pending(uuid) to authenticated;

notify pgrst, 'reload schema';
