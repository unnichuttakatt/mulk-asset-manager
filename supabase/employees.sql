-- =====================================================================
--  Employees. Run this once in Supabase → SQL Editor → Run.
--  Safe to re-run. People already named on an asset are copied in.
--  Later check-outs add a missing person automatically.
-- =====================================================================

create table if not exists public.employees (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  email          text,
  department     text,
  site           text,
  phone          text,
  job_title      text,
  employee_code  text,
  active         boolean not null default true,
  notes          text,
  origin         text not null default 'manual' check (origin in ('manual', 'asset')),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint employees_name_not_blank check (btrim(name) <> '')
);

create unique index if not exists employees_name_key on public.employees (lower(btrim(name)));
create index if not exists employees_department_idx on public.employees (department);

drop trigger if exists employees_touch on public.employees;
create trigger employees_touch before update on public.employees
for each row execute function public.touch_updated_at();

alter table public.employees enable row level security;

drop policy if exists admins_all on public.employees;
create policy admins_all on public.employees
  for all to authenticated using (public.is_admin()) with check (public.is_admin());

revoke all on public.employees from anon;
grant select, insert, update, delete on public.employees to authenticated;

-- Keep the list in step with assignments. A blank name does nothing.
create or replace function public.ensure_employee_from_assignment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := nullif(btrim(coalesce(new.assigned_to, '')), '');
begin
  if v_name is null then
    return new;
  end if;
  insert into public.employees (name, department, site, origin)
  values (
    v_name,
    nullif(btrim(coalesce(new.department, '')), ''),
    nullif(btrim(coalesce(new.site, '')), ''),
    'asset'
  )
  on conflict (lower(btrim(name))) do nothing;
  return new;
end $$;

drop trigger if exists assets_ensure_employee on public.assets;
create trigger assets_ensure_employee
after insert or update of assigned_to on public.assets
for each row execute function public.ensure_employee_from_assignment();

revoke execute on function public.ensure_employee_from_assignment() from public, anon, authenticated;

-- People already on the register, one row per name.
insert into public.employees (name, department, site, origin)
select distinct on (lower(btrim(assigned_to)))
  btrim(assigned_to),
  nullif(btrim(coalesce(department, '')), ''),
  nullif(btrim(coalesce(site, '')), ''),
  'asset'
from public.assets
where nullif(btrim(coalesce(assigned_to, '')), '') is not null
order by lower(btrim(assigned_to)), updated_at desc nulls last
on conflict (lower(btrim(name))) do nothing;

notify pgrst, 'reload schema';
