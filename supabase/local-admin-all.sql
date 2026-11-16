-- One local Administrator password for every computer that has Mulk Agent.
-- The password stays only until that computer applies it, then it is deleted.

create or replace function public.admin_set_all_local_passwords(p_password text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
begin
  if not public.is_admin() then
    raise exception 'Not authorised';
  end if;
  if p_password is null or char_length(p_password) < 12 or char_length(p_password) > 64 then
    raise exception 'Use 12 to 64 characters';
  end if;
  if p_password !~ '[A-Z]' or p_password !~ '[a-z]' or p_password !~ '[0-9]' then
    raise exception 'Include an upper-case letter, a lower-case letter, and a digit';
  end if;
  insert into public.local_admin_resets (asset_id, password, requested_by, requested_at, applied_at, result)
  select distinct a.id, p_password, public.current_email(), now(), null::timestamptz, null::text
  from public.assets a
  join public.agent_devices d on d.asset_id = a.id
  where a.status <> 'disposed'
  on conflict (asset_id) do update
  set password = excluded.password,
      requested_by = excluded.requested_by,
      requested_at = now(),
      applied_at = null,
      result = null;
  get diagnostics v_count = row_count;
  if v_count = 0 then
    raise exception 'No computer has Mulk Agent installed yet.';
  end if;
  return v_count;
end;
$$;

revoke all on function public.admin_set_all_local_passwords(text) from public, anon;
grant execute on function public.admin_set_all_local_passwords(text) to authenticated;

notify pgrst, 'reload schema';
