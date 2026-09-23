-- Proves an assistant can read but never write, against the LIVE database,
-- without keeping any change: the block always ends by raising an exception,
-- so Postgres rolls back everything it did (including the role swaps).
-- Paste into the SQL editor and Run; the result is the error message.
--
-- Result 2026-09-22:
--   CONTROL coach books: allowed | ASSISTANT reads teams: 14, bookings: 1,
--   profiles visible: 1 | books a slot: new row violates row-level security
--   policy for table "bookings" | joins waitlist: new row violates row-level
--   security policy for table "waitlist" | cancels (incl. one they booked as
--   coach): 0 | teams updated: 0 | profiles updated: 0 | settings updated: 0 |
--   HEAD COACH sees own assistants: 1, profiles visible: 2
--
-- The slot must be on field_slots (Cedar Creek 1/2 Field, Tue/Thu 4:30-5:30).
do $$
declare
  coach_id uuid; coach_team uuid; coach_gender text; dir_id uuid;
  r text := ''; n int;
begin
  select id, team_id, gender into coach_id, coach_team, coach_gender from profiles where role = 'coach' limit 1;
  select id into dir_id from profiles where role = 'director' and gender = coach_gender limit 1;

  -- Control: a real head coach books Cedar Creek, Tue 2 Mar 2027, 4:30-5:30.
  perform set_config('request.jwt.claims', json_build_object('sub', coach_id, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    insert into bookings (field_id, date, subfield, time, team_id, booked_by)
      values ('cedarcreek', '2027-03-02', '1/2 Field', '4:30-5:30 PM', coach_team, coach_id);
    r := r || 'CONTROL coach books: allowed';
  exception when others then r := r || 'CONTROL coach books: ' || sqlerrm;
  end;
  execute 'reset role';

  update profiles set role = 'assistant' where id = coach_id;
  execute 'set local role authenticated';
  select count(*) into n from teams; r := r || ' | ASSISTANT reads teams: ' || n;
  select count(*) into n from bookings; r := r || ', bookings: ' || n;
  select count(*) into n from profiles; r := r || ', profiles visible: ' || n;
  begin
    insert into bookings (field_id, date, subfield, time, team_id, booked_by)
      values ('cedarcreek', '2027-03-04', '1/2 Field', '4:30-5:30 PM', coach_team, coach_id);
    r := r || ' | books a slot: ALLOWED';
  exception when others then r := r || ' | books a slot: ' || sqlerrm;
  end;
  begin
    insert into waitlist (field_id, date, subfield, time, team_id, requested_by)
      values ('cedarcreek', '2027-03-02', '1/2 Field', '4:30-5:30 PM', coach_team, coach_id);
    r := r || ' | joins waitlist: ALLOWED';
  exception when others then r := r || ' | joins waitlist: ' || sqlerrm;
  end;
  delete from bookings; get diagnostics n = row_count; r := r || ' | cancels (incl. one they booked as coach): ' || n;
  update teams set priority_finished_at = now(); get diagnostics n = row_count; r := r || ' | teams updated: ' || n;
  update profiles set role = 'coach'; get diagnostics n = row_count; r := r || ' | profiles updated: ' || n;
  update app_settings set schedule_locked = true; get diagnostics n = row_count; r := r || ' | settings updated: ' || n;
  execute 'reset role';

  if dir_id is not null then
    update profiles set role = 'coach', team_id = coach_team where id = dir_id;
    perform set_config('request.jwt.claims', json_build_object('sub', dir_id, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    select count(*) into n from profiles where role = 'assistant'; r := r || ' | HEAD COACH sees own assistants: ' || n;
    select count(*) into n from profiles; r := r || ', profiles visible: ' || n;
    execute 'reset role';
  end if;

  raise exception 'ROLLED BACK. %', r;
end $$;
