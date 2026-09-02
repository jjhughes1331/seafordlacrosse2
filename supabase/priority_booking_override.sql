-- Director/admin override for priority booking.
--
-- The team_priority_unlocked function (including priority_forced_ranks) now
-- lives in supabase/priority_booking.sql so re-running that file is not a
-- footgun. This file is kept as a pointer.
--
-- If you have not run security_hardening.sql / the updated priority_booking.sql
-- yet, the statement below is still safe to run on its own (idempotent
-- CREATE OR REPLACE). Prefer the merged copy in priority_booking.sql going
-- forward.

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
