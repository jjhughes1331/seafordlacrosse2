-- Security hardening — paste once into the Supabase SQL editor.
-- Idempotent-ish: safe to re-run. Does not require the live project to be
-- reachable from this repo. Keep field_slots in sync with FIELDS in index.html.
--
-- Season window: 2027-03-01 .. 2027-06-30 (matches SEASON_START / SEASON_END).
-- Slot allowlist: (field_id, subfield, time) plus days[] using Sunday=0
-- (PostgreSQL EXTRACT(DOW) and JavaScript Date#getDay()).

-- ---------------------------------------------------------------------------
-- 1. Season date CHECK on bookings and waitlist
-- If this fails, existing rows sit outside the window. Inspect with:
--   SELECT * FROM bookings WHERE date < DATE '2027-03-01' OR date > DATE '2027-06-30';
--   SELECT * FROM waitlist WHERE date < DATE '2027-03-01' OR date > DATE '2027-06-30';
-- Fix those rows, then re-run this file (or just the ALTER TABLE ADD CONSTRAINT).
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'bookings_date_in_season'
  ) then
    alter table bookings
      add constraint bookings_date_in_season
      check (date >= date '2027-03-01' and date <= date '2027-06-30');
  end if;
exception
  when check_violation then
    raise notice 'bookings_date_in_season was NOT added: one or more bookings.date values are outside 2027-03-01 .. 2027-06-30. Delete or fix those rows, then re-run.';
end $$;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'waitlist_date_in_season'
  ) then
    alter table waitlist
      add constraint waitlist_date_in_season
      check (date >= date '2027-03-01' and date <= date '2027-06-30');
  end if;
exception
  when undefined_table then
    raise notice 'waitlist table is missing — skip waitlist date constraint (run supabase/waitlist.sql first if you use waitlist).';
  when check_violation then
    raise notice 'waitlist_date_in_season was NOT added: one or more waitlist.date values are outside 2027-03-01 .. 2027-06-30. Delete or fix those rows, then re-run.';
end $$;

-- ---------------------------------------------------------------------------
-- 2. Field slot allowlist (seeded from FIELDS in index.html)
-- ---------------------------------------------------------------------------
create table if not exists field_slots (
  field_id text not null,
  subfield text not null,
  time text not null,
  days int[] not null,
  primary key (field_id, subfield, time)
);

comment on table field_slots is
  'Allowlisted bookable slots. days uses Sunday=0 to match JS getDay() / EXTRACT(DOW). Keep in sync with FIELDS in index.html.';

alter table field_slots enable row level security;

-- Read-only for signed-in users; seed/admin changes go through the SQL editor (table owner).
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'field_slots' and policyname = 'field_slots_select_authenticated'
  ) then
    create policy "field_slots_select_authenticated" on field_slots
      for select using ((select auth.role()) = 'authenticated');
  end if;
end $$;

grant select on field_slots to authenticated;

delete from field_slots;

