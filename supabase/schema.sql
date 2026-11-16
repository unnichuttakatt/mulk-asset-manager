-- =====================================================================
--  Mulk Holdings – IT Asset Manager : database schema for Supabase
--  Run this whole file once in Supabase → SQL Editor → New query → Run.
--  It is safe to re-run (it only creates what is missing / replaces functions).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
--  Admin allow-list. Only logged-in users whose e-mail is in this table
--  can see or change anything. Add your IT team's e-mails here.
-- ---------------------------------------------------------------------
create table if not exists public.app_admins (
  email     text primary key,
  added_at  timestamptz not null default now()
);

-- >>> CHANGE / ADD YOUR ADMIN E-MAILS HERE <<<
insert into public.app_admins (email) values ('unni@mulkholdings.com')
on conflict do nothing;

create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.app_admins
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

create or replace function public.current_email()
returns text language sql stable
as $$ select coalesce(auth.jwt() ->> 'email', 'system') $$;

-- ---------------------------------------------------------------------
--  Assets
-- ---------------------------------------------------------------------
create table if not exists public.assets (
  id               uuid primary key default gen_random_uuid(),
  tag              text not null unique,
  description      text,
  category         text,
  brand            text,
  model            text,
  serial_no        text,
  configuration    text,
  status           text not null default 'available'
                   check (status in ('available','checked_out','under_repair','broken','lost','disposed')),
  site             text,
  location         text,
  department       text,
  assigned_to      text,
  purchase_date    date,
  purchase_cost    numeric(12,2),
  vendor           text,
  warranty_expiry  date,
  notes            text,
  last_event_date  date,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  created_by       text default public.current_email()
);

create index if not exists assets_status_idx   on public.assets (status);
create index if not exists assets_category_idx on public.assets (category);
create index if not exists assets_assigned_idx on public.assets (assigned_to);

-- ---------------------------------------------------------------------
--  History: every check-out, check-in, repair, disposal, edit, import…
-- ---------------------------------------------------------------------
create table if not exists public.asset_events (
  id            bigint generated always as identity primary key,
  asset_id      uuid not null references public.assets(id) on delete cascade,
  action        text not null,
  event_date    date not null default current_date,
  from_status   text,
  to_status     text,
  assigned_to   text,
  department    text,
  site          text,
  location      text,
  vendor        text,
  cost          numeric(12,2),
  notes         text,
  performed_by  text not null default public.current_email(),
  created_at    timestamptz not null default now()
);

create index if not exists asset_events_asset_idx on public.asset_events (asset_id, created_at desc);
create index if not exists asset_events_created_idx on public.asset_events (created_at desc);

-- keep updated_at fresh
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

drop trigger if exists assets_touch on public.assets;
create trigger assets_touch before update on public.assets
for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
--  Row level security: admins only
-- ---------------------------------------------------------------------
alter table public.assets       enable row level security;
alter table public.asset_events enable row level security;
alter table public.app_admins   enable row level security;

drop policy if exists admins_all on public.assets;
create policy admins_all on public.assets
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists admins_all on public.asset_events;
create policy admins_all on public.asset_events
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists admins_all on public.app_admins;
create policy admins_all on public.app_admins
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

revoke all on public.assets, public.asset_events, public.app_admins from anon;
grant select, insert, update, delete on public.assets, public.asset_events, public.app_admins to authenticated;

