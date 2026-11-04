-- Teams and team assignments (JJ, 2026-11-04). Seaford project only
-- (ref gjpqwmcdejpvffdimddk). Run tests/inspect_2026_11_04.sql first.
-- Then paste this whole file into the SQL editor and Run. It is one
-- transaction: if any statement fails, nothing changes.
--
-- What it does:
--   1. Split teams. Directors can add a second team in a grade
--      ("Girls 2nd Grade Green" and "... White"), each with its own head coach.
--      teams.name holds "Green"; it stays null for a team that isn't split.
--      teams.league_name is optional: it's how the league schedule spells the
--      team, when that isn't simply "Seaford 2 Green".
--   2. team_members: one login can hold several teams, each with its own role.
--      "head" can book for that team; "assistant" is view-only for that team.
--      Exactly one head per team: assigning a new head removes the old one.
--      At most 3 assistants per team.
--   3. Only admins and directors assign, through assign_team_member() and
--      unassign_team_member(). A director assigns on their own program's teams
--      and can assign anyone, including the other program's director.
--   4. Booking, waitlist and "Finished booking" now ask can_book_team():
--      admin; the director of that program; or that team's head coach, whoever
--      they are (including a director heading a team in the other program).
--
-- Kept working while the website, the 1.1 app and invite-coach still use
-- profiles.team_id:
--   - Today's coaches become their team's head and today's assistants stay
--     assistants (the backfill below), so nobody loses access.
--   - A coach or assistant created the old way (invite-coach sets
--     profiles.team_id) is assigned to that team automatically.
--   - profiles.role, team_id and gender are kept in step with the assignments:
--     role "coach" if they head any team, otherwise "assistant"; team_id is
--     the team they head (or else their first assistant team). Admins' and
--     directors' rows are never touched.

begin;

-- 1. Split teams ------------------------------------------------------------

alter table public.teams add column if not exists name text;
alter table public.teams add column if not exists league_name text;
alter table public.teams add column if not exists created_by uuid references auth.users(id) on delete set null;
alter table public.teams add column if not exists created_at timestamptz default now();
alter table public.teams alter column id set default gen_random_uuid();

comment on column public.teams.name is
  'Split squad name ("Green"), or null for the only team in that grade. Shown after the grade.';
comment on column public.teams.league_name is
  'How the league schedule names this team, when it is not "Seaford <grade number>[ <name>]".';

do $$
declare r record;
begin
  if not exists (select 1 from pg_constraint where conname = 'teams_name_not_blank') then
    alter table public.teams add constraint teams_name_not_blank
      check (name is null or length(btrim(name)) > 0);
  end if;
  -- A unique rule on (gender, grade) alone would refuse a split team.
  for r in
    select c.conname from pg_constraint c
    where c.conrelid = 'public.teams'::regclass and c.contype = 'u'
      and (select array_agg(a.attname::text order by a.attname::text)
           from pg_attribute a where a.attrelid = c.conrelid and a.attnum = any (c.conkey))
          = array['gender', 'grade']
  loop
    execute format('alter table public.teams drop constraint %I', r.conname);
    raise notice 'Dropped % (gender + grade only): split teams need the same grade twice.', r.conname;
  end loop;
end $$;

create unique index if not exists teams_gender_grade_name_key
  on public.teams (gender, grade, lower(coalesce(name, '')));
create unique index if not exists teams_league_name_key
  on public.teams (gender, lower(league_name)) where league_name is not null;

-- "Girls 2nd Grade Green". The web's teamLabel(), plus the split name.
create or replace function public.team_label(p_team uuid)
returns text language sql stable security definer set search_path = public as $$
  select (case when gender = 'girls' then 'Girls ' else 'Boys ' end) || grade || coalesce(' ' || name, '')
  from teams where id = p_team
$$;

-- Non-admins could only change priority_finished_at. Now a director may also
-- rename their own program's teams (to split one). No signed-in user means
-- the SQL editor or a server job, as before for every other table.
create or replace function public.enforce_teams_update_scope()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_role text;
  v_gender text;
  v_allowed text[] := array['priority_finished_at'];
begin
  if auth.uid() is null then return new; end if;
  select role, gender into v_role, v_gender from profiles where id = auth.uid();
  if v_role = 'admin' then return new; end if;
  if v_role = 'director' and v_gender = old.gender then
    v_allowed := v_allowed || array['name', 'league_name'];
  end if;
  if (to_jsonb(new) - v_allowed) is distinct from (to_jsonb(old) - v_allowed) then
    raise exception 'You can''t change that about this team' using errcode = '42501';
  end if;
  return new;
