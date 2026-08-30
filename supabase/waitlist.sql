-- Waitlist feature — run once in the Supabase SQL editor for this project
-- (Settings > SQL Editor). Mirrors the same team-ownership rules as the
-- `bookings` table: a coach can only waitlist for their own team, a director
-- for any team of their gender, an admin for anyone.
--
-- IMPORTANT: this assumes `bookings`'s existing RLS policies check
-- profile.team_id / profile.role / profile.gender against the target team,
-- since that's the only way the app's current 42501 error path makes sense.
-- Sanity-check the policy below against your actual `bookings` policies
-- (Database > Policies in the dashboard) before running — adjust the
-- `can_act_for_team` conditions to match if they differ.

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

-- Helper: can the current user act (book/waitlist) on behalf of this team?
create or replace function can_act_for_team(target_team_id uuid)
returns boolean
language sql
security definer
stable
as $$
  select exists (
    select 1
    from profiles p
    join teams t on t.id = target_team_id
    where p.id = auth.uid()
      and (
        p.role = 'admin'
        or (p.role = 'director' and p.gender = t.gender)
        or (p.role = 'coach' and p.team_id = target_team_id)
      )
  );
$$;

-- Everyone signed in can see the waitlist (so "3 teams waiting" can show to anyone browsing).
create policy "waitlist_select_all" on waitlist
  for select using (auth.uid() is not null);

-- Insert only for a team you can act for.
create policy "waitlist_insert_own_team" on waitlist
  for insert with check (can_act_for_team(team_id) and requested_by = auth.uid());

-- Remove your own team's waitlist entry (or admin/director cleanup).
create policy "waitlist_delete_own_team" on waitlist
  for delete using (can_act_for_team(team_id));

-- Let the app's existing realtime subscription pattern extend to this table.
alter publication supabase_realtime add table waitlist;
