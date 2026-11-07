-- Admins can coach a team too (JJ, 2026-11-06: "I'm the admin but I'm also a coach").
--
-- assign_team_member() refused any admin ("Admins aren't assigned to teams").
-- This drops only that check; everything else in the function is unchanged.
-- Being on a team never changes an admin's role: sync_role_from_memberships()
-- already returns early for admins and directors. can_book_team(),
-- may_follow_team() and the alerts already treat admins as able to book and
-- follow any team, so nothing else needs to change.
--
-- The edit is made on the live function text, and it fails loudly if the
-- check isn't there exactly as written in teams_assignments_2026_11_04.sql.

do $$
declare
  v_def text;
  v_check constant text := E'  if v_target_role = ''admin'' then\n    raise exception ''Admins aren''''t assigned to teams'' using errcode = ''22023'';\n  end if;\n';
begin
  select pg_get_functiondef('public.assign_team_member(uuid, uuid, text)'::regprocedure) into v_def;
  if position(v_check in v_def) = 0 then
    raise exception 'assign_team_member: the admin check was not found as expected; nothing changed';
  end if;
  execute replace(v_def, v_check, '');
end $$;

-- Check: should be false.
select position('Admins aren''t assigned' in pg_get_functiondef('public.assign_team_member(uuid, uuid, text)'::regprocedure)) > 0
  as admin_check_still_there;
