-- This Week's Games (JJ, 2026-11-04). Seaford project only
-- (ref gjpqwmcdejpvffdimddk). Run AFTER notification_settings_2026_11_04.sql.
-- pg_cron must be available (Database > Extensions; the inspect script shows
-- it). One transaction: if any statement fails, nothing changes.
--
-- 1. games: the league schedule. A director or admin uploads the league's
--    spreadsheet on the website or in the app; the app reads the rows and
--    calls import_games(). Everyone signed in can read it (the new This
--    Week's Games tab, Home/Away toggle).
-- 2. game_duties: on each game day, at each Seaford field, the team in the
--    first home game sets the field up and the team in the last home game
--    breaks it down. One home game that day = that team does both.
-- 3. Reminders: those teams' followers (notification setting "field duty")
--    get a push 2 days and 2 hours before their game. pg_cron checks every
--    10 minutes; each reminder is sent once.
--
-- Times are Eastern (America/New_York), as the league writes them.

begin;

create table if not exists public.games (
  id              uuid primary key default gen_random_uuid(),
  season          int  not null,
  game_number     int  not null,
  game_date       date not null,
  start_time      time,
  field_label     text,
  field_id        text references public.fields(id) on delete set null,
  town            text,
  home            text not null,
  away            text not null,
  gender          text not null check (gender in ('girls', 'boys')),
  grade           text,
  division        text,
  note            text,
  is_home         boolean not null,
  seaford_team_id uuid references public.teams(id) on delete set null,
  imported_at     timestamptz not null default now(),
  imported_by     uuid references auth.users(id) on delete set null
  -- game_number is only for display: the league repeats numbers across grades.
);
comment on table public.games is
  'League schedule. Written only by import_games(), which replaces a season at a time. is_home = a Seaford team is the home team.';
create index if not exists games_date_idx on public.games (game_date);

alter table public.games enable row level security;
drop policy if exists members_read on public.games;
create policy members_read on public.games for select to authenticated
  using (current_user_role() is not null);
revoke all on public.games from anon;
revoke insert, update, delete, truncate on public.games from authenticated;
grant select on public.games to authenticated;

-- "3rd" / "3rd Grade" / "K" -> the app's grade names.
create or replace function public.normalize_grade(p text)
returns text language sql immutable set search_path = public as $$
  select case
    when p is null then null
    when lower(btrim(p)) in ('k', 'kindergarten') then 'Kindergarten'
    when btrim(p) ~ '^[1-6](st|nd|rd|th)' then substring(btrim(p) from '^[1-6](?:st|nd|rd|th)') || ' Grade'
    else btrim(p)
  end
$$;

-- "Seaford 2 Green" -> the Seaford team it means, for one program.
-- league_name wins when set; otherwise "Seaford <grade number>[ <name>]".
create or replace function public.match_seaford_team(p_name text, p_gender text)
returns uuid language sql stable security definer set search_path = public as $$
  select t.id from teams t
  where t.gender = p_gender
    and (lower(btrim(t.league_name)) = lower(btrim(p_name))
         or (t.league_name is null
             and lower('Seaford ' || case when t.grade = 'Kindergarten' then 'K' else left(t.grade, 1) end
                       || coalesce(' ' || t.name, '')) = lower(regexp_replace(btrim(p_name), '\s+', ' ', 'g'))))
  order by (t.league_name is not null) desc
  limit 1
$$;

-- Replace one season's schedule. p_rows is a JSON array of
--   {game_number, date "YYYY-MM-DD", time "HH:MM" (24h) or null,
--    field "SHS" | "Cedar Creek" | ..., town, home, away,
--    gender "girls"|"boys", grade, division, note}
-- The season's games are replaced outright: the league's game numbers
-- repeat across grades, so they can't identify a game. BYE rows and exact
-- duplicate rows are skipped. Returns a summary the app shows: counts,
-- Seaford names it couldn't match to a team, and times outside
-- 7 AM - 8 PM worth a second look.
create or replace function public.import_games(p_season int, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_role text;
  v_count int;
  v_byes int;
  v_removed int;
  v_unmatched jsonb;
  v_odd jsonb;
begin
  -- No signed-in user = the SQL editor, which may import too.
  select role into v_role from profiles where id = auth.uid();
  if auth.uid() is not null and (v_role is null or v_role not in ('admin', 'director')) then
    raise exception 'Only directors and admins can upload the league schedule' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Expected a list of games' using errcode = '22023';
  end if;

  drop table if exists pg_temp.incoming;
  create temp table incoming on commit drop as
  select (r->>'game_number')::int                               as game_number,
         (r->>'date')::date                                     as game_date,
         nullif(r->>'time', '')::time                           as start_time,
         nullif(btrim(r->>'field'), '')                         as field_label,
         nullif(btrim(r->>'town'), '')                          as town,
         btrim(coalesce(r->>'home', ''))                        as home,
         btrim(coalesce(r->>'away', ''))                        as away,
         lower(nullif(btrim(r->>'gender'), ''))                 as gender,
         normalize_grade(r->>'grade')                           as grade,
         nullif(btrim(r->>'division'), '')                      as division,
         nullif(btrim(r->>'note'), '')                          as note
  from jsonb_array_elements(p_rows) as r;

  select count(*) into v_byes from incoming
   where upper(home) in ('BYE', 'N/A', '') or upper(away) in ('BYE', 'N/A', '');
  delete from incoming
   where upper(home) in ('BYE', 'N/A', '') or upper(away) in ('BYE', 'N/A', '')
      or game_number is null or game_date is null;

  if exists (select 1 from incoming where gender is null or gender not in ('girls', 'boys')) then
    raise exception 'Every game needs Girls or Boys' using errcode = '22023';
  end if;

  delete from games where season = p_season;
  get diagnostics v_removed = row_count;

  insert into games (season, game_number, game_date, start_time, field_label, field_id, town,
                     home, away, gender, grade, division, note, is_home, seaford_team_id, imported_by)
  select p_season, i.game_number, i.game_date, i.start_time, i.field_label,
         (select f.id from fields f where f.id = case
            when lower(i.field_label) in ('shs', 'seaford hs', 'seaford high school') then 'seafordhs'
            when lower(i.field_label) like 'cedar creek%' then 'cedarcreek'
          end),
         i.town, i.home, i.away, i.gender, i.grade, i.division, i.note,
         i.home ilike 'seaford%',
         match_seaford_team(case when i.home ilike 'seaford%' then i.home else i.away end, i.gender),
         auth.uid()
  from (select distinct * from incoming) i;
  get diagnostics v_count = row_count;

  select coalesce(jsonb_agg(distinct case when home ilike 'seaford%' then home else away end), '[]')
    into v_unmatched
  from games where season = p_season and seaford_team_id is null;

  select coalesce(jsonb_agg(jsonb_build_object('game', initcap(gender) || ' ' || game_number, 'date', game_date,
                                               'time', to_char(start_time, 'FMHH12:MI AM'),
                                               'teams', home || ' v ' || away) order by game_date, game_number), '[]')
    into v_odd
  from games where season = p_season
   and start_time is not null and (start_time < time '07:00' or start_time > time '20:00');

  perform log_activity('uploaded league schedule', null, p_season || ': ' || v_count || ' games');

  return jsonb_build_object('imported', v_count, 'removed', v_removed, 'byes', v_byes,
                            'unmatched', v_unmatched, 'odd_times', v_odd);
end;
$$;

-- Who sets up and who breaks down, per game day per Seaford field.
-- security_invoker: it reads games with the caller's own rights.
create or replace view public.game_duties with (security_invoker = true) as
with home as (
  select g.*, coalesce(g.field_id, lower(g.field_label), 'seaford') as site
  from games g where g.is_home
), ranked as (
  select h.*,
         row_number() over (partition by season, game_date, site
                            order by start_time asc nulls last, gender, game_number asc) as from_start,
         row_number() over (partition by season, game_date, site
                            order by start_time desc nulls last, gender desc, game_number desc) as from_end
  from home h
)
select id as game_id, season, game_date, start_time, site, field_id, field_label,
       seaford_team_id as team_id, 'setup'::text as duty
from ranked where from_start = 1
union all
select id, season, game_date, start_time, site, field_id, field_label,
       seaford_team_id, 'breakdown'::text
from ranked where from_end = 1;
grant select on public.game_duties to authenticated;

-- Reminders -------------------------------------------------------------------

create table if not exists public.duty_reminders_sent (
  season    int  not null,
  game_date date not null,
  site      text not null,
  duty      text not null,
  kind      text not null check (kind in ('2d', '2h')),
  team_id   uuid not null,
  sent_at   timestamptz not null default now(),
  primary key (season, game_date, site, duty, kind, team_id)
);
alter table public.duty_reminders_sent enable row level security;
revoke all on public.duty_reminders_sent from anon, authenticated;

-- When each reminder is due. No start time: the 2-day one goes at 9 AM, and
-- there's no 2-hour one.
create or replace function public.duty_reminder_at(p_date date, p_time time, p_kind text)
returns timestamptz language sql stable set search_path = public as $$
  select case
    when p_kind = '2d' and p_time is not null then ((p_date + p_time) at time zone 'America/New_York') - interval '2 days'
    when p_kind = '2d' then ((p_date - 2) + time '09:00') at time zone 'America/New_York'
    when p_kind = '2h' and p_time is not null then ((p_date + p_time) at time zone 'America/New_York') - interval '2 hours'
  end
$$;

-- Run by pg_cron. Sends what came due in the last 3 hours and hasn't been
-- sent (so a schedule uploaded late doesn't fire a stale reminder).
create or replace function public.send_duty_reminders()
returns int language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_sent int := 0;
  v_place text;
  v_when text;
begin
  for r in
    select d.*, k.kind, duty_reminder_at(d.game_date, d.start_time, k.kind) as due
    from game_duties d cross join (values ('2d'), ('2h')) as k(kind)
    where d.team_id is not null
  loop
    continue when r.due is null or r.due > now() or r.due <= now() - interval '3 hours';
    insert into duty_reminders_sent (season, game_date, site, duty, kind, team_id)
    values (r.season, r.game_date, r.site, r.duty, r.kind, r.team_id)
    on conflict do nothing;
    continue when not found;

    v_place := coalesce((select name from fields where id = r.field_id), r.field_label, 'the field');
    v_when := case when r.kind = '2h' then 'Today'
                   else to_char(r.game_date, 'FMDay, Mon FMDD') end
              || coalesce(' at ' || to_char(r.start_time, 'FMHH12:MI AM'), '');
    perform push_to(
      case when r.duty = 'setup' then team_label(r.team_id) || ' sets up the field'
           else team_label(r.team_id) || ' breaks down the field' end,
      case when r.duty = 'setup'
           then v_when || ': first home game at ' || v_place || '. Get there early to set up.'
           else v_when || ': last home game at ' || v_place || '. Stay after to break the field down.' end,
      alert_followers(array[r.team_id], 'field_duty'));
    v_sent := v_sent + 1;
  end loop;
  return v_sent;
end;
$$;

-- Grants -----------------------------------------------------------------------
revoke all on function public.normalize_grade(text) from public, anon;
revoke all on function public.match_seaford_team(text, text) from public, anon, authenticated;
revoke all on function public.import_games(int, jsonb) from public, anon;
revoke all on function public.duty_reminder_at(date, time, text) from public, anon;
revoke all on function public.send_duty_reminders() from public, anon, authenticated;
grant execute on function public.normalize_grade(text) to authenticated;
grant execute on function public.import_games(int, jsonb) to authenticated;
grant execute on function public.duty_reminder_at(date, time, text) to authenticated;

do $$
begin
  alter publication supabase_realtime add table public.games;
exception when duplicate_object then null;
end $$;

commit;

-- pg_cron (outside the transaction: cron.schedule commits on its own).
-- If this line errors, turn on Cron under Database > Extensions (or
-- Integrations > Cron) and run just these three statements again.
create extension if not exists pg_cron with schema pg_catalog;
select cron.unschedule(jobid) from cron.job where jobname = 'seaford-duty-reminders';
select cron.schedule('seaford-duty-reminders', '*/10 * * * *', 'select public.send_duty_reminders()');
