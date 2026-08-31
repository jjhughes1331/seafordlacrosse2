-- Waitlist feature — verified against the live SeafordLacrosse Supabase
-- project's actual RLS policies (pulled via pg_policies) before writing this,
-- so the team-ownership checks below exactly mirror bookings_insert_scoped /
-- bookings_delete_scoped rather than guessing. Run once in the SQL editor.

create table if not exists waitlist (
  id uuid primary key default gen_random_uuid(),
  field_id text not null,
  date date not null,
  subfield text not null,
  time text not null,
  team_id uuid not null references teams(id) on delete cascade,
  requested_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (field_id, date, subfield, time, team_id)
);

alter table waitlist enable row level security;

-- Anyone signed in can see who's waiting (so "waitlist (2)" can render for any viewer).
create policy "waitlist_select_authenticated" on waitlist
  for select using (( select auth.role() ) = 'authenticated');

-- Same team-ownership rule as bookings_insert_scoped, minus the schedule-lock
-- check — waitlisting during a lock is harmless (no slot changes hands) and
-- the app's join/leave waitlist buttons don't gate on scheduleLocked either.
create policy "waitlist_insert_scoped" on waitlist
  for insert with check (
    (requested_by = ( select auth.uid() ))
    and (
      exists (select 1 from profiles p where p.id = ( select auth.uid() ) and p.role = 'admin')
      or exists (select 1 from profiles p where p.id = ( select auth.uid() ) and p.role = 'coach' and p.team_id = waitlist.team_id)
      or exists (
        select 1 from profiles p join teams t on t.id = waitlist.team_id
        where p.id = ( select auth.uid() ) and p.role = 'director' and p.gender = t.gender
      )
    )
  );

-- Same team-ownership rule as bookings_delete_scoped (minus lock + booked_by,
-- since a waitlist row has no "booked_by" concept — requested_by instead).
create policy "waitlist_delete_scoped" on waitlist
  for delete using (
    (requested_by = ( select auth.uid() ))
    or exists (select 1 from profiles p where p.id = ( select auth.uid() ) and p.role = 'admin')
    or exists (select 1 from profiles p where p.id = ( select auth.uid() ) and p.role = 'coach' and p.team_id = waitlist.team_id)
    or exists (
      select 1 from profiles p join teams t on t.id = waitlist.team_id
      where p.id = ( select auth.uid() ) and p.role = 'director' and p.gender = t.gender
    )
  );

-- Extend the app's existing realtime subscription pattern to this table.
alter publication supabase_realtime add table waitlist;