end;
$$;

-- 2. Assignments ------------------------------------------------------------

create table if not exists public.team_members (
  team_id     uuid not null references public.teams(id) on delete cascade,
  profile_id  uuid not null references public.profiles(id) on delete cascade,
  role        text not null check (role in ('head', 'assistant')),
  assigned_by uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  primary key (team_id, profile_id)
);
comment on table public.team_members is
  'Who coaches which team. head = books for it; assistant = view-only. Written only by assign_team_member()/unassign_team_member().';

create unique index if not exists team_members_one_head on public.team_members (team_id) where role = 'head';
create index if not exists team_members_profile_idx on public.team_members (profile_id);

alter table public.team_members enable row level security;
drop policy if exists members_read on public.team_members;
create policy members_read on public.team_members for select to authenticated
  using (current_user_role() is not null);
revoke all on public.team_members from anon;
revoke insert, update, delete, truncate on public.team_members from authenticated;
grant select on public.team_members to authenticated;

create or replace function public.enforce_assistant_cap()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.role = 'assistant' and (
    select count(*) from team_members
    where team_id = new.team_id and role = 'assistant' and profile_id <> new.profile_id
  ) >= 3 then
    raise exception 'A team can have at most 3 assistant coaches' using errcode = '23514';
  end if;
  return new;
end;
$$;
drop trigger if exists team_members_assistant_cap on public.team_members;
create trigger team_members_assistant_cap
  before insert or update on public.team_members
  for each row execute function public.enforce_assistant_cap();

-- Backfill. Refuses (and rolls everything back) rather than guess which of
-- two coaches on one team is the head.
do $$
declare v_dupes text;
begin
  select string_agg(t.gender || ' ' || t.grade, ', ') into v_dupes
  from teams t
  where (select count(*) from profiles p where p.role = 'coach' and p.team_id = t.id) > 1;
  if v_dupes is not null then
    raise exception 'These teams have more than one coach today: %. Decide who is head (make the other an assistant in profiles), then re-run.', v_dupes;
  end if;
end $$;

insert into public.team_members (team_id, profile_id, role, assigned_by)
select p.team_id, p.id, 'head', p.invited_by
from profiles p where p.role = 'coach' and p.team_id is not null
on conflict (team_id, profile_id) do nothing;

insert into public.team_members (team_id, profile_id, role, assigned_by)
select p.team_id, p.id, 'assistant', p.invited_by
from profiles p where p.role = 'assistant' and p.team_id is not null
on conflict (team_id, profile_id) do nothing;

