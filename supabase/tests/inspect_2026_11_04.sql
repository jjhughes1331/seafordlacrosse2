-- Step 0 (read only): run this BEFORE the 2026-11-04 migrations and send
-- Claude the output. Nothing here changes anything.
--
-- It checks what those migrations assume about the live database:
-- the teams/profiles/bookings columns, any unique rule on teams(gender, grade)
-- that split teams would break, teams with more than one head coach today
-- (the backfill refuses to guess), and whether pg_cron is installed for the
-- game-day reminders.

select 'columns' as kind, table_name || '.' || column_name || ' ' || data_type
       || coalesce(' default ' || column_default, '') as detail
from information_schema.columns
where table_schema = 'public' and table_name in ('teams', 'profiles', 'bookings', 'waitlist')
union all
select 'teams constraint', conname || ': ' || pg_get_constraintdef(oid)
from pg_constraint where conrelid = 'public.teams'::regclass
union all
select 'teams index', indexname || ': ' || indexdef
from pg_indexes where schemaname = 'public' and tablename = 'teams'
union all
select 'policy', tablename || '.' || policyname || ' (' || cmd || ')'
from pg_policies where schemaname = 'public'
  and tablename in ('bookings', 'waitlist', 'teams', 'profiles')
union all
select 'trigger', event_object_table || '.' || trigger_name || ' ' || action_timing || ' ' || event_manipulation
from information_schema.triggers where trigger_schema = 'public'
  and event_object_table in ('bookings', 'waitlist', 'teams', 'profiles')
union all
select 'team with 2+ coaches', t.gender || ' ' || t.grade || ': ' || string_agg(p.email, ', ')
from profiles p join teams t on t.id = p.team_id
where p.role = 'coach' group by t.id, t.gender, t.grade having count(*) > 1
union all
select 'team with 4+ assistants', t.gender || ' ' || t.grade || ': ' || count(*)
from profiles p join teams t on t.id = p.team_id
where p.role = 'assistant' group by t.id, t.gender, t.grade having count(*) > 3
union all
select 'coach/assistant with no team', email || ' (' || role || ')'
from profiles where role in ('coach', 'assistant') and team_id is null
union all
select 'counts', 'teams ' || (select count(*) from teams)
  || ', coaches ' || (select count(*) from profiles where role = 'coach')
  || ', assistants ' || (select count(*) from profiles where role = 'assistant')
  || ', directors ' || (select count(*) from profiles where role = 'director')
  || ', bookings ' || (select count(*) from bookings)
union all
select 'extension', name || ' installed=' || coalesce(installed_version, 'no')
from pg_available_extensions where name in ('pg_cron', 'pg_net', 'supabase_vault')
order by 1, 2;
