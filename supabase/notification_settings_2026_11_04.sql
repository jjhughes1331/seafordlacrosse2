-- Notification settings (JJ, 2026-11-04). Seaford project only
-- (ref gjpqwmcdejpvffdimddk). Run AFTER teams_assignments_2026_11_04.sql.
-- One transaction: if any statement fails, nothing changes.
--
-- Each person has a switch per alert, stored here so it follows them to the
-- website and every phone:
--   waitlist_opened  A slot they're waiting on opened up          (on)
--   schedule_lock    The schedule was locked or unlocked          (on)
--   booking_turn     Priority booking reached one of their teams  (on)
--   team_bookings    Someone booked or cancelled for their teams  (off)
--   field_duty       Their team sets up / breaks down the field   (on)
--                    (sent by games_2026_11_04.sql)
--
-- "Their teams": until someone picks teams in settings, alerts cover the
-- teams they're assigned to (head or assistant), and for a director every
-- team in their program too. That is exactly who gets alerts today, so
-- nothing changes for anyone until they open settings. Once they pick, only
-- the picked teams count, and only while they may still follow them
-- (a coach can pick among their assigned teams; a director also any team in
-- their program; an admin any team).
--
-- Nobody has a settings row until they save one; a missing row means the
-- defaults above.

begin;

create table if not exists public.notification_prefs (
  profile_id      uuid primary key references public.profiles(id) on delete cascade,
  waitlist_opened boolean not null default true,
  schedule_lock   boolean not null default true,
  booking_turn    boolean not null default true,
  team_bookings   boolean not null default false,
  field_duty      boolean not null default true,
  teams_chosen    boolean not null default false,
  updated_at      timestamptz not null default now()
);
comment on column public.notification_prefs.teams_chosen is
  'false: alerts cover my assigned teams (directors: and my program). true: only the teams in notification_teams.';

create table if not exists public.notification_teams (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  team_id    uuid not null references public.teams(id) on delete cascade,
  primary key (profile_id, team_id)
);

alter table public.notification_prefs enable row level security;
alter table public.notification_teams enable row level security;

drop policy if exists own_prefs on public.notification_prefs;
create policy own_prefs on public.notification_prefs for all to authenticated
  using (profile_id = (select auth.uid()))
  with check (profile_id = (select auth.uid()) and current_user_role() is not null);

-- Team picks go through set_notification_teams() so they're checked; this
-- table is read-only to its owner.
drop policy if exists own_teams on public.notification_teams;
create policy own_teams on public.notification_teams for select to authenticated
  using (profile_id = (select auth.uid()));

revoke all on public.notification_prefs, public.notification_teams from anon;
revoke truncate, references, trigger on public.notification_prefs from authenticated;
revoke insert, update, delete, truncate on public.notification_teams from authenticated;
grant select, insert, update on public.notification_prefs to authenticated;
grant select on public.notification_teams to authenticated;

-- May this person get alerts about this team at all?
create or replace function public.may_follow_team(p_profile uuid, p_team uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from team_members m where m.profile_id = p_profile and m.team_id = p_team)
      or exists (select 1 from profiles p where p.id = p_profile
                   and (p.role = 'admin'
                        or (p.role = 'director' and p.gender = (select t.gender from teams t where t.id = p_team))))
$$;

-- Save the teams this person's alerts cover. null = go back to the default
-- (assigned teams, plus the program for a director). Teams they may not
-- follow are dropped. Returns what was saved.
create or replace function public.set_notification_teams(p_team_ids uuid[])
returns uuid[] language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_saved uuid[];
begin
  if current_user_role() is null then
    raise exception 'Not signed in' using errcode = '42501';
  end if;
  insert into notification_prefs (profile_id) values (v_me) on conflict (profile_id) do nothing;
  delete from notification_teams where profile_id = v_me;
  if p_team_ids is null then
    update notification_prefs set teams_chosen = false, updated_at = now() where profile_id = v_me;
    return null;
  end if;
  insert into notification_teams (profile_id, team_id)
  select distinct v_me, t from unnest(p_team_ids) as t
  where may_follow_team(v_me, t);
  update notification_prefs set teams_chosen = true, updated_at = now() where profile_id = v_me;
  select coalesce(array_agg(team_id), '{}') into v_saved from notification_teams where profile_id = v_me;
  return v_saved;
