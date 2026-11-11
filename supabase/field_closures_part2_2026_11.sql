-- Closed dates, part 2 (2026-11). Seaford project only (ref gjpqwmcdejpvffdimddk);
-- do NOT run on Snowleopard. Needs field_closures_2026_11.sql (applied 2026-11-11).
--
-- APPLIED to the live database on 2026-11-11 (after a trial that ran every
-- rule and rolled itself back; all five checks at the end were true).
--
-- A closure can now name parts of the field (Field B only) and days of the
-- week (Fridays only, inside its dates), and can be edited in place.
--
--   field_closures.subfields  null = every part; else field_slots.subfield names
--   field_closures.weekdays   null = every day; else 0 (Sunday) .. 6 (Saturday)
--   apply_closure()   internal: cancels what a closure covers from today on,
--                     tells the coaches, returns the count
--   close_field()     recreated with p_subfields and p_weekdays (both default
--                     null), so the five-argument named call still works
--   edit_closure()    admins and directors: new dates, times, parts, days or
--                     reason; what it newly covers is cancelled and told
--   enforce_field_open()  the full rule, part included
--
-- Existing closures have neither list and mean exactly what they meant.
-- Design: seaford-lax-app docs/superpowers/specs/2026-11-11-closures-more-design.md
--
-- Do not re-run: "add column" stops the second time, which is correct.

begin;

-- ---------------------------------------------------------------------------
-- 1. The two lists.
-- ---------------------------------------------------------------------------
alter table public.field_closures
  add column subfields text[],
  add column weekdays  int[],
  add constraint field_closures_subfields check (subfields is null or cardinality(subfields) > 0),
  add constraint field_closures_weekdays  check (weekdays is null or (cardinality(weekdays) > 0 and weekdays <@ array[0,1,2,3,4,5,6]));

comment on column public.field_closures.subfields is 'null = every part of the field; else the field_slots.subfield names closed';
comment on column public.field_closures.weekdays  is 'null = every day in the dates; else the days of the week closed, 0 Sunday .. 6 Saturday';

-- ---------------------------------------------------------------------------
-- 2. The rule, in one place for SQL: does closure c cover this slot?
-- ---------------------------------------------------------------------------
create function public.closure_covers(c public.field_closures, p_field text, p_date date, p_subfield text, p_time text)
returns boolean language sql immutable as $$
  select c.field_id = p_field
     and p_date between c.start_date and c.end_date
     and (c.weekdays  is null or extract(dow from p_date)::int = any (c.weekdays))
     and (c.times     is null or p_time = any (c.times))
     and (c.subfields is null or p_subfield = any (c.subfields))
$$;

create or replace function public.enforce_field_open()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_reason text;
begin
  select c.reason into v_reason
  from field_closures c
  where closure_covers(c, new.field_id, new.date::date, new.subfield, new.time)
  order by c.start_date, c.end_date, c.reason
  limit 1;
  if v_reason is not null then
    raise exception 'Field closed: %', v_reason using errcode = '23514';
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Checking what a form sends. Returns the lists tidied (distinct, sorted);
--    raises 22023 with words the person sees.
-- ---------------------------------------------------------------------------
create function public.closure_input(p_field text, p_start date, p_end date, p_reason text,
                                     p_times text[], p_subfields text[], p_weekdays int[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'America/New_York')::date;
  v_times text[]; v_subs text[]; v_days int[];
begin
  if p_start is null or p_end is null or p_end < p_start then
    raise exception 'The last day is before the first' using errcode = '22023';
  end if;
  if p_end < v_today then
    raise exception 'Those dates have passed' using errcode = '22023';
  end if;
  if p_end - p_start > 366 then
    raise exception 'A closure can run for a year at most' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) not between 1 and 40 then
    raise exception 'The reason needs 1 to 40 characters' using errcode = '22023';
  end if;

  if p_times is not null then
    select array_agg(distinct t) into v_times from unnest(p_times) u(t) where t is not null;
    if v_times is null then
      raise exception 'Pick at least one time, or close the whole day' using errcode = '22023';
    end if;
    if exists (select 1 from unnest(v_times) u(t)
               where not exists (select 1 from field_slots s where s.field_id = p_field and s.time = u.t)) then
      raise exception 'That field has no such time' using errcode = '22023';
    end if;
  end if;

  if p_subfields is not null then
    select array_agg(distinct t order by t) into v_subs from unnest(p_subfields) u(t) where t is not null;
    if v_subs is null then
      raise exception 'Pick at least one part, or close every part' using errcode = '22023';
    end if;
    if exists (select 1 from unnest(v_subs) u(t)
               where not exists (select 1 from field_slots s where s.field_id = p_field and s.subfield = u.t)) then
      raise exception 'That field has no such part' using errcode = '22023';
    end if;
  end if;

  if p_weekdays is not null then
    select array_agg(distinct d order by d) into v_days from unnest(p_weekdays) u(d) where d is not null;
    if v_days is null then
      raise exception 'Pick at least one day of the week, or close every day' using errcode = '22023';
    end if;
    if not v_days <@ array[0,1,2,3,4,5,6] then
      raise exception 'That is not a day of the week' using errcode = '22023';
    end if;
    if not exists (select 1 from generate_series(p_start, p_end, interval '1 day') g(d)
                   where extract(dow from g.d)::int = any (v_days)) then
      raise exception 'None of those days fall in the dates' using errcode = '22023';
    end if;
  end if;

  return jsonb_build_object('times', v_times, 'subfields', v_subs, 'weekdays', v_days);