-- ---------------------------------------------------------------------
--  asset_action(): one call that changes status AND writes history
--  actions: check_out, check_in, repair, repair_done, broken, lost,
--           dispose, restore, move, note
-- ---------------------------------------------------------------------
create or replace function public.asset_action(
  p_asset_id    uuid,
  p_action      text,
  p_event_date  date    default current_date,
  p_assigned_to text    default null,
  p_department  text    default null,
  p_site        text    default null,
  p_location    text    default null,
  p_vendor      text    default null,
  p_cost        numeric default null,
  p_notes       text    default null
) returns public.assets
language plpgsql
set search_path = public
as $$
declare
  a public.assets;
  new_status text;
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;

  select * into a from public.assets where id = p_asset_id for update;
  if not found then raise exception 'Asset not found'; end if;

  p_event_date  := coalesce(p_event_date, current_date);
  p_assigned_to := nullif(trim(p_assigned_to), '');
  p_department  := nullif(trim(p_department), '');
  p_site        := nullif(trim(p_site), '');
  p_location    := nullif(trim(p_location), '');

  case p_action
    when 'check_out' then
      if a.status <> 'available' then
        raise exception 'Only available assets can be checked out (this one is %)', replace(a.status, '_', ' ');
      end if;
      if p_assigned_to is null then raise exception 'Choose who the asset is assigned to'; end if;
      new_status    := 'checked_out';
      a.assigned_to := p_assigned_to;
      a.department  := coalesce(p_department, a.department);
      a.site        := coalesce(p_site, a.site);
      a.location    := coalesce(p_location, a.location);

    when 'check_in' then
      if a.status <> 'checked_out' then
        raise exception 'Only checked-out assets can be checked in';
      end if;
      p_assigned_to := a.assigned_to;           -- record who returned it
      new_status    := 'available';
      a.assigned_to := null;
      a.department  := null;
      a.site        := coalesce(p_site, a.site);
      a.location    := coalesce(p_location, a.location);

    when 'repair' then
      if a.status in ('under_repair','disposed','lost') then
        raise exception 'Asset cannot be sent for repair while %', replace(a.status, '_', ' ');
      end if;
      new_status := 'under_repair';

    when 'repair_done' then
      if a.status <> 'under_repair' then raise exception 'Asset is not under repair'; end if;
      new_status := case when a.assigned_to is not null then 'checked_out' else 'available' end;

    when 'broken' then
      if a.status in ('disposed') then raise exception 'Asset is disposed'; end if;
      new_status := 'broken';

    when 'lost' then
      if a.status in ('disposed') then raise exception 'Asset is disposed'; end if;
      new_status := 'lost';

    when 'dispose' then
      if a.status = 'disposed' then raise exception 'Asset is already disposed'; end if;
      new_status    := 'disposed';
      p_assigned_to := coalesce(p_assigned_to, a.assigned_to);
      a.assigned_to := null;
      a.department  := null;

    when 'restore' then
      if a.status not in ('broken','lost','disposed') then
        raise exception 'Only broken, lost or disposed assets can be restored';
      end if;
      new_status    := 'available';
      a.assigned_to := null;

    when 'move' then
      new_status   := a.status;
      a.site       := coalesce(p_site, a.site);
      a.location   := coalesce(p_location, a.location);
      a.department := coalesce(p_department, a.department);

    when 'note' then
      new_status := a.status;

    else
      raise exception 'Unknown action %', p_action;
  end case;

  insert into public.asset_events
    (asset_id, action, event_date, from_status, to_status,
     assigned_to, department, site, location, vendor, cost, notes)
  values
    (a.id, p_action, p_event_date, a.status, new_status,
     coalesce(p_assigned_to, a.assigned_to), coalesce(p_department, a.department),
     coalesce(p_site, a.site), coalesce(p_location, a.location),
     nullif(trim(p_vendor), ''), p_cost, nullif(trim(p_notes), ''));

  update public.assets set
    status          = new_status,
    assigned_to     = a.assigned_to,
    department      = a.department,
    site            = a.site,
    location        = a.location,
    last_event_date = case when p_action = 'note' then last_event_date else p_event_date end
  where id = a.id
  returning * into a;

  return a;
end $$;

-- ---------------------------------------------------------------------
--  import_assets(): bulk insert / update by Asset Tag (used by Import page)
-- ---------------------------------------------------------------------
create or replace function public.import_assets(p_rows jsonb)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  r jsonb;
  existing public.assets;
  new_id uuid;
  n_new int := 0;
  n_upd int := 0;
  v_status text;
