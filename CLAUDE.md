# seafordlacrosse2 — seafordlax.com

Field-booking site for Seaford Lacrosse. **Coaches and directors only — not
parents.** One static file, no build step, no framework.

> Not to be confused with JJ's *other* lacrosse project (Igloo / Snow Leopard —
> Next.js on Netlify, Geist + Anton). Memory entries mentioning Netlify,
> `components/icons.tsx` or `--stage-*` tokens are that project, not this one.

## Structure
- `index.html` — the entire site: markup, styles and script in one file (~5,200 lines)
- `sw.js`, `manifest.json` — PWA. The SW is **network-first** and skips Supabase, so it never serves stale data
- `supabase/*.sql` — reference copies of applied schema/policy work
- `supabase/functions/manage-user.ts` — reference copy; `invite-coach` and `send-push` live only in the dashboard
- `tools/render-audit.js` — see Verifying below
- `MOBILE_APP_HANDOFF.md` — Capacitor shell backend contract

## Deploy
Push to `main` → GitHub Pages. **`cache-control: max-age=600`**, so a change can
look "not deployed" for up to 10 minutes. Confirm with a cache-busted fetch
before concluding anything is broken:

```bash
curl -s "https://seafordlax.com/?v=$RANDOM" | grep -c "some-new-string"
```

## Backend
Supabase project `gjpqwmcdejpvffdimddk`. Tables: `bookings`, `teams`,
`profiles`, `waitlist`, `app_settings`. The **Supabase MCP tool points at a
different project** — drive the dashboard in the browser instead.

**The database is the enforcement layer, not the UI.** Verified live:
- The priority ladder is enforced in Postgres and blocks *admins* too (`42501`)
- `field_slots` is an allowlist; a slot that isn't in it is rejected by trigger
- `bookings.booked_by → auth.users` is **ON DELETE NO ACTION**. Removing a coach
  reassigns their bookings to the remover (in `manage-user`). Never make this
  CASCADE — it would silently erase a team's season
- RLS pins `booked_by` to `auth.uid()` on insert *and* update, so you cannot
  create or move a booking on someone else's behalf

## Domain rules that surprise people
- **The priority ladder is combined across genders.** Girls 6th finishing does
  not unlock 5th until Boys 6th finishes too. Working as designed
- A tier's deadline is *derived*, not stored: it opened when the tier above
  finished (`max(priority_finished_at)`). 3 days, then an admin's session
  auto-advances via `priority_forced_ranks`
- Changing a field's hours in `FIELDS` also requires updating `field_slots`, or
  new bookings get rejected

## Design system (decided, don't relitigate)
- **One typeface: Manrope.** Hierarchy from weight and size
- **Icons are custom and solid.** No Lucide, no stroked icons — mixing the two
  vocabularies was a real bug that shipped twice
- **Editorial palette**: green is an accent (~25 call sites), not the default
  text colour. `--hover-edge` is neutral. Gold `--mine` means *your team* and
  nothing else. Red `--danger` means error or destructive, never "busy"
- **44px minimum** tap target. Small controls get a `::before` overlay
- **One confirmation model**: `confirmAction()` sheet for anything destructive.
  `armTwoTap` survives only on booking a slot, which has Undo

## Verifying — do this instead of grepping
Three separate times a source grep said "clean" and the running page disagreed:
an emoji written as `&#128075;`, thirteen stroked icons, and a table that only
overflowed once a real long email was in it. **Source is what we wrote;
rendered output is what a coach sees.**

- `?fixture=1` boots the whole signed-in app against in-memory data with a mock
  Supabase client and **zero network calls**. Use it to reach any signed-in
  surface without a login or real data
- `tools/render-audit.js` — paste into the console on `?fixture=1`. Checks
  emoji in rendered text, mixed icon vocabularies, tap targets, overflow, em
  dashes, gradients, fonts
- Only JJ can sign in (I don't enter credentials). For anything needing a real
  session, ask — and test destructive paths by opening the confirm sheet and
  *dismissing* it unless the data is disposable

## Gotchas that cost real time
- Chain edit scripts to their commit with `&&`. A commit once shipped with a
  message describing work whose edit script had already failed
- `const` declared later in the file is in the TDZ — even `typeof` throws, and
  in one script that killed the whole app
- The Browser pane catches GSAP mid-transition; a "blank" screenshot is usually
  a fade, not a bug. Prefer DOM/computed-style reads over screenshots
- Edge Functions: never nest template literals in the source you inject. Build
  it as an array of single-quoted strings, or fetch the raw file from GitHub
