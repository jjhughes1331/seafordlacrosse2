-- Closed dates (2026-11). Seaford project only (ref gjpqwmcdejpvffdimddk);
-- do NOT run on Snowleopard.
--
-- APPLIED to the live database on 2026-11-11 (run once in the SQL editor,
-- after a trial that ran every rule and rolled itself back; all six checks
-- at the end were true, and bookings were untouched).
--
-- A field can be closed for a date or a run of dates, all day or for some of
-- its times: no permit, a school game. `field_slots` only knows weekdays, so
-- until now every date a field runs could be booked.
--
--   field_closures     one row per closure. Everyone signed in reads it;
--                      nobody writes it directly (no write policy).
--   close_field()      admins and directors. Adds the closure, removes the
--                      waitlist entries and then the practices booked there
--                      from today on, and tells those teams' coaches.
--   reopen_field()     admins and directors. Removes the closure. Cancelled
--                      practices do not come back.
--   enforce_field_open()  trigger on bookings and waitlist: a closed slot
--                      raises 23514 'Field closed: <reason>'.
--
-- The table starts empty, so nothing behaves differently until someone
-- closes a field. Design: seaford-lax-app
-- docs/superpowers/specs/2026-11-11-closed-dates-design.md
--
-- Do not re-run: the last block edits notify_team_booking_change() in place
-- and stops with "not found as expected" the second time, which is correct.

begin;

-- ---------------------------------------------------------------------------
-- 1. The table.
-- ---------------------------------------------------------------------------
create table public.field_closures (
  id          uuid primary key default gen_random_uuid(),
  field_id    text not null references public.fields(id) on delete cascade,
  start_date  date not null,
  end_date    date not null,
  times       text[],            -- null = all day; else field_slots.time strings
  reason      text not null,
  -- Removing the person who closed it must not fail (see app_settings.locked_by, 2026-11-10).
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  constraint field_closures_dates  check (end_date >= start_date),
  constraint field_closures_reason check (char_length(btrim(reason)) between 1 and 40),
  constraint field_closures_times  check (times is null or cardinality(times) > 0)
);

comment on table public.field_closures is
  'Dates a field cannot be used (no permit, a school game). times null = all day. Written only by close_field()/reopen_field().';

create index field_closures_field_dates on public.field_closures (field_id, start_date, end_date);

alter table public.field_closures enable row level security;

-- Read: any member, as field_slots. No insert/update/delete policy on purpose.
create policy members_read on public.field_closures
  for select to authenticated using (current_user_role() is not null);

revoke all on public.field_closures from anon, authenticated;
grant select on public.field_closures to authenticated;

alter publication supabase_realtime add table public.field_closures;

-- ---------------------------------------------------------------------------
-- 2. A closed slot takes no booking and no waitlist entry.
--
-- A trigger of its own, beside enforce_allowed_slot (which is untouched).
-- Security definer: the check must see every closure whatever the caller may
-- read. It fires on insert, and on update only when the slot itself moves:
-- manage-user re-points booked_by on old rows, and a practice that was played
-- before its field closed must still be allowed to change hands.
-- ---------------------------------------------------------------------------
create function public.enforce_field_open()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_reason text;
begin
  select c.reason into v_reason
  from field_closures c
  where c.field_id = new.field_id
    and new.date::date between c.start_date and c.end_date
    and (c.times is null or new.time = any (c.times))
  order by c.start_date, c.end_date, c.reason
  limit 1;
  if v_reason is not null then
    raise exception 'Field closed: %', v_reason using errcode = '23514';
  end if;
  return new;
end;
$$;

revoke all on function public.enforce_field_open() from public, anon, authenticated;

create trigger bookings_enforce_field_open
  before insert or update of field_id, date, subfield, time on public.bookings
  for each row execute function public.enforce_field_open();

create trigger waitlist_enforce_field_open
  before insert or update of field_id, date, subfield, time on public.waitlist
  for each row execute function public.enforce_field_open();

