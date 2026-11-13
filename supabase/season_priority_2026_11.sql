-- Season rule and priority deadline move into the database (2026-11).
-- Seaford project only (ref gjpqwmcdejpvffdimddk); do NOT run on Snowleopard.
--
-- APPLIED 2026-11-12 (trial run first, rolled back; then applied). Do not re-run: "add column" stops the second time.
--
-- 1. Season. The fixed CHECKs (2027-03-01 .. 2027-06-30) on bookings and
--    waitlist are replaced by a trigger that reads app_settings.season_start /
--    season_end. A new season is now one edit to app_settings. Rows already
--    saved are never re-checked. Refusal: 23514, constraint name kept.
--
-- 2. Priority deadline. A grade that is holding everyone up for more than 3
--    days is opened by the database (pg_cron, every 10 minutes), whoever has
--    the app open. Two server-owned stamps on app_settings make the clock:
--      priority_enabled_at   when priority booking was last switched on
--      priority_forced_at    {"6": "<when rank 6 was opened by Override or deadline>"}
--    A grade's clock starts at the latest of: switch-on, and the moment each
--    grade above it cleared (all its teams finished, or it was opened).
--    The top grade's clock is the switch-on (JJ 2026-11-12). The switch-on in
--    force when this was applied has no stamp, so nothing advances until
--    priority is next switched off and on.
--    Opening a grade is the same write as Override (priority_forced_ranks), so
--    the booking gate and the "your turn" push are unchanged.

begin;

-- ---------------------------------------------------------------------------
-- 1. Season
-- ---------------------------------------------------------------------------
alter table public.bookings drop constraint if exists bookings_date_in_season;
alter table public.waitlist drop constraint if exists waitlist_date_in_season;

create or replace function public.enforce_date_in_season()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_start date;
  v_end date;
begin
  select season_start, season_end into v_start, v_end from app_settings limit 1;
  if v_start is not null and v_end is not null and (new.date < v_start or new.date > v_end) then
    raise exception 'That date is outside the season (% to %)',
      to_char(v_start, 'Mon FMDD, YYYY'), to_char(v_end, 'Mon FMDD, YYYY')
      using errcode = '23514', constraint = tg_table_name || '_date_in_season';
  end if;
  return new;
end $$;
revoke execute on function public.enforce_date_in_season() from public, anon, authenticated;

create trigger bookings_date_in_season before insert or update of date on public.bookings
  for each row execute function public.enforce_date_in_season();
create trigger waitlist_date_in_season before insert or update of date on public.waitlist
  for each row execute function public.enforce_date_in_season();

alter table public.app_settings
  add constraint app_settings_season_order check (season_start <= season_end);

-- ---------------------------------------------------------------------------
-- 2. Priority deadline
-- ---------------------------------------------------------------------------
alter table public.app_settings
  add column priority_enabled_at timestamptz,
  add column priority_forced_at jsonb not null default '{}';

comment on column public.app_settings.priority_enabled_at is 'server-owned: when priority booking was last switched on';
comment on column public.app_settings.priority_forced_at  is 'server-owned: {"rank": "when it was opened by Override or the deadline"}';

-- Runs after app_settings_enforce_admin_update (triggers fire in name order),
-- so who may change what is already settled. Clients cannot set these stamps.
create or replace function public.stamp_priority_times()
returns trigger language plpgsql set search_path = public as $$
declare
  v_rank int;
  v_stamps jsonb := '{}';
begin
  if not coalesce(new.priority_booking_enabled, false) then
    new.priority_enabled_at := null;
  elsif not coalesce(old.priority_booking_enabled, false) then
    new.priority_enabled_at := now();
  else
    new.priority_enabled_at := old.priority_enabled_at;
  end if;
  foreach v_rank in array coalesce(new.priority_forced_ranks, '{}') loop
    v_stamps := v_stamps || jsonb_build_object(v_rank::text,
      coalesce(old.priority_forced_at -> v_rank::text, to_jsonb(now())));
  end loop;
  new.priority_forced_at := v_stamps;
  return new;
end $$;
revoke execute on function public.stamp_priority_times() from public, anon, authenticated;

