-- =====================================================================
--  Laptop control tab. Run once in Supabase → SQL Editor, after schema.sql.
--  Safe to re-run. Stores decisions only: no keystrokes, screenshots, or file contents.
-- =====================================================================

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

-- Connection and printer mode. Safe if the tables were created by an earlier run.
alter table public.laptop_controls add column if not exists connection text not null default 'not_connected';
alter table public.laptop_controls drop constraint if exists laptop_controls_connection_check;
alter table public.laptop_controls add constraint laptop_controls_connection_check
  check (connection in ('not_connected','enrolled'));

alter table public.laptop_controls add column if not exists print_mode text not null default 'open';
alter table public.laptop_controls drop constraint if exists laptop_controls_print_mode_check;
alter table public.laptop_controls add constraint laptop_controls_print_mode_check
  check (print_mode in ('open','release','mono','stopped'));
