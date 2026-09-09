-- Give people names.
--
-- profiles has never had one. The name in the header is derived from role, so
-- an admin shows as "Site Admin" and a coach as "Girls 6th Grade" — labels that
-- read like names and identify nobody. The bulk-invite template has been asking
-- directors for a Name column all along and discarding it on the way through.
--
-- Nullable on purpose: accounts created before this keep working and fall back
-- to the role label until someone fills them in.

alter table profiles add column if not exists first_name text;
alter table profiles add column if not exists last_name  text;

-- Directors and admins read the user list; everyone reads their own row. The
-- existing select policies already cover that, so nothing new is needed there.

-- Sorting a roster by surname is the one query this table will actually run.
create index if not exists profiles_last_name_idx on profiles (last_name);