begin
  if not public.is_admin() then raise exception 'Not authorised'; end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    if coalesce(trim(r->>'tag'), '') = '' then continue; end if;

    v_status := coalesce(nullif(r->>'status', ''), 'available');
    if v_status not in ('available','checked_out','under_repair','broken','lost','disposed') then
      v_status := 'available';
    end if;

    select * into existing from public.assets where tag = trim(r->>'tag');

    if not found then
      insert into public.assets (tag, description, category, brand, model, serial_no, configuration,
        status, site, location, department, assigned_to, purchase_date, purchase_cost, vendor,
        warranty_expiry, notes, last_event_date, created_at)
      values (trim(r->>'tag'), nullif(r->>'description',''), nullif(r->>'category',''),
        nullif(r->>'brand',''), nullif(r->>'model',''), nullif(r->>'serial_no',''),
        nullif(r->>'configuration',''), v_status, nullif(r->>'site',''), nullif(r->>'location',''),
        nullif(r->>'department',''), nullif(r->>'assigned_to',''),
        nullif(r->>'purchase_date','')::date, nullif(r->>'purchase_cost','')::numeric,
        nullif(r->>'vendor',''), nullif(r->>'warranty_expiry','')::date, nullif(r->>'notes',''),
        nullif(r->>'last_event_date','')::date,
        coalesce(nullif(r->>'created_at','')::timestamptz, now()))
      returning id into new_id;

      insert into public.asset_events (asset_id, action, event_date, to_status, assigned_to,
        department, site, location, notes)
      values (new_id, 'imported',
        coalesce(nullif(r->>'last_event_date','')::date, current_date),
        v_status, nullif(r->>'assigned_to',''), nullif(r->>'department',''),
        nullif(r->>'site',''), nullif(r->>'location',''), 'Imported from spreadsheet');
      n_new := n_new + 1;
    else
      update public.assets set
        description   = coalesce(nullif(r->>'description',''), description),
        category      = coalesce(nullif(r->>'category',''), category),
        brand         = coalesce(nullif(r->>'brand',''), brand),
        model         = coalesce(nullif(r->>'model',''), model),
        serial_no     = coalesce(nullif(r->>'serial_no',''), serial_no),
        configuration = coalesce(nullif(r->>'configuration',''), configuration),
        status        = v_status,
        site          = nullif(r->>'site',''),
        location      = nullif(r->>'location',''),
        department    = nullif(r->>'department',''),
        assigned_to   = nullif(r->>'assigned_to',''),
        purchase_date = coalesce(nullif(r->>'purchase_date','')::date, purchase_date),
        purchase_cost = coalesce(nullif(r->>'purchase_cost','')::numeric, purchase_cost),
        vendor        = coalesce(nullif(r->>'vendor',''), vendor),
        warranty_expiry = coalesce(nullif(r->>'warranty_expiry','')::date, warranty_expiry),
        notes         = coalesce(nullif(r->>'notes',''), notes),
        last_event_date = coalesce(nullif(r->>'last_event_date','')::date, last_event_date)
      where id = existing.id;

      insert into public.asset_events (asset_id, action, from_status, to_status, assigned_to,
        department, site, location, notes)
      values (existing.id, 'updated', existing.status, v_status, nullif(r->>'assigned_to',''),
        nullif(r->>'department',''), nullif(r->>'site',''), nullif(r->>'location',''),
        'Updated from spreadsheet import');
      n_upd := n_upd + 1;
    end if;
  end loop;

  return jsonb_build_object('inserted', n_new, 'updated', n_upd);
end $$;

-- log manual creates / edits made through the form
create or replace function public.log_asset_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if current_setting('app.skip_log', true) = 'on' then return new; end if;
  if tg_op = 'INSERT' then
    insert into public.asset_events (asset_id, action, to_status, assigned_to, department, site, location, notes)
    values (new.id, 'created', new.status, new.assigned_to, new.department, new.site, new.location, 'Asset created');
  end if;
  return new;
end $$;

drop trigger if exists assets_log_insert on public.assets;
create trigger assets_log_insert after insert on public.assets
for each row execute function public.log_asset_change();

-- the import function writes its own 'imported' event; silence the insert trigger there
create or replace function public.import_assets_wrapper(p_rows jsonb)
returns jsonb language plpgsql set search_path = public as $$
begin
  perform set_config('app.skip_log', 'on', true);
  return public.import_assets(p_rows);
end $$;

