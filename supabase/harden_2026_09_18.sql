-- Security hardening, 2026-09-18. Safe to re-run.
--
-- 1. Reads required only "signed in". Anyone able to create an auth account
--    (public sign-up, a leaked invite) could read the whole schedule. Now a
--    reader must also have a profiles row, which only invite-coach creates.
-- 2. anon (not signed in) held every privilege on every table, TRUNCATE
--    included. RLS stopped it; now the grants are gone too, so a single bad
--    policy can't expose anything to the open internet.
-- 3. log_activity() was callable through the API, so any user could forge
--    activity-log entries. Only the triggers may call it now. (A trigger
--    fires regardless of EXECUTE on its function; that's checked only at
--    CREATE TRIGGER.)
-- 4. Three plain functions still resolved names through a mutable
--    search_path.

-- 1 ------------------------------------------------------------------------
drop policy if exists "app_settings_select" on app_settings;
drop policy if exists "bookings_select"     on bookings;
drop policy if exists "field_slots_select"  on field_slots;
drop policy if exists "teams_select"        on teams;
drop policy if exists "waitlist_select"     on waitlist;
do $$
declare r record;
begin
  for r in select tablename, policyname from pg_policies
           where schemaname = 'public' and cmd = 'SELECT'
             and tablename in ('app_settings','bookings','field_slots','teams','waitlist')
  loop
    execute format('drop policy %I on %I', r.policyname, r.tablename);
  end loop;
end $$;
create policy members_read on app_settings for select to authenticated using (current_user_role() is not null);
create policy members_read on bookings     for select to authenticated using (current_user_role() is not null);
create policy members_read on field_slots  for select to authenticated using (current_user_role() is not null);
create policy members_read on teams        for select to authenticated using (current_user_role() is not null);
create policy members_read on waitlist     for select to authenticated using (current_user_role() is not null);

-- 2 ------------------------------------------------------------------------
revoke all on all tables    in schema public from anon;
revoke all on all sequences in schema public from anon;
alter default privileges in schema public revoke all on tables    from anon;
alter default privileges in schema public revoke all on sequences from anon;
revoke truncate, trigger, references on all tables in schema public from authenticated;

-- 3 ------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig, p.proname,
                  format_type(p.prorettype, null) as ret
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public'
  loop
    execute format('revoke execute on function %s from public, anon', r.sig);
    -- Policies call these as the signed-in user, so they must stay callable.
    if r.proname in ('current_user_role','current_user_gender','team_priority_unlocked',
                     'slot_is_allowed','grade_rank') then
      execute format('grant execute on function %s to authenticated', r.sig);
    else
      execute format('revoke execute on function %s from authenticated', r.sig);
    end if;
  end loop;
end $$;
alter default privileges in schema public revoke execute on functions from public, anon;

-- 4 ------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proconfig is null
  loop
    execute format('alter function %s set search_path = public', r.sig);
  end loop;
end $$;
