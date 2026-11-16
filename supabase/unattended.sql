-- A computer still running after office hours, 8:00 AM to 6:00 PM.
-- Run once after it-admin.sql. Safe to re-run.
-- The screen and the keyboard are not collected.

alter table public.compliance_alerts drop constraint if exists compliance_alerts_kind_check;
alter table public.compliance_alerts add constraint compliance_alerts_kind_check
  check (kind in ('bitlocker', 'defender', 'firewall', 'disk', 'serial', 'local_admin', 'startup', 'banned', 'unattended'));

create or replace function public.agent_report_unattended(p_token text, p_idle_seconds integer, p_local_date text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  dev public.agent_devices%rowtype;
  v_date text;
begin
  select * into dev from public.agent_devices where id = public.agent_device_id(p_token);
  if not found then
    raise exception 'This computer is not enrolled';
  end if;
  if p_idle_seconds is null or p_idle_seconds < 7200 or p_idle_seconds > 2592000 then
    raise exception 'The computer must still be on for at least 2 hours after 6:00 PM';
  end if;
  v_date := btrim(coalesce(p_local_date, ''));
  if v_date !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'The computer date is not valid';
  end if;
  perform public.raise_compliance(
    dev.asset_id,
    'unattended',
    'Still on after office hours (8:00 AM to 6:00 PM) on ' || v_date || '. The person is reminded to shut the computer down when leaving the office.'
  );
  update public.agent_devices set last_seen = now() where id = dev.id;
end;
$$;

revoke all on function public.agent_report_unattended(text, integer, text) from public;
grant execute on function public.agent_report_unattended(text, integer, text) to anon, authenticated;

notify pgrst, 'reload schema';