grant execute on function public.asset_action(uuid,text,date,text,text,text,text,text,numeric,text) to authenticated;
grant execute on function public.import_assets(jsonb) to authenticated;
grant execute on function public.import_assets_wrapper(jsonb) to authenticated;
grant execute on function public.is_admin() to authenticated;
revoke execute on function public.asset_action(uuid,text,date,text,text,text,text,text,numeric,text) from anon, public;
revoke execute on function public.import_assets(jsonb) from anon, public;
revoke execute on function public.import_assets_wrapper(jsonb) from anon, public;

-- hardening (Supabase security advisor)
alter function public.current_email() set search_path = public;
alter function public.touch_updated_at() set search_path = public;
revoke execute on function public.log_asset_change() from public, anon, authenticated;
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- ---------------------------------------------------------------------
--  Laptop control (also in supabase/laptop-control.sql for existing databases)
-- ---------------------------------------------------------------------

create table if not exists public.laptop_controls (
  asset_id           uuid primary key references public.assets(id) on delete cascade,
  admin              text not null default 'standard' check (admin in ('standard','elevated','standing')),
  elevation_ends_at  timestamptz,
  admin_note         text,
  policy             text not null default 'baseline'
                     check (policy in ('baseline','finance','engineering','legal','executive','field')),
  hold               boolean not null default false,
  hold_reason        text,
  updated_at         timestamptz not null default now(),
  updated_by         text default public.current_email()
);

drop trigger if exists laptop_controls_touch on public.laptop_controls;
create trigger laptop_controls_touch before update on public.laptop_controls
for each row execute function public.touch_updated_at();

create table if not exists public.laptop_control_events (
  id            bigint generated always as identity primary key,
  asset_id      uuid not null references public.assets(id) on delete cascade,
  action        text not null,
  detail        text,
  performed_by  text not null default public.current_email(),
  created_at    timestamptz not null default now()
);

create index if not exists laptop_control_events_asset_idx
  on public.laptop_control_events (asset_id, created_at desc);

alter table public.laptop_controls enable row level security;
alter table public.laptop_control_events enable row level security;

drop policy if exists admins_all on public.laptop_controls;
create policy admins_all on public.laptop_controls
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists admins_all on public.laptop_control_events;
create policy admins_all on public.laptop_control_events
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

revoke all on public.laptop_controls, public.laptop_control_events from anon;
grant select, insert, update, delete on public.laptop_controls, public.laptop_control_events to authenticated;
grant usage, select on sequence public.laptop_control_events_id_seq to authenticated;

alter table public.laptop_controls add column if not exists connection text not null default 'not_connected';
alter table public.laptop_controls drop constraint if exists laptop_controls_connection_check;
alter table public.laptop_controls add constraint laptop_controls_connection_check
  check (connection in ('not_connected','enrolled'));

alter table public.laptop_controls add column if not exists print_mode text not null default 'open';
alter table public.laptop_controls drop constraint if exists laptop_controls_print_mode_check;
alter table public.laptop_controls add constraint laptop_controls_print_mode_check
  check (print_mode in ('open','release','mono','stopped'));

create table if not exists public.admin_requests (
  id             bigint generated always as identity primary key,
  asset_id       uuid not null references public.assets(id) on delete cascade,
  requested_by   text not null,
  reason         text not null,
  status         text not null default 'pending' check (status in ('pending','approved','denied')),
  window_choice  text,
  decision_note  text,
  decided_by     text,
  created_at     timestamptz not null default now(),
  decided_at     timestamptz,
  constraint admin_requests_reason_len check (char_length(reason) between 8 and 500),
  constraint admin_requests_window_check check (window_choice is null or window_choice in ('1h','4h','close'))
);

create index if not exists admin_requests_status_idx on public.admin_requests (status, created_at desc);

create table if not exists public.copy_activity (
  id           bigint generated always as identity primary key,
  asset_id     uuid not null references public.assets(id) on delete cascade,
  channel      text not null check (channel in ('usb','clipboard','cloud','mail','print')),
  file_name    text not null,
  label        text,
  action       text not null check (action in ('blocked','warned','quarantined')),
  happened_at  timestamptz not null default now(),
  reported_by  text not null default public.current_email(),
  constraint copy_activity_name_len check (char_length(file_name) between 1 and 180),
  constraint copy_activity_label_len check (label is null or char_length(label) <= 80)
);

