-- Field catalog in the database (2026-11). Seaford project only
-- (ref gjpqwmcdejpvffdimddk); do NOT run on Snowleopard.
--
-- `fields` (names, notes, order) + `field_slots` (the allowlist the booking
-- trigger already enforces) are now the field list both the website and the
-- native app read. index.html keeps FIELDS_FALLBACK (lib/field-catalog.js)
-- only for when that read fails. To change a field or a time, change these
-- tables: no website edit, no app update.
--
-- Season dates move into app_settings for the same reason. NOTE: the
-- bookings_date_in_season / waitlist_date_in_season CHECKs from
-- security_hardening.sql still hold 2027-03-01..2027-06-30; a new season
-- changes those constraints as well as these two columns.
--
-- Safe to re-run.

create table if not exists fields (
  id text primary key,
  name text not null,
  short_name text,
  note text,
  sort int not null
);

comment on table fields is
  'Field names, notes and display order. With field_slots, the catalog the website and the iPhone app read.';

alter table fields enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'fields' and policyname = 'fields_select_authenticated'
  ) then
    create policy "fields_select_authenticated" on fields
      for select using ((select auth.role()) = 'authenticated');
  end if;
end $$;

grant select on fields to authenticated;

insert into fields (id, name, short_name, note, sort) values
  ('cedarcreek', 'Cedar Creek', null, 'East Field, Tuesday and Thursday only. Half field only (shared with soccer and Wantagh Lax).', 1),
  ('harbor', 'Seaford Harbor', null, 'Field 1 inside track, Field 2 outside track.', 2),
  ('seafordhs', 'Seaford HS', null, 'Turf field. School games have priority weeknights.', 3),
  ('sms', 'Seaford MS', null, 'Grass field. School teams have priority; permit starts at 5 PM.', 4),
  ('seamans', 'Seamans Neck Park', 'Seamans Neck', 'Field A closest to parking, B mid field, C far end.', 5)
on conflict (id) do update set
  name = excluded.name, short_name = excluded.short_name, note = excluded.note, sort = excluded.sort;

-- Filled by the column default, not an UPDATE: app_settings_enforce_admin_update
-- rejects any UPDATE without an admin auth.uid(), and the SQL editor has none.
-- ADD COLUMN ... DEFAULT fills the existing row without firing that trigger;
-- the defaults are then dropped so nothing else inherits them.
alter table app_settings
  add column if not exists season_start date default '2027-03-01',
  add column if not exists season_end date default '2027-06-30';
alter table app_settings
  alter column season_start drop default,
  alter column season_end drop default;
