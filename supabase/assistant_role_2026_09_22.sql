-- Assistant coaches (JJ, 2026-09-22): view-only members of one team.
--
-- They read what a coach reads: every members_read policy is "has a profile".
-- Every write policy (bookings insert/delete, waitlist insert/delete, teams
-- update, app_settings update) names the roles that may write - admin,
-- director, coach - and profiles has no write policy at all, so an assistant
-- is refused by the database itself, not just by a hidden button.
--
-- Accounts still come only from invite-coach (public sign-up stays OFF):
-- a head coach may add up to 3 for their own team, a director for their
-- gender, an admin anywhere. manage-user removes a head coach's assistants
-- along with the head coach.

begin;

alter table public.profiles drop constraint profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role = any (array['admin'::text, 'director'::text, 'coach'::text, 'assistant'::text]));

-- Who added them, so removing a head coach can take their assistants too.
alter table public.profiles
  add column if not exists invited_by uuid references auth.users(id) on delete set null;

-- Same shape as current_user_role()/current_user_gender(): SECURITY DEFINER so
-- a profiles policy can read the caller's own team without recursing into
-- itself, pinned search_path, callable by signed-in users only.
create or replace function public.current_user_team()
returns uuid
language sql stable security definer
set search_path = public
as $$
  select team_id from public.profiles where id = auth.uid()
$$;
revoke all on function public.current_user_team() from public, anon;
grant execute on function public.current_user_team() to authenticated, service_role;

-- A head coach sees their own team's assistants (My Team > Assistant coaches).
-- Nothing else about who can see profiles changes.
alter policy profiles_select_combined on public.profiles using (
  (id = (select auth.uid()))
  or (current_user_role() = 'admin'::text)
  or ((current_user_role() = 'director'::text) and (current_user_gender() = gender))
  or ((current_user_role() = 'coach'::text) and (role = 'assistant'::text) and (team_id = current_user_team()))
);

commit;

-- ---------------------------------------------------------------------------
-- Part 2 (same day): make "can't write" airtight, and tell the directors.
-- ---------------------------------------------------------------------------
begin;

-- Cancel/leave-waitlist also allowed "rows you made yourself". An assistant
-- can never make one, but a rule that depends on that is one role change away
-- from a hole, so both now require a booking role outright.
alter policy bookings_delete_scoped on public.bookings using (
  (current_user_role() = any (array['admin'::text, 'director'::text, 'coach'::text]))
  and (not (select app_settings.schedule_locked from app_settings limit 1))
  and (
    (booked_by = (select auth.uid()))
    or exists (select 1 from profiles p where p.id = (select auth.uid()) and p.role = 'admin')
    or exists (select 1 from profiles p where p.id = (select auth.uid()) and p.role = 'coach' and p.team_id = bookings.team_id)
    or exists (select 1 from profiles p join teams t on t.id = bookings.team_id
               where p.id = (select auth.uid()) and p.role = 'director' and p.gender = t.gender)
  )
);
alter policy waitlist_delete_scoped on public.waitlist using (
  (current_user_role() = any (array['admin'::text, 'director'::text, 'coach'::text]))
  and (
    (requested_by = (select auth.uid()))
    or exists (select 1 from profiles p where p.id = (select auth.uid()) and p.role = 'admin')
    or exists (select 1 from profiles p where p.id = (select auth.uid()) and p.role = 'coach' and p.team_id = waitlist.team_id)
    or exists (select 1 from profiles p join teams t on t.id = waitlist.team_id
               where p.id = (select auth.uid()) and p.role = 'director' and p.gender = t.gender)
  )
);

-- A new assistant is logged for the directors (Admin > Activity) and pushed
-- to that gender's directors, except whoever added them. A trigger, like the
-- rest of activity_log, so it can't be skipped by a client.
create or replace function public.notify_assistant_added()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  v_by text;
  v_team text;
  v_directors uuid[];
  v_secret text;
begin
  select coalesce(nullif(trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), ''), email)
    into v_by from profiles where id = new.invited_by;
  select (case when gender = 'girls' then 'Girls ' else 'Boys ' end) || grade
    into v_team from teams where id = new.team_id;

  insert into activity_log (actor_id, actor_email, action, team_id, gender, detail)
  values (new.invited_by, coalesce((select email from profiles where id = new.invited_by), 'system'),
          'added assistant', new.team_id, new.gender, new.email);

  select array_agg(id) into v_directors from profiles
   where role = 'director' and gender = new.gender and id is distinct from new.invited_by;
  if v_directors is not null then
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'push_trigger_secret';
    if v_secret is not null then
      perform net.http_post(
        url := 'https://gjpqwmcdejpvffdimddk.supabase.co/functions/v1/send-push',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
        body := jsonb_build_object(
          'title', 'New assistant coach',
          'message', coalesce(v_by, 'A coach') || ' added ' || new.email || ' to ' || coalesce(v_team, 'a team') || '.',
          'externalIds', to_jsonb(v_directors)
        )
      );
    end if;
  end if;
  return null;
end;
$$;
revoke all on function public.notify_assistant_added() from public, anon, authenticated;

drop trigger if exists profiles_assistant_added on public.profiles;
create trigger profiles_assistant_added
  after insert on public.profiles
  for each row when (new.role = 'assistant')
  execute function public.notify_assistant_added();

commit;
