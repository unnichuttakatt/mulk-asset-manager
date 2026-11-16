-- Remote sign-in lock is turned off. A single-computer install is turned off.
-- Bulk install stays, and it requires the install password. Sign-in uses the admin password.

update public.laptop_controls
set locked = false, lock_reason = null
where locked or lock_reason is not null;

update public.install_jobs
set status = 'failed',
    finished_at = now(),
    detail = 'Cancelled. Single-computer install is turned off.'
where status = 'pending';

create or replace function public.keep_sign_in_open()
returns trigger
language plpgsql
as $$
begin
  new.locked := false;
  new.lock_reason := null;
  return new;
end;
$$;

drop trigger if exists laptop_controls_no_remote_lock on public.laptop_controls;
create trigger laptop_controls_no_remote_lock
  before insert or update on public.laptop_controls
  for each row execute function public.keep_sign_in_open();

revoke all on function public.keep_sign_in_open() from public, anon, authenticated;

create table if not exists public.install_passwords (
  id int primary key default 1 check (id = 1),
  password_hash text not null,
  updated_at timestamptz not null default now(),
  updated_by text
);

alter table public.install_passwords enable row level security;
revoke all on public.install_passwords from public, anon, authenticated;

create or replace function public.admin_has_install_password()
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select case
    when not public.is_admin() then false
    else exists (select 1 from public.install_passwords where id = 1)
  end;
$$;

create or replace function public.admin_set_install_password(p_password text)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;
  if p_password is null or char_length(p_password) < 12 or char_length(p_password) > 64 then
    raise exception 'Use 12 to 64 characters.';
  end if;
  if p_password !~ '[A-Z]' or p_password !~ '[a-z]' or p_password !~ '[0-9]' then
    raise exception 'Include an upper-case letter, a lower-case letter, and a digit.';
  end if;
  insert into public.install_passwords (id, password_hash, updated_at, updated_by)
  values (1, extensions.crypt(p_password, extensions.gen_salt('bf')), now(), public.current_email())
  on conflict (id) do update
  set password_hash = excluded.password_hash,
      updated_at = now(),
      updated_by = public.current_email();
end;
$$;

create or replace function public.admin_queue_install(
  p_asset_id uuid,
  p_name text,
  p_url text,
  p_silent_args text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;
  raise exception 'Single-computer install is turned off. Use Bulk install.';
end;
$$;

create or replace function public.admin_queue_bulk_install(
  p_asset_ids uuid[],
  p_name text,
  p_url text,
  p_silent_args text,
  p_password text
) returns integer
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_name text;
  v_url text;
  v_args text;
  v_hash text;
  v_id uuid;
  v_count integer := 0;
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;
  if p_asset_ids is null or cardinality(p_asset_ids) < 1 or cardinality(p_asset_ids) > 200 then
    raise exception 'Choose between 1 and 200 computers.';
  end if;
  select password_hash into v_hash from public.install_passwords where id = 1;
  if v_hash is null or extensions.crypt(p_password, v_hash) is distinct from v_hash then
    raise exception 'The install password is wrong.';
  end if;
  v_name := left(btrim(coalesce(p_name, '')), 80);
  v_url := left(btrim(coalesce(p_url, '')), 500);
  v_args := nullif(left(btrim(coalesce(p_silent_args, '')), 200), '');
  if char_length(v_name) < 1 then
    raise exception 'Name the software';
  end if;
  if v_url !~ '^https://' or v_url ~ '^https://[^/[:space:]]*@' then
    raise exception 'The installer link must start with https:// and cannot contain a password.';
  end if;
  if v_args ~ '[;&|`$<>]' then
    raise exception 'Silent arguments cannot contain shell characters';
  end if;
  if right(lower(split_part(split_part(v_url, '?', 1), '#', 1)), 4) not in ('.msi', '.exe') then
    raise exception 'The link must end in .msi or .exe';
  end if;
  foreach v_id in array p_asset_ids loop
    if exists (
      select 1 from public.assets
      where id = v_id and status <> 'disposed'
    ) then
      insert into public.install_jobs (asset_id, name, source_url, silent_args, status)
      values (v_id, v_name, v_url, v_args, 'pending');
      v_count := v_count + 1;
    end if;
  end loop;
  if v_count = 0 then
    raise exception 'None of those assets can take an install.';
  end if;
  return v_count;
end;
$$;

revoke all on function public.admin_has_install_password() from public, anon;
grant execute on function public.admin_has_install_password() to authenticated;
revoke all on function public.admin_set_install_password(text) from public, anon;
grant execute on function public.admin_set_install_password(text) to authenticated;
revoke all on function public.admin_queue_install(uuid, text, text, text) from public, anon;
grant execute on function public.admin_queue_install(uuid, text, text, text) to authenticated;
revoke all on function public.admin_queue_bulk_install(uuid[], text, text, text, text) from public, anon;
grant execute on function public.admin_queue_bulk_install(uuid[], text, text, text, text) to authenticated;

notify pgrst, 'reload schema';
