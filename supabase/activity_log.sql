-- Activity log: what coaches actually did, for directors and admins.
--
-- Written by TRIGGERS, not by the app. A coach controls their own browser, so
-- client-side logging can be skipped, replayed or forged, and it silently
-- misses anything done outside the app. A trigger sees every write, including
-- ones made from the SQL editor.

create table if not exists activity_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  -- ON DELETE SET NULL, not NO ACTION: removing a coach must never fail because
  -- of the log, and must never erase the history of what they did. That is the
  -- same trap bookings.booked_by set, which is why actor_email is denormalised
  -- here — the entry still reads sensibly after the account is gone.
  actor_id    uuid references auth.users(id) on delete set null,
  actor_email text,
  action      text not null,
  team_id     uuid references teams(id) on delete set null,
  gender      text,
  detail      text
);

create index if not exists activity_log_at_idx     on activity_log (at desc);
create index if not exists activity_log_gender_idx on activity_log (gender, at desc);

alter table activity_log enable row level security;

-- Admins see everything; a director sees their own gender; a coach sees only
-- what they themselves did. Nobody writes directly — only the triggers below,
-- which run as security definer.
drop policy if exists activity_log_select on activity_log;
create policy activity_log_select on activity_log for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin')
  or exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'director' and p.gender = activity_log.gender)
  or actor_id = auth.uid()
);

create or replace function log_activity(
  p_action text, p_team_id uuid, p_detail text
) returns void language plpgsql security definer as $$
declare
  v_actor uuid := auth.uid();
  v_email text;
  v_gender text;
begin
  select email into v_email from profiles where id = v_actor;
  select gender into v_gender from teams where id = p_team_id;
  insert into activity_log (actor_id, actor_email, action, team_id, gender, detail)
  values (v_actor, coalesce(v_email, 'system'), p_action, p_team_id, v_gender, p_detail);
end $$;

create or replace function log_booking_change() returns trigger
language plpgsql security definer as $$
begin
  if (TG_OP = 'INSERT') then
    perform log_activity('booked', NEW.team_id,
      NEW.time || ' on ' || to_char(NEW.date::date, 'Mon DD') || ' at ' || NEW.field_id ||
      case when NEW.subfield is null then '' else ' (' || NEW.subfield || ')' end);
    return NEW;
  else
    perform log_activity('cancelled', OLD.team_id,
      OLD.time || ' on ' || to_char(OLD.date::date, 'Mon DD') || ' at ' || OLD.field_id ||
      case when OLD.subfield is null then '' else ' (' || OLD.subfield || ')' end);
    return OLD;
  end if;
end $$;

drop trigger if exists bookings_log_activity on bookings;
create trigger bookings_log_activity
  after insert or delete on bookings
  for each row execute function log_booking_change();

create or replace function log_waitlist_change() returns trigger
language plpgsql security definer as $$
begin
  if (TG_OP = 'INSERT') then
    perform log_activity('joined waitlist', NEW.team_id,
      NEW.time || ' on ' || to_char(NEW.date::date, 'Mon DD') || ' at ' || NEW.field_id);
    return NEW;
  else
    perform log_activity('left waitlist', OLD.team_id,
      OLD.time || ' on ' || to_char(OLD.date::date, 'Mon DD') || ' at ' || OLD.field_id);
    return OLD;
  end if;
end $$;

drop trigger if exists waitlist_log_activity on waitlist;
create trigger waitlist_log_activity
  after insert or delete on waitlist
  for each row execute function log_waitlist_change();

-- A team marking itself finished releases the next grade, so it belongs here.
create or replace function log_team_finished() returns trigger
language plpgsql security definer as $$
begin
  if (NEW.priority_finished_at is distinct from OLD.priority_finished_at) then
    perform log_activity(
      case when NEW.priority_finished_at is null then 'reopened booking' else 'marked finished' end,
      NEW.id, null);
  end if;
  return NEW;
end $$;

drop trigger if exists teams_log_finished on teams;
create trigger teams_log_finished
  after update on teams
  for each row execute function log_team_finished();
