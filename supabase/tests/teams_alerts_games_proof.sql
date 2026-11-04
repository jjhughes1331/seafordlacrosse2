-- Proves the 2026-11-04 migrations against the LIVE database without keeping
-- any change: the block always ends by raising an exception, so Postgres
-- rolls back everything (teams, assignments, games, queued pushes).
-- Run AFTER teams_assignments / notification_settings / games. The result
-- is the error message.
do $$
declare
  c uuid; c_team uuid; c_gender text;
  d_same uuid; d_other uuid; other_gender text;
  green uuid; r text := ''; tmp text; n int; ids uuid[]; res jsonb;
  local_now timestamp := now() at time zone 'America/New_York';
begin
  select id, team_id, gender into c, c_team, c_gender from profiles where role = 'coach' limit 1;
  select id into d_same from profiles where role = 'director' and gender = c_gender limit 1;
  select id, gender into d_other, other_gender from profiles where role = 'director' and id is distinct from d_same limit 1;
  if c is null or d_same is null then raise exception 'Need a coach and a director of the same program'; end if;

  select count(*) into n from team_members where profile_id = c and team_id = c_team and role = 'head';
  r := 'backfill: coach is head of own team ' || (n = 1);

  -- As the head coach
  perform set_config('request.jwt.claims', json_build_object('sub', c, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  r := r || ' | COACH can book own team ' || can_book_team(c_team)
         || ', another team ' || can_book_team((select id from teams where id <> c_team limit 1));
  begin
    perform assign_team_member(c_team, c, 'assistant');
    r := r || ', assigns: ALLOWED';
  exception when others then r := r || ', assigns: ' || sqlerrm;
  end;
  begin
    perform create_team(c_gender, '2nd Grade', 'Green');
    r := r || ', adds team: ALLOWED';
  exception when others then r := r || ', adds team: ' || sqlerrm;
  end;
  execute 'reset role';

  -- As that program's director
  perform set_config('request.jwt.claims', json_build_object('sub', d_same, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  green := create_team(c_gender, '2nd Grade', 'Green');
  r := r || ' | DIRECTOR adds split team: ' || team_label(green);
  begin
    perform create_team(c_gender, '2nd Grade', 'green');
    r := r || ', same name again: ALLOWED';
  exception when others then r := r || ', same name again: ' || sqlerrm;
  end;
  if other_gender is not null then
    begin
      perform create_team(other_gender, '3rd Grade', 'Blue');
      r := r || ', other program team: ALLOWED';
    exception when others then r := r || ', other program team: ' || sqlerrm;
    end;
  end if;

  perform assign_team_member(green, c, 'assistant');
  execute 'reset role';
  select ' | coach as Green assistant: role ' || role || ', profile team still own ' || (team_id = c_team)
    into tmp from profiles where id = c;
  r := r || tmp;
  perform set_config('request.jwt.claims', json_build_object('sub', c, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  r := r || ', can book Green ' || can_book_team(green);
  execute 'reset role';

  perform set_config('request.jwt.claims', json_build_object('sub', d_same, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  perform assign_team_member(green, c, 'head');
  if d_other is not null then
    res := assign_team_member(c_team, d_other, 'head');
    r := r || ' | other director made head of coach''s team, replaced coach: ' || ((res->>'replaced')::uuid = c);
  end if;
  execute 'reset role';

  select count(*) into n from team_members where profile_id = c;
  r := r || ' | coach now on ' || n || ' team(s), profile team = Green ' || ((select team_id from profiles where id = c) = green);
  perform set_config('request.jwt.claims', json_build_object('sub', c, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  r := r || ', can book Green ' || can_book_team(green) || ', old team ' || can_book_team(c_team);
  execute 'reset role';
  if d_other is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', d_other, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
    r := r || ', other director can book it ' || can_book_team(c_team);
    execute 'reset role';
  end if;

  -- Three assistants max
  begin
    insert into team_members (team_id, profile_id, role)
    select green, id, 'assistant' from profiles where id <> c and role <> 'admin' limit 4;
    r := r || ' | 4 assistants: ALLOWED (or fewer than 4 people to try)';
  exception when others then r := r || ' | 4 assistants: ' || sqlerrm;
  end;

  -- Alerts
  ids := alert_followers(array[green], 'booking_turn');
  r := r || ' | turn-to-book for Green reaches coach ' || (c = any (ids)) || ', director ' || (d_same = any (ids));
  ids := alert_followers(array[green], 'team_bookings');
  r := r || '; bookings alert (default off) reaches coach ' || (c = any (ids));
  insert into notification_prefs (profile_id, team_bookings, booking_turn) values (c, true, false);
  ids := alert_followers(array[green], 'team_bookings');
  r := r || ', after switching on ' || (c = any (ids));
  r := r || ', turn-to-book after switching off ' || (c = any (alert_followers(array[green], 'booking_turn')));
  perform set_config('request.jwt.claims', json_build_object('sub', c, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  ids := set_notification_teams(array[green, c_team]);
  execute 'reset role';
  r := r || '; coach picks Green + old team, saved ' || cardinality(ids);

  -- Games: a coach can't upload; the director can.
  begin
    perform import_games(2099, '[]'::jsonb);
    r := r || ' | COACH uploads schedule: ALLOWED';
  exception when others then r := r || ' | COACH uploads schedule: ' || sqlerrm;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', d_same, 'role', 'authenticated')::text, true);
  res := import_games(2099, jsonb_build_array(
    jsonb_build_object('game_number', 1, 'date', local_now::date, 'time', to_char(local_now + interval '115 minutes', 'HH24:MI'),
                       'field', 'SHS', 'town', 'Seaford', 'home', 'Seaford 2 Green', 'away', 'Visitors 2',
                       'gender', c_gender, 'grade', '2nd Grade'),
    jsonb_build_object('game_number', 1, 'date', local_now::date, 'time', '23:59',
                       'field', 'SHS', 'town', 'Seaford', 'home', 'Seaford 9', 'away', 'Visitors 9',
                       'gender', c_gender, 'grade', '6th'),
    jsonb_build_object('game_number', 2, 'date', local_now::date, 'time', '10:00',
                       'field', 'Cedar Creek ', 'town', 'Seaford', 'home', 'Seaford 2 Green', 'away', 'Visitors 3',
                       'gender', c_gender, 'grade', '2nd Grade'),
    jsonb_build_object('game_number', 3, 'date', local_now::date, 'time', '10:00',
                       'town', 'Elsewhere', 'home', 'Elsewhere 2', 'away', 'Seaford 2 Green',
                       'gender', c_gender, 'grade', '2nd'),
    jsonb_build_object('game_number', 4, 'date', local_now::date, 'home', 'N/A', 'away', 'BYE',
                       'gender', c_gender, 'grade', '2nd')));
  r := r || ' | IMPORT ' || res::text;
  select count(*) into n from games where season = 2099 and seaford_team_id = green;
  r := r || ', matched to Green: ' || n;
  select string_agg(site || ' ' || duty || '=' || coalesce(team_label(team_id), 'unmatched'), ', ' order by site, duty)
    into tmp from game_duties where season = 2099;
  r := r || ' | DUTIES ' || coalesce(tmp, 'none');
  r := r || ' | reminders sent now: ' || send_duty_reminders() || ', again: ' || send_duty_reminders();

  raise exception 'PROOF (rolled back): %', r;
end $$;