create index if not exists copy_activity_when_idx on public.copy_activity (happened_at desc);

alter table public.admin_requests enable row level security;
alter table public.copy_activity enable row level security;

drop policy if exists admins_all on public.admin_requests;
create policy admins_all on public.admin_requests
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists admins_all on public.copy_activity;
create policy admins_all on public.copy_activity
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

revoke all on public.admin_requests, public.copy_activity from anon;
grant select, insert, update, delete on public.admin_requests, public.copy_activity to authenticated;
grant usage, select on sequence public.admin_requests_id_seq to authenticated;
grant usage, select on sequence public.copy_activity_id_seq to authenticated;

-- ---------------------------------------------------------------------
--  Mulk Agent (also in supabase/agent.sql)
-- ---------------------------------------------------------------------
create extension if not exists pgcrypto;

do $$
begin
  if to_regclass('public.laptop_controls') is null then
    raise exception 'Run supabase/laptop-control.sql before supabase/agent.sql';
  end if;
end $$;

alter table public.laptop_controls add column if not exists connection text not null default 'not_connected';

create table if not exists public.agent_codes (
  id          uuid primary key default gen_random_uuid(),
  asset_id    uuid not null references public.assets(id) on delete cascade,
  code_hash   text not null unique,
  expires_at  timestamptz not null,
  used_at     timestamptz,
  created_by  text not null default public.current_email(),
  created_at  timestamptz not null default now()
);

create table if not exists public.agent_devices (
  id            uuid primary key default gen_random_uuid(),
  asset_id      uuid not null references public.assets(id) on delete cascade,
  token_hash    text not null unique,
  hostname      text,
  windows_user  text,
  last_seen     timestamptz,
  created_at    timestamptz not null default now()
);

alter table public.agent_codes enable row level security;
alter table public.agent_devices enable row level security;

drop policy if exists admins_read on public.agent_codes;
create policy admins_read on public.agent_codes
  for select to authenticated using (public.is_admin());

drop policy if exists admins_read on public.agent_devices;
create policy admins_read on public.agent_devices
  for select to authenticated using (public.is_admin());

revoke all on public.agent_codes, public.agent_devices from anon, authenticated;
grant select on public.agent_codes, public.agent_devices to authenticated;

