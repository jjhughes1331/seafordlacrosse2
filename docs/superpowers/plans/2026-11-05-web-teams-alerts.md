# Website catch-up: split teams, assignments, alerts, league upload

JJ approved 2026-11-05 ("You have my ok"). The database side is live
(`supabase/teams_assignments_2026_11_04.sql`,
`notification_settings_2026_11_04.sql`, `games_2026_11_04.sql`). The native
app (../seaford-lax-app, branch `native`) already does all of this; its
behaviour is the spec: `../seaford-lax-app/docs/superpowers/specs/2026-11-04-teams-alerts-games-design.md`.
invite-coach was changed and deployed first (39d8143): only admins and
directors invite.

Branch `teams-web` (from `field-catalog`). Deploy = merge to `main` and push
(GitHub Pages), after the final review.

## Global constraints

- Everything in `CLAUDE.md` holds: no framework, no build step, SF type,
  green = interactive, gold = mine, one `confirmAction()` model, 44pt
  targets, no em dashes in UI text, tab bar shape/order/labels unchanged.
- The database enforces the rules; the UI only reflects them. Show the
  database's own refusal text when an RPC fails.
- `?fixture=1` must keep working with zero network calls: every new table and
  RPC gets a fixture stand-in with the same rules (one head per team, max 3
  assistants, delete only with no bookings).
- Labels: "Girls 2nd Grade Green" (gender + grade + split name). Use
  `team_label` semantics everywhere a team is named.
- Copy matches the native app's wording where the native app has it.

## Tasks (in order, each its own commit)

1. **Teams and memberships.** Load `team_members` (and realtime). Team label
   with the split name everywhere. A person's teams = their memberships.
   Book: bookable teams = teams they head (directors/admins unchanged); 2+
   head teams get the team picker, remembered. My Team: a switcher when on
   2+ teams ("Girls 5th Grade · Head Coach" / "Boys 3rd Grade · Assistant"),
   remembered per device. The head coach's Add Assistant control is removed;
   a read-only Coaches section lists head and assistants by name with
   "Your director assigns coaches." Fixture: a split 2nd grade, a coach who
   heads one team and assists another, an assistant-only person.
   Native reference: `AppStore+Members.swift`, `MyTeamView.swift`,
   `CoachesSection.swift`.
2. **Admin > Teams.** Teams grouped by program then grade, head coach name or
   "No head coach". Add Team (program fixed for directors, grade, optional
   name: "Name it to split a grade, like Green or White."). Team detail: head
   coach picker (directors, coaches, assistants; searchable; confirm "Replace
   Pat as head coach?"), assistants up to 3 add/remove, Name and League Name,
   Remove Team (database refusal text shown). RPCs: `create_team`,
   `rename_team`, `delete_team`, `assign_team_member`,
   `unassign_team_member`. Invite form: head coaches no longer see it (they
   can't invite); team menus show split teams.
   Native reference: `TeamsView.swift`, `TeamDetailView.swift`, `TeamTools.swift`.
3. **Notification settings.** In the account sheet for everyone signed in:
   five switches with one-line explanations (Slot Opened, Schedule Locked,
   Your Turn to Book, Bookings on My Teams, Field Setup & Breakdown) stored in
   `notification_prefs`; Teams: "My assigned teams" (directors: "and all
   Girls teams") or Choose Teams, saved with `set_notification_teams`.
   Native reference: `NotificationSettingsView.swift`, SeafordKit prefs model.
4. **League schedule upload (Admin).** Last upload line. Upload .xlsx, parse
   in the browser with no third-party code (zip central directory +
   `DecompressionStream('deflate-raw')`, shared strings, sheet XML via
   DOMParser), port of `LeagueSheet.swift` incl. its edge cases. Preview
   before saving (games by program, home games, unmatched Seaford names, odd
   times before 7 AM / after 8 PM, byes skipped), then `import_games(season,
   rows)`. Check against the two 2026 workbooks in the native test bundle
   (88 games, 41 at home).

Not in this plan: a Games tab on the website (the tab bar is JJ's; ask
first), the 2.1 setup/breakdown checklist.

## Verification

Each task: `?fixture=1` as admin, director, coach (two teams) and assistant
at phone width, both themes; `tools/render-audit.js` and
`tools/pixel-audit.js` clean for the touched screens; no console errors.
Final: one whole-branch review, then merge and push to `main`, then a
cache-busted fetch of seafordlax.com confirming the new strings.
