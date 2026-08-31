-- Director/admin override for priority booking — run once in the SQL editor.
-- Adds a "forced ranks" list: grade tiers a director has manually pushed
-- through even though not every team in that tier finished. Modeled as a set
-- (not a single threshold) so forcing 6th grade through only unlocks 5th —
-- it does NOT cascade to also unlock 4th/3rd/etc before 5th actually finishes
-- (or is itself forced).

alter table app_settings add column if not exists priority_forced_ranks integer[] not null default '{}';

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