insert into field_slots (field_id, subfield, time, days) values
  ('cedarcreek', '1/2 Field', '4:30-5:30 PM', ARRAY[2,4]),
  ('cedarcreek', '1/2 Field', '5:30-6:30 PM', ARRAY[2,4]),
  ('cedarcreek', '1/2 Field', '6:30-8:00 PM', ARRAY[2,4]),
  ('harbor', 'Field 1', '4:30-5:30 PM', ARRAY[1,2,3,4,5]),
  ('harbor', 'Field 1', '5:30-6:30 PM', ARRAY[1,2,3,4,5]),
  ('harbor', 'Field 1', '6:30-7:30 PM', ARRAY[1,2,3,4,5]),
  ('harbor', 'Field 1', '7:30-8:30 PM', ARRAY[1,2,3,4,5]),
  ('harbor', 'Field 2', '4:30-5:30 PM', ARRAY[1,2,3,4,5]),
  ('harbor', 'Field 2', '5:30-6:30 PM', ARRAY[1,2,3,4,5]),
  ('harbor', 'Field 2', '6:30-7:30 PM', ARRAY[1,2,3,4,5]),
  ('harbor', 'Field 2', '7:30-8:30 PM', ARRAY[1,2,3,4,5]),
  ('harbor', 'Field 1', '9:00-10:00 AM', ARRAY[0,6]),
  ('harbor', 'Field 1', '10:00-11:00 AM', ARRAY[0,6]),
  ('harbor', 'Field 1', '11:00-12:00 PM', ARRAY[0,6]),
  ('harbor', 'Field 1', '12:00-1:00 PM', ARRAY[0,6]),
  ('harbor', 'Field 1', '1:00-2:00 PM', ARRAY[0,6]),
  ('harbor', 'Field 1', '2:00-3:00 PM', ARRAY[0,6]),
  ('harbor', 'Field 1', '3:00-4:00 PM', ARRAY[0,6]),
  ('harbor', 'Field 1', '4:00-5:00 PM', ARRAY[0,6]),
  ('harbor', 'Field 1', '5:00-6:00 PM', ARRAY[0,6]),
  ('harbor', 'Field 1', '6:00-7:00 PM', ARRAY[0,6]),
  ('harbor', 'Field 1', '7:00-8:00 PM', ARRAY[0,6]),
  ('harbor', 'Field 2', '9:00-10:00 AM', ARRAY[0,6]),
  ('harbor', 'Field 2', '10:00-11:00 AM', ARRAY[0,6]),
  ('harbor', 'Field 2', '11:00-12:00 PM', ARRAY[0,6]),
  ('harbor', 'Field 2', '12:00-1:00 PM', ARRAY[0,6]),
  ('harbor', 'Field 2', '1:00-2:00 PM', ARRAY[0,6]),
  ('harbor', 'Field 2', '2:00-3:00 PM', ARRAY[0,6]),
  ('harbor', 'Field 2', '3:00-4:00 PM', ARRAY[0,6]),
  ('harbor', 'Field 2', '4:00-5:00 PM', ARRAY[0,6]),
  ('harbor', 'Field 2', '5:00-6:00 PM', ARRAY[0,6]),
  ('harbor', 'Field 2', '6:00-7:00 PM', ARRAY[0,6]),
  ('harbor', 'Field 2', '7:00-8:00 PM', ARRAY[0,6]),
  ('seafordhs', 'Half Field A (North)', '7:15-9:00 PM', ARRAY[1,2,3,4,5]),
  ('seafordhs', 'Half Field B (South)', '7:15-9:00 PM', ARRAY[1,2,3,4,5]),
  ('seafordhs', 'Half Field A (North)', '1:00-2:00 PM', ARRAY[6]),
  ('seafordhs', 'Half Field A (North)', '2:00-3:00 PM', ARRAY[6]),
  ('seafordhs', 'Half Field A (North)', '3:00-4:00 PM', ARRAY[6]),
  ('seafordhs', 'Half Field A (North)', '4:00-5:00 PM', ARRAY[6]),
  ('seafordhs', 'Half Field A (North)', '5:00-6:00 PM', ARRAY[6]),
  ('seafordhs', 'Half Field A (North)', '6:00-7:00 PM', ARRAY[6]),
  ('seafordhs', 'Half Field B (South)', '1:00-2:00 PM', ARRAY[6]),
  ('seafordhs', 'Half Field B (South)', '2:00-3:00 PM', ARRAY[6]),
  ('seafordhs', 'Half Field B (South)', '3:00-4:00 PM', ARRAY[6]),
  ('seafordhs', 'Half Field B (South)', '4:00-5:00 PM', ARRAY[6]),
  ('seafordhs', 'Half Field B (South)', '5:00-6:00 PM', ARRAY[6]),
  ('seafordhs', 'Half Field B (South)', '6:00-7:00 PM', ARRAY[6]),
  ('sms', 'Half Field A', '6:00-7:00 PM', ARRAY[1,2,3,4,5]),
  ('sms', 'Half Field A', '7:30-9:00 PM', ARRAY[1,2,3,4,5]),
  ('sms', 'Half Field B', '6:00-7:00 PM', ARRAY[1,2,3,4,5]),
  ('sms', 'Half Field B', '7:30-9:00 PM', ARRAY[1,2,3,4,5]),
  ('sms', 'Half Field A', '1:00-2:00 PM', ARRAY[6]),
  ('sms', 'Half Field A', '2:00-3:00 PM', ARRAY[6]),
  ('sms', 'Half Field A', '3:00-4:00 PM', ARRAY[6]),
  ('sms', 'Half Field A', '4:00-5:00 PM', ARRAY[6]),
  ('sms', 'Half Field A', '5:00-6:00 PM', ARRAY[6]),
  ('sms', 'Half Field B', '1:00-2:00 PM', ARRAY[6]),
  ('sms', 'Half Field B', '2:00-3:00 PM', ARRAY[6]),
  ('sms', 'Half Field B', '3:00-4:00 PM', ARRAY[6]),
  ('sms', 'Half Field B', '4:00-5:00 PM', ARRAY[6]),
  ('sms', 'Half Field B', '5:00-6:00 PM', ARRAY[6]),
  ('seamans', 'Field A', '5:00-6:30 PM', ARRAY[1,2,3,4,5]),
  ('seamans', 'Field A', '6:30-8:00 PM', ARRAY[1,2,3,4,5]),
  ('seamans', 'Field A', '8:00-10:00 PM', ARRAY[1,2,3,4,5]),
  ('seamans', 'Field B', '5:00-6:30 PM', ARRAY[1,2,3,4,5]),
  ('seamans', 'Field B', '6:30-8:00 PM', ARRAY[1,2,3,4,5]),
  ('seamans', 'Field B', '8:00-10:00 PM', ARRAY[1,2,3,4,5]),
  ('seamans', 'Field C', '5:00-6:30 PM', ARRAY[1,2,3,4,5]),
  ('seamans', 'Field C', '6:30-8:00 PM', ARRAY[1,2,3,4,5]),
  ('seamans', 'Field C', '8:00-10:00 PM', ARRAY[1,2,3,4,5]),
  ('seamans', 'Half Field A', '1:00-2:00 PM', ARRAY[6]),
  ('seamans', 'Half Field A', '2:00-3:00 PM', ARRAY[6]),
  ('seamans', 'Half Field A', '3:00-4:00 PM', ARRAY[6]),
  ('seamans', 'Half Field A', '4:00-5:00 PM', ARRAY[6]),
  ('seamans', 'Half Field A', '5:00-6:00 PM', ARRAY[6]),
  ('seamans', 'Half Field B', '1:00-2:00 PM', ARRAY[6]),
  ('seamans', 'Half Field B', '2:00-3:00 PM', ARRAY[6]),
  ('seamans', 'Half Field B', '3:00-4:00 PM', ARRAY[6]),
  ('seamans', 'Half Field B', '4:00-5:00 PM', ARRAY[6]),
  ('seamans', 'Half Field B', '5:00-6:00 PM', ARRAY[6]);