create trigger app_settings_stamp_priority before update on public.app_settings
  for each row execute function public.stamp_priority_times();

-- The settings gate, as it stood, plus one door: the deadline job (no signed-in
-- user, flag set inside advance_overdue_priority) may change the opened grades
-- and nothing else.
create or replace function public.enforce_app_settings_admin_update()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
  my_role text := (select p.role from profiles p where p.id = auth.uid());
  director_cols text[] := array['schedule_locked', 'locked_by', 'locked_at', 'priority_booking_enabled'];
begin
  if my_role = 'admin' then
    return new;
  end if;
  -- No signed-in user: the service role removing an account, or the foreign key
  -- clearing the stamp as that account goes. Clearing locked_by is all it may do.
  if auth.uid() is null and new.locked_by is null
     and (to_jsonb(new) - 'locked_by') is not distinct from (to_jsonb(old) - 'locked_by') then
    return new;
  end if;
  -- The deadline job opening an overdue grade.
  if auth.uid() is null and current_setting('seaford.priority_advance', true) = 'on'
     and (to_jsonb(new) - 'priority_forced_ranks') is not distinct from (to_jsonb(old) - 'priority_forced_ranks') then
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
$function$;

-- Opens the grade that is holding everyone up, if its 3 days are over.
-- Returns the rank it opened, or null. One grade per call: the next grade's
-- clock starts when this one is opened.
create or replace function public.advance_overdue_priority()
returns int language plpgsql security definer set search_path = public as $$
declare
  v_s app_settings;
  v_block int;
  v_opened timestamptz;
  v_rank int;
  v_cleared timestamptz;
begin
  select * into v_s from app_settings limit 1 for update;
  if not coalesce(v_s.priority_booking_enabled, false) then return null; end if;

  select max(grade_rank(grade)) into v_block from teams
   where priority_finished_at is null and grade_rank(grade) >= 0
     and not (grade_rank(grade) = any (coalesce(v_s.priority_forced_ranks, '{}')));
  if v_block is null then return null; end if;

  v_opened := v_s.priority_enabled_at;
  for v_rank in select distinct grade_rank(grade) from teams where grade_rank(grade) > v_block loop
    select least(
             case when bool_and(priority_finished_at is not null) then max(priority_finished_at) end,
             (v_s.priority_forced_at ->> v_rank::text)::timestamptz)
      into v_cleared from teams where grade_rank(grade) = v_rank;
    if v_cleared is null then return null; end if;   -- no record of when it cleared: no clock
    v_opened := greatest(v_opened, v_cleared);
  end loop;
  if v_opened is null or now() < v_opened + interval '3 days' then return null; end if;

  perform set_config('seaford.priority_advance', 'on', true);
  update app_settings set priority_forced_ranks = coalesce(priority_forced_ranks, '{}') || v_block;
  perform set_config('seaford.priority_advance', 'off', true);
  return v_block;
end $$;
revoke execute on function public.advance_overdue_priority() from public, anon, authenticated;

commit;

-- pg_cron (outside the transaction: cron.schedule commits on its own).
select cron.unschedule(jobid) from cron.job where jobname = 'seaford-priority-deadline';
select cron.schedule('seaford-priority-deadline', '*/10 * * * *', 'select public.advance_overdue_priority()');

-- Checks.
select
  (select count(*) from pg_constraint where conname in ('bookings_date_in_season','waitlist_date_in_season')) = 0 as fixed_checks_gone,
  (select count(*) from pg_trigger where tgname in ('bookings_date_in_season','waitlist_date_in_season') and not tgisinternal) = 2 as season_triggers,
  (select count(*) from pg_trigger where tgname = 'app_settings_stamp_priority') = 1 as stamp_trigger,
  (select count(*) from cron.job where jobname = 'seaford-priority-deadline' and active) = 1 as job_scheduled,
  not has_function_privilege('authenticated', 'public.advance_overdue_priority()', 'execute') as job_hidden,
  (select priority_enabled_at is null and priority_forced_at = '{}' from app_settings) as no_clock_yet,
  public.advance_overdue_priority() is null as nothing_advances_now,
  (select count(*) from bookings) as bookings;