-- ---------------------------------------------------------------------------
-- 3. close_field: admins and directors (either director, any field: the
--    fields are shared by both programs).
--
-- p_times last, with a default, so a caller that leaves it out means all day.
-- Messages are shown to the person as written.
-- ---------------------------------------------------------------------------
create function public.close_field(p_field text, p_start date, p_end date, p_reason text, p_times text[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_actor  uuid := auth.uid();
  v_role   text;
  v_today  date := (now() at time zone 'America/New_York')::date;
  v_reason text := btrim(coalesce(p_reason, ''));
  v_times  text[];
  v_field  text;
  v_from   date;
  v_row    field_closures;
  v_lost   jsonb;
  v_n      int := 0;
  r        record;
begin
  select role into v_role from profiles where id = v_actor;
  if (v_role in ('admin', 'director')) is not true then
    raise exception 'Only an admin or a director can close a field' using errcode = '42501';
  end if;

  select name into v_field from fields where id = p_field;
  if v_field is null then
    raise exception 'That field does not exist' using errcode = '22023';
  end if;
  if p_start is null or p_end is null or p_end < p_start then
    raise exception 'The last day is before the first' using errcode = '22023';
  end if;
  if p_end < v_today then
    raise exception 'Those dates have passed' using errcode = '22023';
  end if;
  if p_end - p_start > 366 then
    raise exception 'A closure can run for a year at most' using errcode = '22023';
  end if;
  if char_length(v_reason) not between 1 and 40 then
    raise exception 'The reason needs 1 to 40 characters' using errcode = '22023';
  end if;
  if p_times is not null then
    select array_agg(distinct t) into v_times from unnest(p_times) as u(t) where t is not null;
    if v_times is null then
      raise exception 'Pick at least one time, or close the whole day' using errcode = '22023';
    end if;
    if exists (select 1 from unnest(v_times) as u(t)
               where not exists (select 1 from field_slots s where s.field_id = p_field and s.time = u.t)) then
      raise exception 'That field has no such time' using errcode = '22023';
    end if;
  end if;

  insert into field_closures (field_id, start_date, end_date, times, reason, created_by)
  values (p_field, p_start, p_end, v_times, v_reason, v_actor)
  returning * into v_row;

  -- Practices already played stay on the record.
  v_from := greatest(p_start, v_today);

  -- Whoever was waiting goes first: with nobody waiting, the "A slot opened
  -- up!" trigger on the deletes below has nobody to tell.
  delete from waitlist w
  where w.field_id = p_field and w.date::date between v_from and p_end
    and (v_times is null or w.time = any (v_times));

  -- The practices. notify_team_booking_change() stays quiet for these (it
  -- reads this flag); the push below says why they went. log_booking_change()
  -- still records each one against the person closing the field.
  perform set_config('seaford.closing_field', '1', true);
  with gone as (
    delete from bookings b
    where b.field_id = p_field and b.date::date between v_from and p_end
      and (v_times is null or b.time = any (v_times))
    returning b.team_id, b.date::date as d, b.time
  )
  select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) into v_lost
  from (select team_id, count(*) as n, min(d) as d1, max(d) as d2, min(time) as one_time
        from gone group by team_id) s;
  perform set_config('seaford.closing_field', '', true);

  -- One push per team that lost practices: its coaches, and anyone following
  -- it with "team bookings" on, whatever their other alert settings. Not the
  -- person who closed the field.
  for r in select * from jsonb_to_recordset(v_lost) as x(team_id uuid, n int, d1 date, d2 date, one_time text) loop
    v_n := v_n + r.n;
    perform push_to(
      'Practice cancelled: ' || v_field || ' closed',
      v_field || ' is closed '
        || case when r.d1 = r.d2 then to_char(r.d1, 'Dy, Mon FMDD')
                else to_char(r.d1, 'Mon FMDD') || ' to ' || to_char(r.d2, 'Mon FMDD') end
        || ' (' || v_reason || '). '
        || case when r.n = 1 then team_label(r.team_id) || '''s ' || r.one_time || ' practice was cancelled.'
                else r.n || ' practices for ' || team_label(r.team_id) || ' were cancelled.' end,
      (select coalesce(array_agg(distinct id), '{}') from (
         select m.profile_id as id from team_members m where m.team_id = r.team_id
         union
         select unnest(alert_followers(array[r.team_id], 'team_bookings', v_actor))
       ) who where id is distinct from v_actor));
  end loop;

  return jsonb_build_object('closure', to_jsonb(v_row), 'cancelled', v_n);
end;
$$;

revoke all on function public.close_field(text, date, date, text, text[]) from public, anon;
grant execute on function public.close_field(text, date, date, text, text[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. reopen_field: the closure goes. Practices it cancelled do not come back.
-- ---------------------------------------------------------------------------
create function public.reopen_field(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_role text;
begin
  select role into v_role from profiles where id = auth.uid();
  if (v_role in ('admin', 'director')) is not true then
    raise exception 'Only an admin or a director can reopen a field' using errcode = '42501';
  end if;
  delete from field_closures where id = p_id;
end;
$$;

revoke all on function public.reopen_field(uuid) from public, anon;
grant execute on function public.reopen_field(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. The ordinary "X cancelled N practices for Team" push stays quiet while a
--    field is being closed: close_field sends its own, with the reason.
--
-- Edits the live function text in place and fails loudly, changing nothing,
-- if the text it expects is not there (as audit_fixes_2026_11_10.sql).
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text;
  v_old constant text := E'begin\n  for r in\n    select team_id, count(*) as n,';
  v_new constant text :=
       E'begin\n'
    || E'  -- close_field() is cancelling these and tells the coaches itself, with the reason.\n'
    || E'  if current_setting(''seaford.closing_field'', true) = ''1'' then return null; end if;\n'
    || E'  for r in\n    select team_id, count(*) as n,';
begin
  select pg_get_functiondef('public.notify_team_booking_change()'::regprocedure) into v_def;
  if position(v_old in v_def) = 0 then
    raise exception 'notify_team_booking_change: the loop was not found as expected; nothing changed';
  end if;
  execute replace(v_def, v_old, v_new);
end $$;

-- ---------------------------------------------------------------------------
-- Checks. All six should be true.
-- ---------------------------------------------------------------------------
select
  (select relrowsecurity from pg_class where oid = 'public.field_closures'::regclass)
    as closures_have_rls,
  (select count(*) = 1 and bool_and(cmd = 'SELECT') from pg_policies
     where schemaname = 'public' and tablename = 'field_closures')
    as closures_are_read_only,
  not has_table_privilege('anon', 'public.field_closures', 'select')
    and not has_table_privilege('authenticated', 'public.field_closures', 'insert')
    as nobody_writes_directly,
  (select count(*) = 2 from pg_trigger
     where tgname in ('bookings_enforce_field_open', 'waitlist_enforce_field_open') and not tgisinternal)
    as closed_slots_are_refused,
  has_function_privilege('authenticated', 'public.close_field(text, date, date, text, text[])', 'execute')
    and not has_function_privilege('anon', 'public.close_field(text, date, date, text, text[])', 'execute')
    and not has_function_privilege('anon', 'public.reopen_field(uuid)', 'execute')
    as only_members_can_call,
  position('seaford.closing_field' in pg_get_functiondef('public.notify_team_booking_change()'::regprocedure)) > 0
    and exists (select 1 from pg_publication_tables
                where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'field_closures')
    as quiet_and_live;

commit;
