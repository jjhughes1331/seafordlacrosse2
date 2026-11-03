-- Proves the field catalog is in place and private, against the LIVE
-- database, without keeping any change: the block always ends by raising an
-- exception, so Postgres rolls back everything it did (including the role
-- swap). Paste into the SQL editor and Run; the result is the error message.
--
-- Expected: fields 5; slots cedarcreek 3, harbor 30, seafordhs 14, sms 14,
-- seamans 19; season 2027-03-01..2027-06-30; anon reads fields 0.
--
-- Result 2026-11-03:
--   fields: 5 | slots: cedarcreek 3 harbor 30 seafordhs 14 sms 14 seamans 19 |
--   season: 2027-03-01..2027-06-30 | anon reads fields: 0
do $$
declare
  r text := ''; n int; s record;
begin
  select count(*) into n from fields;
  r := 'fields: ' || n || ' | slots:';
  for s in select f.id, count(fs.*) c from fields f left join field_slots fs on fs.field_id = f.id group by f.id, f.sort order by f.sort loop
    r := r || ' ' || s.id || ' ' || s.c;
  end loop;
  select r || ' | season: ' || season_start || '..' || season_end into r from app_settings where id = true;
  set local role anon;
  begin
    select count(*) into n from fields;
  exception when insufficient_privilege then n := 0;
  end;
  reset role;
  r := r || ' | anon reads fields: ' || n;
  raise exception '%', r;
end $$;