end;
$$;

-- Who should get alert p_kind about any of p_team_ids, minus p_exclude
-- (the person who caused it). The one place the rules above live.
create or replace function public.alert_followers(p_team_ids uuid[], p_kind text, p_exclude uuid default null)
returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct p.id), '{}')
  from profiles p
  left join notification_prefs np on np.profile_id = p.id
  where p.id is distinct from p_exclude
    and case p_kind
          when 'waitlist_opened' then coalesce(np.waitlist_opened, true)
          when 'booking_turn'    then coalesce(np.booking_turn, true)
          when 'team_bookings'   then coalesce(np.team_bookings, false)
          when 'field_duty'      then coalesce(np.field_duty, true)
          else false
        end
    and exists (
      select 1 from unnest(p_team_ids) as tid(team_id)
      where may_follow_team(p.id, tid.team_id)
        and case when coalesce(np.teams_chosen, false)
              then exists (select 1 from notification_teams nt
                           where nt.profile_id = p.id and nt.team_id = tid.team_id)
              else exists (select 1 from team_members m
                           where m.profile_id = p.id and m.team_id = tid.team_id)
                   or (p.role = 'director'
                       and p.gender = (select t.gender from teams t where t.id = tid.team_id))
            end
    )
$$;

-- Everyone with this (team-less) alert switched on.
create or replace function public.alert_everyone(p_kind text)
returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(p.id), '{}')
  from profiles p left join notification_prefs np on np.profile_id = p.id
  where case p_kind when 'schedule_lock' then coalesce(np.schedule_lock, true) else false end
$$;

-- Send one push through the send-push Edge Function. Does nothing for an
-- empty list. Same secret and endpoint as push_notifications.sql.
create or replace function public.push_to(p_title text, p_message text, p_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare v_secret text;
begin
  if p_ids is null or cardinality(p_ids) = 0 then return; end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_trigger_secret';
  if v_secret is null then return; end if;
  perform net.http_post(
    url := 'https://gjpqwmcdejpvffdimddk.supabase.co/functions/v1/send-push',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body := jsonb_build_object('title', p_title, 'message', p_message, 'externalIds', to_jsonb(p_ids))
  );
end;
$$;

-- "Harbor Field 1, Tue, Mar 2, 4:30-5:30 PM"
create or replace function public.slot_label(p_field text, p_subfield text, p_date date, p_time text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select name from fields where id = p_field), p_field)
         || coalesce(' ' || nullif(p_subfield, ''), '')
         || ', ' || to_char(p_date, 'Dy, Mon FMDD') || ', ' || p_time
$$;

create or replace function public.person_name(p_profile uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(nullif(btrim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), ''), email)
  from profiles where id = p_profile
$$;

-- 1. Waitlist slot opened: rewritten to honour settings ------------------------
-- Goes to whoever waited for that slot and to the waiting teams' followers,
-- each only with "slot opened" on.
create or replace function public.notify_waitlist_on_slot_open()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_teams uuid[];
  v_requesters uuid[];
  v_ids uuid[];
begin
  select array_agg(distinct team_id), array_agg(distinct requested_by)
    into v_teams, v_requesters
  from waitlist
  where field_id = old.field_id and date = old.date and subfield = old.subfield and time = old.time;
  if v_teams is null then return old; end if;

  select coalesce(array_agg(distinct id), '{}') into v_ids from (
    select unnest(alert_followers(v_teams, 'waitlist_opened')) as id
    union
    select p.id from profiles p left join notification_prefs np on np.profile_id = p.id
    where p.id = any (v_requesters) and coalesce(np.waitlist_opened, true)
  ) s;

  perform push_to('A slot opened up!',
                  slot_label(old.field_id, old.subfield, old.date, old.time) || ' is now open.',
                  v_ids);
  return old;
end;
$$;

-- 2. Schedule locked/unlocked: no longer a broadcast, so it can be switched off.
create or replace function public.notify_schedule_lock_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.schedule_locked is distinct from old.schedule_locked then
    perform push_to(
      case when new.schedule_locked then 'Schedule locked' else 'Schedule unlocked' end,
      case when new.schedule_locked then 'Booking is temporarily paused by an admin.'
           else 'Booking is open again.' end,
      alert_everyone('schedule_lock'));
  end if;
  return new;
