-- Priority booking (grade hierarchy) — run once in the Supabase SQL editor.
-- When app_settings.priority_booking_enabled is true, a team can only book
-- once every OLDER grade tier (6th highest seniority down to Kindergarten
-- lowest) has been marked finished — combined across both genders, so e.g.
-- ALL 6th grade teams (girls + boys) must finish before ANY 5th grade team
-- (either gender) unlocks.
--
-- Forced ranks (priority_forced_ranks) are included here so re-running this
-- file does not clobber the override-aware team_priority_unlocked from
-- priority_booking_override.sql. That file is now a pointer at this function.
--
-- IMPORTANT: this modifies the existing bookings_insert_scoped policy (via
-- ALTER POLICY, so it stays in place the whole time — no window with the
-- policy missing) to add a hierarchy check on top of the existing
-- admin/coach/director scoping. When priority_booking_enabled is false the
-- added check is always true, so nothing changes from today's behavior.

alter table app_settings add column if not exists priority_booking_enabled boolean not null default false;
alter table app_settings add column if not exists priority_forced_ranks integer[] not null default '{}';
alter table teams add column if not exists priority_finished_at timestamptz;

create or replace function public.grade_rank(g text)
returns int language sql immutable as $$
  select case g
    when 'Kindergarten' then 0
    when '1st Grade' then 1
    when '2nd Grade' then 2
    when '3rd Grade' then 3
    when '4th Grade' then 4
    when '5th Grade' then 5
    when '6th Grade' then 6
    else -1
  end;
$$;

create or replace function public.team_priority_unlocked(check_team_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select
    not coalesce((select priority_booking_enabled from app_settings limit 1), false)
    or not exists (
      select 1 from teams older, teams mine
      where mine.id = check_team_id
        and grade_rank(older.grade) > grade_rank(mine.grade)
        and older.priority_finished_at is null
        and not (grade_rank(older.grade) = any (coalesce((select priority_forced_ranks from app_settings limit 1), '{}')))
    );
$$;

alter policy "bookings_insert_scoped" on bookings
with check (
  (not (select app_settings.schedule_locked from app_settings limit 1))
  and (booked_by = (select auth.uid()))
  and (
    (exists (select 1 from profiles p where p.id = (select auth.uid()) and p.role = 'admin'))
    or (exists (select 1 from profiles p where p.id = (select auth.uid()) and p.role = 'coach' and p.team_id = bookings.team_id))
    or (exists (select 1 from profiles p join teams t on t.id = bookings.team_id where p.id = (select auth.uid()) and p.role = 'director' and p.gender = t.gender))
  )
  and team_priority_unlocked(bookings.team_id)
);

-- teams had no UPDATE policy at all before this — needed so a coach/director/
-- admin can mark their own team's priority_finished_at. Scoped the same way
-- booking permission already is.
-- Column-level lock (non-admins cannot change gender/grade; only
-- priority_finished_at) is in supabase/security_hardening.sql.
do $$
begin
  create policy "teams_update_priority_scoped" on teams
    for update
    using (
      exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin')
      or exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'coach' and p.team_id = teams.id)
      or exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'director' and p.gender = teams.gender)
    )
    with check (
      exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin')
      or exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'coach' and p.team_id = teams.id)
      or exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'director' and p.gender = teams.gender)
    );
exception
  when duplicate_object then
    null;
end $$;

do $$
begin
  alter publication supabase_realtime add table teams;
exception
  when duplicate_object then
    null;
end $$;