create or replace function public.agent_create_code(p_asset_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  plain text := '';
  i int;
  b bytea;
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;
  if not exists (select 1 from public.assets where id = p_asset_id and status <> 'disposed') then
    raise exception 'Asset not found';
  end if;
  for i in 1..8 loop
    b := gen_random_bytes(1);
    plain := plain || substr(alphabet, 1 + (get_byte(b, 0) % length(alphabet)), 1);
  end loop;
  insert into public.agent_codes (asset_id, code_hash, expires_at)
  values (p_asset_id, encode(digest(plain, 'sha256'), 'hex'), now() + interval '24 hours');
  return plain;
end;
$$;

create or replace function public.agent_device_id(p_token text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from public.agent_devices
  where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
$$;

create or replace function public.agent_policy(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  dev public.agent_devices%rowtype;
  asset public.assets%rowtype;
  ctrl public.laptop_controls%rowtype;
  has_ctrl boolean := false;
  live_admin text := 'standard';
  policy_name text := 'baseline';
  ends_at timestamptz;
  hold_flag boolean := false;
  hold_text text;
  usb text := 'block';
  rules jsonb;
begin
  select * into dev from public.agent_devices
  where id = public.agent_device_id(p_token);
  if not found then
    raise exception 'This computer is not enrolled';
  end if;
  update public.agent_devices set last_seen = now() where id = dev.id;
  select * into asset from public.assets where id = dev.asset_id;
  select * into ctrl from public.laptop_controls where asset_id = dev.asset_id;
  has_ctrl := found;

  if has_ctrl then
    policy_name := coalesce(ctrl.policy, 'baseline');
    ends_at := ctrl.elevation_ends_at;
    hold_flag := coalesce(ctrl.hold, false);
    hold_text := ctrl.hold_reason;
    if ctrl.admin = 'standing' then
      live_admin := 'standing';
    elsif ctrl.admin = 'elevated' and ctrl.elevation_ends_at is not null and ctrl.elevation_ends_at > now() then
      live_admin := 'elevated';
    end if;
    usb := case policy_name when 'engineering' then 'read' when 'field' then 'read' else 'block' end;
    if hold_flag then
      live_admin := 'standard';
      usb := 'block';
    end if;
  end if;

  rules := case policy_name
    when 'finance' then '["USB storage blocked","Personal cloud blocked","Mail to outside addresses held","Printing a labeled file blocked","Copying a labeled file blocked"]'::jsonb
    when 'engineering' then '["USB storage read only","Personal cloud warns","Mail to outside addresses warns","Printing a labeled file warns","Copying a labeled file warns"]'::jsonb
    when 'legal' then '["USB storage blocked","Personal cloud blocked","Mail to outside addresses held","Printing a labeled file blocked","Copying a labeled file blocked"]'::jsonb
    when 'executive' then '["USB storage blocked","Personal cloud blocked","Mail to outside addresses held","Printing a labeled file warns","Copying a labeled file blocked"]'::jsonb
    when 'field' then '["USB storage read only","Personal cloud blocked","Mail to outside addresses warns","Printing a labeled file warns","Copying a labeled file warns"]'::jsonb
    else '["USB storage blocked","Personal cloud blocked","Mail to outside addresses held","Printing a labeled file warns","Copying a labeled file warns"]'::jsonb
  end;

  return jsonb_build_object(
    'tag', asset.tag,
    'description', asset.description,
    'assigned_to', asset.assigned_to,
    'hostname', dev.hostname,
    'windows_user', dev.windows_user,
    'admin', live_admin,
    'elevation_ends_at', ends_at,
    'policy', policy_name,
    'usb', usb,
    'hold', hold_flag,
    'hold_reason', hold_text,
    'rules', rules
  );
end;
$$;

create or replace function public.agent_enroll(p_code text, p_hostname text, p_windows_user text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  code_row public.agent_codes%rowtype;
  token text;
  asset public.assets%rowtype;
begin
  if p_code is null or length(trim(p_code)) < 8 then
    raise exception 'Enter the 8 character code from Control';
  end if;
  if p_windows_user is null or length(trim(p_windows_user)) < 2 then
    raise exception 'Enter the Windows account that uses this computer';
  end if;

  select * into code_row from public.agent_codes
  where code_hash = encode(digest(upper(trim(p_code)), 'sha256'), 'hex')
    and used_at is null
    and expires_at > now()
  for update;
  if not found then
    raise exception 'That code is used or expired. Create a new one in Control';
  end if;

  update public.agent_codes set used_at = now() where id = code_row.id;
  select * into asset from public.assets where id = code_row.asset_id;
  token := encode(gen_random_bytes(32), 'hex');

  insert into public.agent_devices (asset_id, token_hash, hostname, windows_user, last_seen)
  values (
    code_row.asset_id,
    encode(digest(token, 'sha256'), 'hex'),
    left(coalesce(p_hostname, ''), 80),
    left(trim(p_windows_user), 80),
    now()
  );

  insert into public.laptop_controls (asset_id, connection)
  values (code_row.asset_id, 'enrolled')
  on conflict (asset_id) do update set connection = 'enrolled', updated_at = now();

  return jsonb_build_object(
    'token', token,
    'tag', asset.tag,
    'description', asset.description,
    'windows_user', left(trim(p_windows_user), 80)
  );
end;
$$;

create or replace function public.agent_request(p_token text, p_requested_by text, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  asset_id uuid;
begin
  select d.asset_id into asset_id from public.agent_devices d
  where d.id = public.agent_device_id(p_token);
  if asset_id is null then
    raise exception 'This computer is not enrolled';
  end if;
  if p_requested_by is null or length(trim(p_requested_by)) < 2 then
    raise exception 'Name the person who is asking';
  end if;
  if p_reason is null or char_length(trim(p_reason)) < 8 or char_length(trim(p_reason)) > 500 then
    raise exception 'Write a reason between a sentence and a short paragraph';
  end if;
  insert into public.admin_requests (asset_id, requested_by, reason, status)
  values (asset_id, left(trim(p_requested_by), 120), trim(p_reason), 'pending');
  update public.agent_devices set last_seen = now() where id = public.agent_device_id(p_token);
end;
$$;

create or replace function public.agent_report(
  p_token text,
  p_channel text,
  p_file_name text,
  p_label text,
  p_action text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  asset_id uuid;
begin
  select d.asset_id into asset_id from public.agent_devices d
  where d.id = public.agent_device_id(p_token);
  if asset_id is null then
    raise exception 'This computer is not enrolled';
  end if;
  if p_channel not in ('usb','clipboard','cloud','mail','print') then
    raise exception 'Unknown channel';
  end if;
  if p_action not in ('blocked','warned','quarantined') then
    raise exception 'Unknown result';
  end if;
  if p_file_name is null or char_length(trim(p_file_name)) < 1 or char_length(trim(p_file_name)) > 180 then
    raise exception 'Use the file name only, up to 180 characters';
  end if;
  if p_label is not null and char_length(p_label) > 80 then
    raise exception 'Keep the label short';
  end if;
  insert into public.copy_activity (asset_id, channel, file_name, label, action)
  values (asset_id, p_channel, trim(p_file_name), nullif(trim(coalesce(p_label, '')), ''), p_action);
  update public.agent_devices set last_seen = now() where id = public.agent_device_id(p_token);
end;
$$;

revoke all on function public.agent_create_code(uuid) from public, anon;
grant execute on function public.agent_create_code(uuid) to authenticated;

revoke all on function public.agent_device_id(text) from public, anon, authenticated;

revoke all on function public.agent_policy(text) from public;
revoke all on function public.agent_enroll(text, text, text) from public;
revoke all on function public.agent_request(text, text, text) from public;
revoke all on function public.agent_report(text, text, text, text, text) from public;

grant execute on function public.agent_policy(text) to anon, authenticated;
grant execute on function public.agent_enroll(text, text, text) to anon, authenticated;
grant execute on function public.agent_request(text, text, text) to anon, authenticated;
grant execute on function public.agent_report(text, text, text, text, text) to anon, authenticated;

-- =====================================================================
--  Asset admin reports. Run once after supabase/agent.sql.
--  Safe to re-run.
--  Stores program name, version, and publisher from the Windows uninstall
--  list, plus a removable-drive notice. No documents, keystrokes, or screens.
-- =====================================================================

do $$
begin
  if to_regclass('public.agent_devices') is null then
    raise exception 'Run supabase/agent.sql before supabase/asset-admin.sql';
  end if;
end $$;

create table if not exists public.installed_software (
  id            uuid primary key default gen_random_uuid(),
  asset_id      uuid not null references public.assets(id) on delete cascade,
  name          text not null,
  name_key      text not null,
  version       text,
  publisher     text,
  installed_on  date,
  first_seen    timestamptz not null default now(),
  last_seen     timestamptz not null default now(),
  removed_at    timestamptz,
  constraint installed_software_name_len check (char_length(name) between 1 and 160),
  constraint installed_software_version_len check (version is null or char_length(version) <= 80),
  constraint installed_software_publisher_len check (publisher is null or char_length(publisher) <= 120)
);

create unique index if not exists installed_software_asset_name_idx
  on public.installed_software (asset_id, name_key);

create index if not exists installed_software_asset_idx
  on public.installed_software (asset_id) where removed_at is null;

create table if not exists public.software_events (
  id               bigint generated always as identity primary key,
  asset_id         uuid not null references public.assets(id) on delete cascade,
  name             text not null,
  version          text,
  publisher        text,
  kind             text not null check (kind in ('installed', 'removed')),
  happened_at      timestamptz not null default now(),
  acknowledged_at  timestamptz,
  acknowledged_by  text,
  constraint software_events_name_len check (char_length(name) between 1 and 160)
);

create index if not exists software_events_open_idx
  on public.software_events (happened_at desc) where acknowledged_at is null;

alter table public.copy_activity add column if not exists acknowledged_at timestamptz;
alter table public.copy_activity add column if not exists acknowledged_by text;

-- Rows that already existed are the baseline, not a new alert.
update public.copy_activity
set acknowledged_at = coalesce(acknowledged_at, happened_at),
    acknowledged_by = coalesce(acknowledged_by, 'baseline')
where acknowledged_at is null;

alter table public.installed_software enable row level security;
alter table public.software_events enable row level security;

drop policy if exists admins_read on public.installed_software;
create policy admins_read on public.installed_software
  for select to authenticated using (public.is_admin());

drop policy if exists admins_read on public.software_events;
create policy admins_read on public.software_events
  for select to authenticated using (public.is_admin());

drop policy if exists admins_ack on public.software_events;
create policy admins_ack on public.software_events
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

revoke all on public.installed_software, public.software_events from anon, authenticated;
grant select on public.installed_software to authenticated;
grant select, update on public.software_events to authenticated;
grant usage, select on sequence public.software_events_id_seq to authenticated;

create or replace function public.agent_sync_software(p_token text, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  dev_id uuid;
  v_asset uuid;
  baseline boolean;
  item jsonb;
  n text;
  nk text;
  ver text;
  pub text;
  inst date;
  seen text[] := '{}';
  added int := 0;
  removed int := 0;
  kept int := 0;
  existing public.installed_software%rowtype;
begin
  dev_id := public.agent_device_id(p_token);
  if dev_id is null then
    raise exception 'This computer is not enrolled';
  end if;
  select d.asset_id into v_asset from public.agent_devices d where d.id = dev_id;

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'Software list must be a list';
  end if;
  if jsonb_array_length(p_items) = 0 then
    raise exception 'Refusing an empty software list';
  end if;
  if jsonb_array_length(p_items) > 500 then
    raise exception 'Send at most 500 programs';
  end if;

  select not exists (
    select 1 from public.installed_software s where s.asset_id = v_asset
  ) into baseline;

  for item in select value from jsonb_array_elements(p_items)
  loop
    n := left(btrim(coalesce(item->>'name', '')), 160);
    if n = '' then
      continue;
    end if;
    nk := lower(n);
    if nk = any (seen) then
      continue;
    end if;
    seen := array_append(seen, nk);
    ver := nullif(left(btrim(coalesce(item->>'version', '')), 80), '');
    pub := nullif(left(btrim(coalesce(item->>'publisher', '')), 120), '');
    begin
      inst := nullif(item->>'installed_on', '')::date;
    exception when others then
      inst := null;
    end;

    select * into existing from public.installed_software
    where asset_id = v_asset and name_key = nk;

    if not found then
      insert into public.installed_software (asset_id, name, name_key, version, publisher, installed_on)
      values (v_asset, n, nk, ver, pub, inst);
      if baseline then
        kept := kept + 1;
      else
        insert into public.software_events (asset_id, name, version, publisher, kind)
        values (v_asset, n, ver, pub, 'installed');
        added := added + 1;
      end if;
    else
      update public.installed_software
      set name = n,
          version = ver,
          publisher = coalesce(pub, publisher),
          installed_on = coalesce(inst, installed_on),
          last_seen = now(),
          removed_at = null
      where id = existing.id;
      if existing.removed_at is not null and not baseline then
        insert into public.software_events (asset_id, name, version, publisher, kind)
        values (v_asset, n, ver, pub, 'installed');
        added := added + 1;
      else
        kept := kept + 1;
      end if;
    end if;
  end loop;

  if not baseline then
    for existing in
      select * from public.installed_software
      where asset_id = v_asset
        and removed_at is null
        and not (name_key = any (seen))
    loop
      update public.installed_software
      set removed_at = now(), last_seen = now()
      where id = existing.id;
      insert into public.software_events (asset_id, name, version, publisher, kind)
      values (v_asset, existing.name, existing.version, existing.publisher, 'removed');
      removed := removed + 1;
    end loop;
  end if;

  update public.agent_devices set last_seen = now() where id = dev_id;

  return jsonb_build_object(
    'baseline', baseline,
    'added', added,
    'removed', removed,
    'kept', kept
  );
end;
$$;

revoke all on function public.agent_sync_software(text, jsonb) from public;
grant execute on function public.agent_sync_software(text, jsonb) to anon, authenticated;

notify pgrst, 'reload schema';