end;
$$;

-- 3. A grade's turn to book: when the last team of a grade finishes ----------
create or replace function public.notify_priority_tier_unlock()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_rank int;
  v_teams uuid[];
begin
  if new.priority_finished_at is not null and old.priority_finished_at is null then
    v_rank := grade_rank(new.grade);
    if v_rank > 0 and not exists (
      select 1 from teams t where grade_rank(t.grade) = v_rank and t.priority_finished_at is null
    ) then
      select array_agg(id) into v_teams from teams where grade_rank(grade) = v_rank - 1;
      perform push_to('Booking is open for your team!',
                      'The next grade tier just unlocked — you can now book field time.',
                      alert_followers(v_teams, 'booking_turn'));
    end if;
  end if;
  return new;
end;
$$;

-- ...and when a director pushes a grade through (Admin > Priority Booking).
-- Before this, forcing a grade through told nobody.
create or replace function public.notify_priority_force()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_rank int;
  v_teams uuid[];
begin
  if not coalesce(new.priority_booking_enabled, false) then return new; end if;
  for v_rank in
    select r from unnest(new.priority_forced_ranks) as r
    except select r from unnest(coalesce(old.priority_forced_ranks, '{}')) as r
  loop
    select array_agg(id) into v_teams from teams
     where grade_rank(grade) = v_rank - 1 and team_priority_unlocked(id);
    if v_teams is not null then
      perform push_to('Booking is open for your team!',
                      'The next grade tier just unlocked — you can now book field time.',
                      alert_followers(v_teams, 'booking_turn'));
    end if;
  end loop;
  return new;
end;
$$;
drop trigger if exists trg_notify_priority_force on public.app_settings;
create trigger trg_notify_priority_force
  after update of priority_forced_ranks on public.app_settings
  for each row execute function public.notify_priority_force();

-- 4. New: someone booked or cancelled for a team I follow --------------------
-- Statement-level, so Clear Bookings or a season of repeats sends one push
-- per team, not one per practice. The person who did it isn't told.
create or replace function public.notify_team_booking_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_actor uuid := auth.uid();
  v_who text := coalesce(person_name(auth.uid()), 'An admin');
  v_verb text := case when tg_op = 'INSERT' then ' booked ' else ' cancelled ' end;
begin
  for r in
    select team_id, count(*) as n,
           min(slot_label(field_id, subfield, date, time)) as one_slot
    from changed group by team_id
  loop
    perform push_to(
      case when tg_op = 'INSERT' then 'New booking for ' else 'Booking cancelled for ' end || team_label(r.team_id),
      v_who || v_verb || case when r.n = 1 then r.one_slot else r.n || ' practices' end
            || ' for ' || team_label(r.team_id) || '.',
      alert_followers(array[r.team_id], 'team_bookings', v_actor));
  end loop;
  return null;
end;
$$;
drop trigger if exists trg_notify_team_booking_insert on public.bookings;
create trigger trg_notify_team_booking_insert
  after insert on public.bookings
  referencing new table as changed
  for each statement execute function public.notify_team_booking_change();
drop trigger if exists trg_notify_team_booking_delete on public.bookings;
create trigger trg_notify_team_booking_delete
  after delete on public.bookings
  referencing old table as changed
  for each statement execute function public.notify_team_booking_change();

-- Grants -----------------------------------------------------------------------
revoke all on function public.may_follow_team(uuid, uuid) from public, anon, authenticated;
revoke all on function public.alert_followers(uuid[], text, uuid) from public, anon, authenticated;
revoke all on function public.alert_everyone(text) from public, anon, authenticated;
revoke all on function public.push_to(text, text, uuid[]) from public, anon, authenticated;
revoke all on function public.slot_label(text, text, date, text) from public, anon, authenticated;
revoke all on function public.person_name(uuid) from public, anon, authenticated;
revoke all on function public.notify_priority_force() from public, anon, authenticated;
revoke all on function public.notify_team_booking_change() from public, anon, authenticated;
revoke all on function public.set_notification_teams(uuid[]) from public, anon;
grant execute on function public.set_notification_teams(uuid[]) to authenticated;

commit;