-- Keep profiles.role/team_id/gender in step for the clients that read them.
create or replace function public.sync_profile_from_assignments(p_profile uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_role text;
  v_head uuid;
  v_first uuid;
  v_new_role text;
  v_gender text;
begin
  select role into v_role from profiles where id = p_profile;
  if v_role is null or v_role in ('admin', 'director') then return; end if;

  select team_id into v_head from team_members
   where profile_id = p_profile and role = 'head' order by created_at limit 1;
  select team_id into v_first from team_members
   where profile_id = p_profile order by (role = 'head') desc, created_at limit 1;

  v_new_role := case when v_head is not null then 'coach'
                     when v_first is not null then 'assistant'
                     else v_role end;
  select gender into v_gender from teams where id = v_first;

  update profiles
     set role = v_new_role, team_id = v_first, gender = coalesce(v_gender, gender)
   where id = p_profile
     and (role, team_id, gender) is distinct from (v_new_role, v_first, coalesce(v_gender, gender));
end;
$$;

create or replace function public.team_members_sync()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then perform sync_profile_from_assignments(old.profile_id); end if;
  if tg_op in ('INSERT', 'UPDATE') and (tg_op = 'INSERT' or new.profile_id <> old.profile_id) then
    perform sync_profile_from_assignments(new.profile_id);
  end if;
  return null;
end;
$$;
drop trigger if exists team_members_sync on public.team_members;
create trigger team_members_sync
  after insert or update or delete on public.team_members
  for each row execute function public.team_members_sync();

-- The one place an assignment is written. Returns the head it replaced.
create or replace function public.write_team_member(p_team uuid, p_profile uuid, p_role text, p_by uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_old uuid;
begin
  if p_role = 'head' then
    select profile_id into v_old from team_members
     where team_id = p_team and role = 'head' and profile_id <> p_profile;
    if v_old is not null then
      delete from team_members where team_id = p_team and profile_id = v_old;
    end if;
  end if;
  insert into team_members (team_id, profile_id, role, assigned_by)
  values (p_team, p_profile, p_role, p_by)
  on conflict (team_id, profile_id) do update
    set role = excluded.role, assigned_by = excluded.assigned_by;
  return v_old;
end;
$$;

-- A coach or assistant made the old way (invite-coach writes team_id) gets
-- that assignment. An invited coach becomes head, replacing any head there.
create or replace function public.profiles_assign_from_invite()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform write_team_member(new.team_id, new.id,
    case when new.role = 'coach' then 'head' else 'assistant' end, new.invited_by);
  return null;
end;
$$;
drop trigger if exists profiles_assign_from_invite on public.profiles;
create trigger profiles_assign_from_invite
  after insert on public.profiles
  for each row when (new.role in ('coach', 'assistant') and new.team_id is not null)
  execute function public.profiles_assign_from_invite();

-- 3. Who may do what ----------------------------------------------------------

-- Book, cancel, waitlist and mark finished for this team.
create or replace function public.can_book_team(p_team uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles p
    where p.id = auth.uid()
      and (
        p.role = 'admin'
        or (p.role = 'director' and p.gender = (select t.gender from teams t where t.id = p_team))
        or (p.role in ('director', 'coach') and exists (
              select 1 from team_members m
              where m.profile_id = p.id and m.team_id = p_team and m.role = 'head'))
      )
  )
$$;

-- Add, rename, remove and staff this team.
create or replace function public.can_manage_team(p_team uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles p
    where p.id = auth.uid()
      and (p.role = 'admin'
           or (p.role = 'director' and p.gender = (select t.gender from teams t where t.id = p_team)))
  )
$$;

alter policy bookings_insert_scoped on public.bookings with check (
  (not (select app_settings.schedule_locked from app_settings limit 1))
  and (booked_by = (select auth.uid()))
  and can_book_team(bookings.team_id)
  and team_priority_unlocked(bookings.team_id)
);

alter policy bookings_delete_scoped on public.bookings using (
  (not (select app_settings.schedule_locked from app_settings limit 1))
  and can_book_team(bookings.team_id)
);

alter policy waitlist_insert_scoped on public.waitlist with check (
  (requested_by = (select auth.uid()))
  and can_book_team(waitlist.team_id)
);

alter policy waitlist_delete_scoped on public.waitlist using (
  ((current_user_role() = any (array['admin'::text, 'director'::text, 'coach'::text]))
    and requested_by = (select auth.uid()))
  or can_book_team(waitlist.team_id)
);

alter policy teams_update_priority_scoped on public.teams
  using (can_book_team(teams.id) or can_manage_team(teams.id))
  with check (can_book_team(teams.id) or can_manage_team(teams.id));

-- Directors see every coach, assistant and director (to assign anyone,
-- including the other program's director). Coaches see the people they
-- share a team with. Everything else about who sees profiles is unchanged.
alter policy profiles_select_combined on public.profiles using (
  (id = (select auth.uid()))
  or (current_user_role() = 'admin'::text)
  or ((current_user_role() = 'director'::text) and (current_user_gender() = gender))
  or ((current_user_role() = 'director'::text) and (role = any (array['director'::text, 'coach'::text, 'assistant'::text])))
  or ((current_user_role() = 'coach'::text) and (role = 'assistant'::text) and (team_id = current_user_team()))
  or exists (
    select 1 from team_members mine join team_members theirs on theirs.team_id = mine.team_id
    where mine.profile_id = (select auth.uid()) and theirs.profile_id = profiles.id
  )
);

-- 4. What the apps call -------------------------------------------------------

create or replace function public.assign_team_member(p_team uuid, p_profile uuid, p_role text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_target_role text;
  v_email text;
  v_old uuid;
begin
  if p_role not in ('head', 'assistant') then
    raise exception 'Role must be head or assistant' using errcode = '22023';
  end if;
  if not exists (select 1 from teams where id = p_team) then
    raise exception 'That team no longer exists' using errcode = 'P0002';
  end if;
  if not can_manage_team(p_team) then
    raise exception 'Only an admin or this program''s director can assign coaches' using errcode = '42501';
  end if;
  select role, email into v_target_role, v_email from profiles where id = p_profile;
  if v_target_role is null then
    raise exception 'That person no longer has an account' using errcode = 'P0002';
  end if;
  if v_target_role = 'admin' then
    raise exception 'Admins aren''t assigned to teams' using errcode = '22023';
  end if;

  v_old := write_team_member(p_team, p_profile, p_role, auth.uid());
  perform log_activity(case when p_role = 'head' then 'assigned head coach' else 'assigned assistant' end,
                       p_team, v_email || coalesce(', replacing ' || (select email from profiles where id = v_old), ''));
  return jsonb_build_object('replaced', v_old);
end;
$$;

create or replace function public.unassign_team_member(p_team uuid, p_profile uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_email text;
begin
  if not can_manage_team(p_team) then
    raise exception 'Only an admin or this program''s director can change a team''s coaches' using errcode = '42501';
  end if;
  delete from team_members where team_id = p_team and profile_id = p_profile;
  if found then
    select email into v_email from profiles where id = p_profile;
    perform log_activity('removed from team', p_team, v_email);
  end if;
end;
$$;

create or replace function public.create_team(p_gender text, p_grade text, p_name text default null, p_league_name text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_role text;
  v_my_gender text;
  v_id uuid;
begin
  select role, gender into v_role, v_my_gender from profiles where id = auth.uid();
  if not (v_role = 'admin' or (v_role = 'director' and v_my_gender = p_gender)) then
    raise exception 'Only an admin or this program''s director can add teams' using errcode = '42501';
  end if;
  if p_gender not in ('girls', 'boys') then
    raise exception 'Program must be girls or boys' using errcode = '22023';
  end if;
  if grade_rank(p_grade) < 0 then
    raise exception 'Unknown grade: %', p_grade using errcode = '22023';
  end if;
  begin
    insert into teams (gender, grade, name, league_name, created_by)
    values (p_gender, p_grade, nullif(btrim(p_name), ''), nullif(btrim(p_league_name), ''), auth.uid())
    returning id into v_id;
  exception when unique_violation then
    raise exception 'There''s already a % % team%. Give the new one a different name (Green, White...).',
      initcap(p_gender), p_grade, coalesce(' called ' || nullif(btrim(p_name), ''), ' without a name')
      using errcode = '23505';
  end;
  perform log_activity('added team', v_id, team_label(v_id));
  return v_id;
end;
$$;

create or replace function public.rename_team(p_team uuid, p_name text, p_league_name text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not can_manage_team(p_team) then
    raise exception 'Only an admin or this program''s director can rename teams' using errcode = '42501';
  end if;
  begin
    update teams set name = nullif(btrim(p_name), ''), league_name = nullif(btrim(p_league_name), '')
     where id = p_team;
  exception when unique_violation then
    raise exception 'Another team in that grade already has that name' using errcode = '23505';
  end;
  perform log_activity('renamed team', p_team, team_label(p_team));
end;
$$;

create or replace function public.delete_team(p_team uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_label text;
begin
  if not can_manage_team(p_team) then
    raise exception 'Only an admin or this program''s director can remove teams' using errcode = '42501';
  end if;
  if exists (select 1 from bookings where team_id = p_team) then
    raise exception 'This team still has bookings. Clear them first (Admin > Clear Bookings).' using errcode = '23503';
  end if;
  v_label := team_label(p_team);
  perform log_activity('removed team', p_team, v_label);
  -- Unassign first, so each coach's profiles.team_id moves off this team.
  delete from team_members where team_id = p_team;
  delete from teams where id = p_team;
end;
$$;

-- Grants: the helpers stay private; policies and the apps get what they call.
revoke all on function public.team_label(uuid) from public, anon;
revoke all on function public.sync_profile_from_assignments(uuid) from public, anon, authenticated;
revoke all on function public.team_members_sync() from public, anon, authenticated;
revoke all on function public.write_team_member(uuid, uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.profiles_assign_from_invite() from public, anon, authenticated;
revoke all on function public.enforce_assistant_cap() from public, anon, authenticated;
revoke all on function public.can_book_team(uuid) from public, anon;
revoke all on function public.can_manage_team(uuid) from public, anon;
revoke all on function public.assign_team_member(uuid, uuid, text) from public, anon;
revoke all on function public.unassign_team_member(uuid, uuid) from public, anon;
revoke all on function public.create_team(text, text, text, text) from public, anon;
revoke all on function public.rename_team(uuid, text, text) from public, anon;
revoke all on function public.delete_team(uuid) from public, anon;
grant execute on function public.team_label(uuid) to authenticated;
grant execute on function public.can_book_team(uuid) to authenticated;
grant execute on function public.can_manage_team(uuid) to authenticated;
grant execute on function public.assign_team_member(uuid, uuid, text) to authenticated;
grant execute on function public.unassign_team_member(uuid, uuid) to authenticated;
grant execute on function public.create_team(text, text, text, text) to authenticated;
grant execute on function public.rename_team(uuid, text, text) to authenticated;
grant execute on function public.delete_team(uuid) to authenticated;

do $$
begin
  alter publication supabase_realtime add table public.team_members;
exception when duplicate_object then null;
end $$;

commit;
