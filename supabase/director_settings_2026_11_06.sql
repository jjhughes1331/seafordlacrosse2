-- Directors lock the schedule and switch priority booking (JJ, 2026-11-06).
-- Seaford project only (ref gjpqwmcdejpvffdimddk). Paste into the SQL editor
-- and Run. One transaction: if any statement fails, nothing changes.
--
-- Before: only admins could update app_settings (security_hardening.sql,
-- enforce_app_settings_admin_update).
-- After:
--   - Admins: unchanged, any column.
--   - Directors: only schedule_locked (with its locked_by / locked_at stamp,
--     which must be themselves) and priority_booking_enabled. Forced ranks
--     (Push Past), season dates and everything else stay admin-only.
--   - Everyone else: refused, as before.
-- The lock covers both programs; a director's lock pauses every team's
-- booking, the same as an admin's.

begin;

create or replace function public.enforce_app_settings_admin_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  my_role text := (select p.role from profiles p where p.id = auth.uid());
  director_cols text[] := array['schedule_locked', 'locked_by', 'locked_at', 'priority_booking_enabled'];
begin
  if my_role = 'admin' then
    return new;
  end if;
  if my_role = 'director' then
    if (to_jsonb(new) - director_cols) is distinct from (to_jsonb(old) - director_cols) then
      raise exception 'Directors can lock the schedule and turn priority booking on or off. Ask an admin for the rest.'
        using errcode = '42501';
    end if;
    if new.locked_by is not null and new.locked_by is distinct from old.locked_by
       and new.locked_by <> auth.uid() then
      raise exception 'A lock is stamped with the person who locked it.'
        using errcode = '42501';
    end if;
    return new;
  end if;
  raise exception 'Only admins and directors can change these settings'
    using errcode = '42501';
end;
$$;

-- Row security needs no change: the live policy app_settings_update_admin_director
-- (checked 2026-11-06) already lets admins and directors update this row, so
-- the trigger above is what decides which columns a director may change.

commit;

-- Check: the function now names directors.
select position('director' in prosrc) > 0 as directors_allowed
from pg_proc where proname = 'enforce_app_settings_admin_update';