create or replace function public.slot_is_allowed(p_field_id text, p_subfield text, p_time text, p_date date)
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from field_slots s
    where s.field_id = p_field_id
      and s.subfield = p_subfield
      and s.time = p_time
      and (extract(dow from p_date)::int = any (s.days))
  );
$$;

create or replace function public.enforce_allowed_slot()
returns trigger
language plpgsql
as $$
begin
  if not public.slot_is_allowed(new.field_id, new.subfield, new.time, new.date) then
    raise exception 'Slot is not on the allowlist: field_id=%, subfield=%, time=%, date=% (dow=%)',
      new.field_id, new.subfield, new.time, new.date, extract(dow from new.date)::int
      using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists bookings_enqueue_allowed_slot on bookings;
create trigger bookings_enforce_allowed_slot
  before insert or update of field_id, subfield, time, date on bookings
  for each row execute function public.enforce_allowed_slot();

do $$
begin
  drop trigger if exists waitlist_enforce_allowed_slot on waitlist;
  create trigger waitlist_enforce_allowed_slot
    before insert or update of field_id, subfield, time, date on waitlist
    for each row execute function public.enforce_allowed_slot();
exception
  when undefined_table then
    raise notice 'waitlist table is missing — skip waitlist slot trigger.';
end $$;

-- ---------------------------------------------------------------------------
-- 3. Teams: coaches/directors may only change priority_finished_at
--    (cannot change gender/grade or any other column). Admins unrestricted.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_teams_update_scope()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') then
    return new;
  end if;
  if new.gender is distinct from old.gender or new.grade is distinct from old.grade then
    raise exception 'Only admins can change teams.gender or teams.grade'
      using errcode = '42501';
  end if;
  if (to_jsonb(new) - 'priority_finished_at') is distinct from (to_jsonb(old) - 'priority_finished_at') then
    raise exception 'Non-admins may only update teams.priority_finished_at'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists teams_enforce_update_scope on teams;
create trigger teams_enforce_update_scope
  before update on teams
  for each row execute function public.enforce_teams_update_scope();

-- ---------------------------------------------------------------------------
-- 4. app_settings: UPDATE is admin-only. SELECT policies are left alone so
--    directors (and other authenticated roles) can still read lock/priority
--    state. Existing UPDATE policies — names unknown in this repo — are
--    dropped and replaced.
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select policyname from pg_policies
    where schemaname = 'public' and tablename = 'app_settings' and cmd = 'UPDATE'
  loop
    execute format('drop policy if exists %I on app_settings', r.policyname);
  end loop;
end $$;

create policy "app_settings_update_admin" on app_settings
  for update
  using (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin'))
  with check (exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin'));

create or replace function public.enforce_app_settings_admin_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- SQL editor / service role (no end-user JWT). RLS is already bypassed
  -- for these; the trigger still fires, so allow them through.
  if coalesce(auth.role(), '') in ('service_role', 'supabase_admin') then
    return new;
  end if;
  if auth.uid() is null and current_user in ('postgres', 'supabase_admin') then
    return new;
  end if;
  if not exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') then
    raise exception 'Only admins can update app_settings'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists app_settings_enforce_admin_update on app_settings;
create trigger app_settings_enforce_admin_update
  before update on app_settings
  for each row execute function public.enforce_app_settings_admin_update();