end;
$$;

revoke all on function public.closure_input(text, date, date, text, text[], text[], int[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. apply_closure: what a closure covers from today on goes, waitlist first
--    (so "A slot opened up!" finds nobody), then the practices, quietly; one
--    push per team that lost practices. Returns the practices cancelled.
--    Internal: called only by close_field and edit_closure.
-- ---------------------------------------------------------------------------
create function public.apply_closure(p_row public.field_closures, p_actor uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'America/New_York')::date;
  v_from  date := greatest(p_row.start_date, (now() at time zone 'America/New_York')::date);
  v_field text;
  v_on    text := '';
  v_lost  jsonb;
  v_n     int := 0;
  r       record;
begin
  select name into v_field from fields where id = p_row.field_id;

  delete from waitlist w
  where w.date::date >= v_from and closure_covers(p_row, w.field_id, w.date::date, w.subfield, w.time);

  perform set_config('seaford.closing_field', '1', true);
  with gone as (
    delete from bookings b
    where b.date::date >= v_from and closure_covers(p_row, b.field_id, b.date::date, b.subfield, b.time)
    returning b.team_id, b.date::date as d, b.time
  )
  select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) into v_lost
  from (select team_id, count(*) as n, min(d) as d1, max(d) as d2, min(time) as one_time
        from gone group by team_id) s;
  perform set_config('seaford.closing_field', '', true);

  -- " on Fridays", " on Tuesdays and Thursdays", " on Mondays, Wednesdays and Fridays"
  if p_row.weekdays is not null then
    select ' on ' || case when count(*) = 1 then max(n)
                          else string_agg(n, ', ' order by d) filter (where d < max_d) || ' and ' || max(n) filter (where d = max_d) end
    into v_on
    from (select d, (array['Sundays','Mondays','Tuesdays','Wednesdays','Thursdays','Fridays','Saturdays'])[d + 1] as n,
                 max(d) over () as max_d
          from unnest(p_row.weekdays) u(d)) x;
  end if;

  for r in select * from jsonb_to_recordset(v_lost) as x(team_id uuid, n int, d1 date, d2 date, one_time text) loop
    v_n := v_n + r.n;
    perform push_to(
      'Practice cancelled: ' || v_field || ' closed',
      v_field || ' is closed '
        || case when p_row.start_date = p_row.end_date then to_char(p_row.start_date, 'Dy, Mon FMDD')
                else to_char(p_row.start_date, 'Mon FMDD') || ' to ' || to_char(p_row.end_date, 'Mon FMDD') end
        || v_on
        || ' (' || p_row.reason || '). '
        || case when r.n = 1 then team_label(r.team_id) || '''s ' || to_char(r.d1, 'Dy, Mon FMDD') || ' ' || r.one_time || ' practice was cancelled.'
                else r.n || ' practices for ' || team_label(r.team_id) || ' were cancelled.' end,
      (select coalesce(array_agg(distinct id), '{}') from (
         select m.profile_id as id from team_members m where m.team_id = r.team_id
         union
         select unnest(alert_followers(array[r.team_id], 'team_bookings', p_actor))
       ) who where id is distinct from p_actor));
  end loop;

  return v_n;
end;
$$;

revoke all on function public.apply_closure(public.field_closures, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. close_field, with parts and days. Dropped and recreated in this
--    transaction: a second overload would make the five-argument call
--    ambiguous.
-- ---------------------------------------------------------------------------
drop function public.close_field(text, date, date, text, text[]);

create function public.close_field(p_field text, p_start date, p_end date, p_reason text,
                                   p_times text[] default null, p_subfields text[] default null, p_weekdays int[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_role  text;
  v_in    jsonb;
  v_row   field_closures;
  v_n     int;
begin
  select role into v_role from profiles where id = v_actor;
  if (v_role in ('admin', 'director')) is not true then
    raise exception 'Only an admin or a director can close a field' using errcode = '42501';
  end if;
  if not exists (select 1 from fields where id = p_field) then
    raise exception 'That field does not exist' using errcode = '22023';
  end if;
  v_in := closure_input(p_field, p_start, p_end, p_reason, p_times, p_subfields, p_weekdays);

  insert into field_closures (field_id, start_date, end_date, times, subfields, weekdays, reason, created_by)
  values (p_field, p_start, p_end,
          (select array_agg(x) from jsonb_array_elements_text(nullif(v_in->'times', 'null'::jsonb)) x),
          (select array_agg(x) from jsonb_array_elements_text(nullif(v_in->'subfields', 'null'::jsonb)) x),
          (select array_agg(x::int) from jsonb_array_elements_text(nullif(v_in->'weekdays', 'null'::jsonb)) x),
          btrim(p_reason), v_actor)
  returning * into v_row;

  v_n := apply_closure(v_row, v_actor);
  return jsonb_build_object('closure', to_jsonb(v_row), 'cancelled', v_n);
end;
$$;

revoke all on function public.close_field(text, date, date, text, text[], text[], int[]) from public, anon;
grant execute on function public.close_field(text, date, date, text, text[], text[], int[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. edit_closure: same field, new everything else. What it newly covers is
--    cancelled and told; what it stops covering opens; nothing comes back.
-- ---------------------------------------------------------------------------
create function public.edit_closure(p_id uuid, p_start date, p_end date, p_reason text,
                                    p_times text[] default null, p_subfields text[] default null, p_weekdays int[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor uuid := auth.uid();
  v_today date := (now() at time zone 'America/New_York')::date;
  v_role  text;
  v_old   field_closures;
  v_in    jsonb;
  v_row   field_closures;
  v_n     int;
begin
  select role into v_role from profiles where id = v_actor;
  if (v_role in ('admin', 'director')) is not true then
    raise exception 'Only an admin or a director can change a closure' using errcode = '42501';
  end if;
  select * into v_old from field_closures where id = p_id for update;
  if not found then
    raise exception 'That closure no longer exists' using errcode = '22023';
  end if;
  if v_old.end_date < v_today then
    raise exception 'That closure has ended' using errcode = '22023';
  end if;
  v_in := closure_input(v_old.field_id, p_start, p_end, p_reason, p_times, p_subfields, p_weekdays);

  update field_closures set
    start_date = p_start,
    end_date   = p_end,
    times      = (select array_agg(x) from jsonb_array_elements_text(nullif(v_in->'times', 'null'::jsonb)) x),
    subfields  = (select array_agg(x) from jsonb_array_elements_text(nullif(v_in->'subfields', 'null'::jsonb)) x),
    weekdays   = (select array_agg(x::int) from jsonb_array_elements_text(nullif(v_in->'weekdays', 'null'::jsonb)) x),
    reason     = btrim(p_reason)
  where id = p_id
  returning * into v_row;

  -- Only practices the old closure did not cover can still be there.
  v_n := apply_closure(v_row, v_actor);
  return jsonb_build_object('closure', to_jsonb(v_row), 'cancelled', v_n);
end;
$$;

revoke all on function public.edit_closure(uuid, date, date, text, text[], text[], int[]) from public, anon;
grant execute on function public.edit_closure(uuid, date, date, text, text[], text[], int[]) to authenticated;

-- ---------------------------------------------------------------------------
-- Checks. All should be true.
-- ---------------------------------------------------------------------------
select
  (select count(*) = 2 from information_schema.columns
     where table_schema = 'public' and table_name = 'field_closures' and column_name in ('subfields', 'weekdays'))
    as lists_added,
  (select count(*) = 1 from pg_proc where proname = 'close_field' and pronamespace = 'public'::regnamespace)
    as one_close_field,
  has_function_privilege('authenticated', 'public.close_field(text, date, date, text, text[], text[], int[])', 'execute')
    and has_function_privilege('authenticated', 'public.edit_closure(uuid, date, date, text, text[], text[], int[])', 'execute')
    and not has_function_privilege('anon', 'public.close_field(text, date, date, text, text[], text[], int[])', 'execute')
    and not has_function_privilege('anon', 'public.edit_closure(uuid, date, date, text, text[], text[], int[])', 'execute')
    as only_members_can_call,
  not has_function_privilege('authenticated', 'public.apply_closure(public.field_closures, uuid)', 'execute')
    and not has_function_privilege('authenticated', 'public.closure_input(text, date, date, text, text[], text[], int[])', 'execute')
    as internals_hidden,
  position('closure_covers' in pg_get_functiondef('public.enforce_field_open()'::regprocedure)) > 0
    as rule_has_parts;

commit;
