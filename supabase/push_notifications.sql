-- Push notification triggers — run once in the Supabase SQL editor.
-- Fires on 3 events, each posting to the send-push Edge Function (which
-- holds the real OneSignal REST API key — never referenced here):
--   1. A booking is deleted and someone was waiting for that exact slot.
--   2. Admin locks/unlocks the schedule (broadcast to every subscriber).
--   3. A grade tier finishes priority booking, unlocking the next tier down
--      (notify just the coaches/directors of the newly-unlocked teams).
--
-- The Edge Function requires a shared secret header (x-push-secret) since
-- trigger calls have no user session to verify. That secret is stored in
-- Supabase Vault (not inlined in trigger source) and looked up per-call.

create extension if not exists pg_net with schema extensions;
create extension if not exists supabase_vault;

-- Run this separately, by hand, with YOUR_SECRET_HERE replaced by the same
-- value saved as the PUSH_TRIGGER_SECRET Edge Function secret. Deliberately
-- not run automatically by this file and not committed with a real value —
-- it's the one statement in this migration that contains actual secret
-- material.
--
-- delete from vault.secrets where name = 'push_trigger_secret';
-- select vault.create_secret('YOUR_SECRET_HERE', 'push_trigger_secret');

-- ============ 1. Waitlist slot opens up ============
create or replace function public.notify_waitlist_on_slot_open()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  secret text;
  target_ids uuid[];
begin
  select array_agg(distinct requested_by) into target_ids
  from waitlist
  where field_id = old.field_id and date = old.date and subfield = old.subfield and time = old.time;

  if target_ids is not null and array_length(target_ids, 1) > 0 then
    select decrypted_secret into secret from vault.decrypted_secrets where name = 'push_trigger_secret';
    if secret is not null then
      perform net.http_post(
        url := 'https://gjpqwmcdejpvffdimddk.supabase.co/functions/v1/send-push',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', secret),
        body := jsonb_build_object(
          'title', 'A slot opened up!',
          'message', old.subfield || ' at ' || old.time || ' on ' || old.date || ' is now open.',
          'externalIds', to_jsonb(target_ids)
        )
      );
    end if;
  end if;
  return old;
end;
$$;

drop trigger if exists trg_notify_waitlist_on_slot_open on bookings;
create trigger trg_notify_waitlist_on_slot_open
  after delete on bookings
  for each row execute function notify_waitlist_on_slot_open();

-- ============ 2. Schedule locked/unlocked ============
create or replace function public.notify_schedule_lock_change()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  secret text;
begin
  if new.schedule_locked is distinct from old.schedule_locked then
    select decrypted_secret into secret from vault.decrypted_secrets where name = 'push_trigger_secret';
    if secret is not null then
      perform net.http_post(
        url := 'https://gjpqwmcdejpvffdimddk.supabase.co/functions/v1/send-push',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', secret),
        body := jsonb_build_object(
          'title', case when new.schedule_locked then 'Schedule locked' else 'Schedule unlocked' end,
          'message', case when new.schedule_locked
            then 'Booking is temporarily paused by an admin.'
            else 'Booking is open again.' end,
          'broadcast', true
        )
      );
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_schedule_lock_change on app_settings;
create trigger trg_notify_schedule_lock_change
  after update on app_settings
  for each row execute function notify_schedule_lock_change();

-- ============ 3. Priority booking tier unlocks ============
create or replace function public.notify_priority_tier_unlock()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  secret text;
  finished_rank int;
  tier_fully_done boolean;
  target_team_ids uuid[];
  target_user_ids uuid[];
begin
  if new.priority_finished_at is not null and old.priority_finished_at is null then
    finished_rank := grade_rank(new.grade);

    select not exists (
      select 1 from teams t where grade_rank(t.grade) = finished_rank and t.priority_finished_at is null
    ) into tier_fully_done;

    if tier_fully_done and finished_rank > 0 then
      select array_agg(id) into target_team_ids from teams where grade_rank(grade) = finished_rank - 1;

      if target_team_ids is not null then
        select array_agg(distinct p.id) into target_user_ids
        from profiles p
        where (p.role = 'coach' and p.team_id = any(target_team_ids))
           or (p.role = 'director' and exists (
                 select 1 from teams t where t.id = any(target_team_ids) and t.gender = p.gender
               ));

        if target_user_ids is not null and array_length(target_user_ids, 1) > 0 then
          select decrypted_secret into secret from vault.decrypted_secrets where name = 'push_trigger_secret';
          if secret is not null then
            perform net.http_post(
              url := 'https://gjpqwmcdejpvffdimddk.supabase.co/functions/v1/send-push',
              headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', secret),
              body := jsonb_build_object(
                'title', 'Booking is open for your team!',
                'message', 'The next grade tier just unlocked — you can now book field time.',
                'externalIds', to_jsonb(target_user_ids)
              )
            );
          end if;
        end if;
      end if;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_priority_tier_unlock on teams;
create trigger trg_notify_priority_tier_unlock
  after update on teams
  for each row execute function notify_priority_tier_unlock();
