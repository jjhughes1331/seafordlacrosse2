-- Database fixes from the 2026-11-10 audit. APPLIED to the live database on
-- 2026-11-10 (run once in the SQL editor; all four checks at the end were
-- true, and a caller with no profile is now refused by create_team).
--
-- Each block edits the live function text in place and fails loudly, changing
-- nothing, if the text it expects is not there (the same approach as
-- admins_on_teams_2026_11_06.sql). Do not re-run: the first block would stop
-- with "not found as expected", which is correct.

begin;

-- ---------------------------------------------------------------------------
-- 1. create_team: refuse a caller with no profile.
--
-- The permission check is `if not (role = 'admin' or (...)) then raise`. For a
-- signed-in user with no profiles row the role is NULL, the whole expression
-- is NULL, `not NULL` is NULL, and the `if` does not fire: the team is
-- created. Nobody is in that state today (0 users without a profile, sign-up
-- off), so this cannot be used now; it would matter the day an invite half
-- fails or sign-up is switched on by mistake. `is not true` treats NULL as a
-- refusal. The program check gets the same treatment.
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text;
  v_old constant text := E'  if not (v_role = ''admin'' or (v_role = ''director'' and v_my_gender = p_gender)) then\n';
  v_new constant text := E'  if (v_role = ''admin'' or (v_role = ''director'' and v_my_gender = p_gender)) is not true then\n';
  v_old2 constant text := E'  if p_gender not in (''girls'', ''boys'') then\n';
  v_new2 constant text := E'  if p_gender is null or p_gender not in (''girls'', ''boys'') then\n';
begin
  select pg_get_functiondef('public.create_team(text, text, text, text)'::regprocedure) into v_def;
  if position(v_old in v_def) = 0 or position(v_old2 in v_def) = 0 then
    raise exception 'create_team: the checks were not found as expected; nothing changed';
  end if;
  execute replace(replace(v_def, v_old, v_new), v_old2, v_new2);
end $$;

-- ---------------------------------------------------------------------------
-- 2. teams.priority_finished_at: a head coach finishes once, at the server's
--    time.
--
-- enforce_teams_update_scope() limits WHICH columns a coach may change, not
-- what they change them to. A head coach could clear their team's Finished
-- (locking every younger grade out again, which the apps treat as admin-only)
-- or back-date it (the next grade's 3-day clock then starts already expired).
-- The apps also send the phone's clock. Now, for anyone who is not an admin
-- or that program's director: Finished can only go from empty to set, and the
-- time stored is the server's now().
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text;
  v_old constant text := E'  if (to_jsonb(new) - v_allowed) is distinct from (to_jsonb(old) - v_allowed) then\n';
  v_new constant text :=
       E'  if new.priority_finished_at is distinct from old.priority_finished_at\n'
    || E'     and (v_role = ''director'' and v_gender = old.gender) is not true then\n'
    || E'    if old.priority_finished_at is not null or new.priority_finished_at is null then\n'
    || E'      raise exception ''Only an admin or this program''''s director can change a team''''s Finished once it is set'' using errcode = ''42501'';\n'
    || E'    end if;\n'
    || E'    new.priority_finished_at := now();\n'
    || E'  end if;\n'
    || v_old;
begin
  select pg_get_functiondef('public.enforce_teams_update_scope()'::regprocedure) into v_def;
  if position(v_old in v_def) = 0 then
    raise exception 'enforce_teams_update_scope: the column check was not found as expected; nothing changed';
  end if;
  execute replace(v_def, v_old, v_new);
end $$;

-- ---------------------------------------------------------------------------
-- 3. Removing the person whose name is on the schedule lock.
--
-- app_settings.locked_by -> auth.users is ON DELETE NO ACTION, and
-- enforce_app_settings_admin_update() refuses any update with no signed-in
-- user. manage-user (service role, no signed-in user) tries to clear
-- locked_by before deleting an account; the trigger refuses, the function
-- ignores the error, and the delete then fails on the foreign key AFTER the
-- person's bookings were already handed to someone else. It happens when a
-- director locks the schedule and is removed (or deletes their own account)
-- while it is still locked.
--
-- Two changes: the foreign key clears the stamp by itself, and the trigger
-- lets a session with no signed-in user (the service role, or that foreign
-- key action) do exactly one thing: clear locked_by. Everything else it
-- refused before, it still refuses.
-- ---------------------------------------------------------------------------
alter table public.app_settings drop constraint app_settings_locked_by_fkey;
alter table public.app_settings
  add constraint app_settings_locked_by_fkey
  foreign key (locked_by) references auth.users(id) on delete set null;

do $$
declare
  v_def text;
  v_old constant text := E'  if my_role = ''admin'' then\n    return new;\n  end if;\n';
  v_new constant text :=
       v_old
    || E'  -- No signed-in user: the service role removing an account, or the foreign key\n'
    || E'  -- clearing the stamp as that account goes. Clearing locked_by is all it may do.\n'
    || E'  if auth.uid() is null and new.locked_by is null\n'
    || E'     and (to_jsonb(new) - ''locked_by'') is not distinct from (to_jsonb(old) - ''locked_by'') then\n'
    || E'    return new;\n'
    || E'  end if;\n';
begin
  select pg_get_functiondef('public.enforce_app_settings_admin_update()'::regprocedure) into v_def;
  if position(v_old in v_def) = 0 then
    raise exception 'enforce_app_settings_admin_update: the admin branch was not found as expected; nothing changed';
  end if;
  execute replace(v_def, v_old, v_new);
end $$;

-- ---------------------------------------------------------------------------
-- Checks. All four should be true.
-- ---------------------------------------------------------------------------
select
  position('is not true then' in pg_get_functiondef('public.create_team(text, text, text, text)'::regprocedure)) > 0
    as create_team_fails_closed,
  position('new.priority_finished_at := now()' in pg_get_functiondef('public.enforce_teams_update_scope()'::regprocedure)) > 0
    as finished_is_server_time,
  position('auth.uid() is null and new.locked_by is null' in pg_get_functiondef('public.enforce_app_settings_admin_update()'::regprocedure)) > 0
    as stamp_can_be_cleared,
  (select pg_get_constraintdef(oid) from pg_constraint where conname = 'app_settings_locked_by_fkey') like '%ON DELETE SET NULL%'
    as stamp_clears_on_delete;

commit;
