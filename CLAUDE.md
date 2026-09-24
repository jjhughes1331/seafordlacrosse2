# seafordlacrosse2 — seafordlax.com

Field-booking site for Seaford Lacrosse. **Coaches and directors only — not
parents.** Static site, no build step, no framework: `index.html` plus a few
component modules in `ui/`.

> Not to be confused with JJ's *other* lacrosse project (Igloo / Snow Leopard —
> Next.js on Netlify, Geist + Anton). Memory entries mentioning Netlify,
> `components/icons.tsx` or `--stage-*` tokens are that project, not this one.

## Keeping this file true
This file loads in full at the start of every session here, so it is both the
cheapest place to put knowledge and a file that costs tokens forever. Both
halves of that matter.

**Update it in the same commit as the change** — not afterwards, not "later".
A stale CLAUDE.md is worse than none, because it is trusted.

Write a line here when a change would otherwise have to be *rediscovered*:
- a decision a future session might reasonably reverse without knowing why
- something the database or a third party enforces that the code doesn't show
- a gotcha that cost more than a few minutes to diagnose
- a domain rule that surprised someone

Do **not** write a line for: what a file already says plainly, anything `git
log` answers, routine fixes, or work in progress. If it is not worth re-reading
in six months, it is not worth loading in every session.

**Delete as readily as you add.** When a section stops being true, cut it in the
same commit that made it untrue. Superseded decisions go entirely — leaving
"we used to do X" invites someone to weigh a dead option. If a section has
grown past a screen, it wants its own file with one line pointing to it here.

## Structure
- `index.html` — markup, styles and app script (~6,500 lines)
- `ui/*.js` — design v2 components, each self-contained and wired by event
  delegation so load order never matters: `spring.js` (interruptible spring
  solver), `field-menu.js` (field switcher), `aurora.js` (WebGL hero surface),
  `ripple.js` (booking-landed moment), `sheet.js` (drag-to-dismiss and an
  inert page for every `.share-modal`). **`docs/DESIGN.md` is the design
  source of truth** — principles, tokens, components, log; v3 rules at its end
- `vendor/` — supabase-js, GSAP, Flip, **pinned and served from here, not a
  CDN**: the app bundles this page and must draw with no network. To upgrade,
  replace the file and update the `<script>` tag and `sw.js` SHELL_FILES
  (`sync-web.sh` in the app repo copies `vendor/`)
- `sw.js`, `manifest.json` — PWA. The SW is **network-first** and skips Supabase, so it never serves stale data
- `supabase/*.sql` — reference copies of applied schema/policy work
- `supabase/functions/*.ts` — reference copies of `manage-user` and `invite-coach` (`send-push` and `team-ics` are read-only in the dashboard; both reviewed 2026-09-18)
- `tools/render-audit.js`, `tools/pixel-audit.js` — see Verifying below
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
- Reads require a `profiles` row, not just a session (`harden_2026_09_18.sql`);
  `anon` has no table grants and `log_activity()` is not API-callable
- **Public sign-up must stay OFF** (Auth → Sign In / Providers). Accounts come
  only from `invite-coach` via the admin API
- **Roles:** admin, director, coach (a *head* coach, who books), assistant
  (JJ, 2026-09-22: view-only, one team). Every write policy names the roles
  that may write, so assistants are refused by RLS, not by hidden buttons.
  A head coach invites up to 3 assistants to their own team, by email only,
  and may remove them; removing a head coach removes the assistants they
  invited (`profiles.invited_by`). Proof that runs against live and keeps
  nothing: `supabase/tests/assistant_rls_proof.sql`
- `manage-user`'s delete-me and set-name-on-yourself are open to **every**
  role. Its director/admin gate once ran first, so coaches couldn't delete
  their account (an App Store requirement) or save their name

## Domain rules that surprise people
- **The priority ladder is combined across genders.** Girls 6th finishing does
  not unlock 5th until Boys 6th finishes too. Working as designed
- A tier's deadline is *derived*, not stored: it opened when the tier above
  finished (`max(priority_finished_at)`). 3 days, then an admin's session
  auto-advances via `priority_forced_ranks`
- Changing a field's hours in `FIELDS` also requires updating `field_slots`, or
  new bookings get rejected

## iOS app (App Store)
The Capacitor shell lives in `../seaford-lax-app` (branch `app-store`). It
**bundles this site into the binary** — Apple rejects apps that only load a
website — so a web change reaches the app only after `./sync-web.sh && npx cap
sync ios` and a new build. The web keeps deploying instantly as always.
- App Apple ID 6814956251, bundle `com.seafordlax.app`, team 66YQ74WLDA
- `tools/asc.py` there pushes listing text, screenshots and review details
  through Apple's API. App Privacy answers have **no API** — website only
- `window.__IS_NATIVE_APP` gates native behaviour in this file: Taptic haptics,
  the iOS share sheet, native OneSignal (the web SDK is not loaded there), the
  system browser for external links, no service worker, no install nudge
- Account deletion is an App Store requirement: account sheet (the monogram,
  top right) > Delete Account, `manage-user` action `delete-me`
- The app's pull-to-refresh is a native `UIRefreshControl`
  (`MainViewController`) that awaits `window.appRefresh()`; the JS pull is
  Safari-only. The app also sets `html.lpm` (Low Power Mode); `html.kb` is
  set while the keyboard is up
- Native launch: `MainViewController` (set in **SceneDelegate**, not the
  storyboard, which Capacitor 8 ignores) lays a Metal scene
  (`LaunchShader.swift`) over the web view. Its clock starts in
  `viewDidAppear`, or the opening strokes play during iOS's icon zoom unseen
- `App.entitlements` carries `aps-environment`; without it OneSignal can never
  get an APNs token and push fails silently. The other half is OneSignal's
  **Apple iOS (APNs)** platform, which needs a `.p8` key from Apple: JJ set it
  up 2026-09-22 and holds the file. Until then only Web was active there
- `privacy.html` / `support.html` must stay publicly reachable — App Review
  cannot sign in
- **1.1 native features** (widgets, Live Activity, calendar sync, Siri, Watch):
  `window.Native.setContext/clearContext/settings/setSetting/onRoute` talk to
  the app's `SeafordBridge` plugin and no-op everywhere else. The app is told
  *what to show* and never gets a login; it refreshes from the `team-ics`
  feed. The sign-in screen always calls `clearContext`, so an expired session
  can't leave practices on a Lock Screen. Design and status:
  `../seaford-lax-app/docs/NATIVE.md`

## Dark mode
Neutral iOS greys, not green-tinted ones: true black page, `#1C1C1E` and
`#2C2C2E` surfaces. Dark fills use a **bright** accent with dark text
(`--on-accent`), because white on a green dark enough for 4.5:1 looks muddy.
`--text-strong` is the strong-text token (it used to be `--turf-deep`, which
in dark meant near-white).
**Never put `backdrop-filter` on `header`**: it makes the header a containing
block, and the mobile tab bar is a fixed child of it — the bar lands at the top
of the screen. The blur is desktop-only for this reason.
The toast is a HUD: fixed dark material in **both** themes. It used `--ink`,
which is white in dark mode.

## Design system (decided, don't relitigate)
Full spec in `docs/DESIGN.md`. The rules that get broken by accident:
- **SF (system font) for UI; Manrope only for the wordmark.** Two weights: 600
  headings, 400 body. The type scale is `rem`, so Dynamic Type works
- **Each field has a hue** (`--field-<id>`), used for dots, calendar marks, the
  hero surface and the ripple. Text in a field hue is mixed toward `--ink`
  (`color-mix`) or it fails contrast in light mode
- **Green = interactive/selected. Gold `--mine` = your team. Red = destructive.**
  Selected filters are *tinted*, never solid-filled
- **Segmented controls:** grey track, light thumb. Colour is never the selection
- **Motion goes through `ui/spring.js`**, never a CSS ease on anything touched
- **Icons are custom and solid.** No stroked icon sets
- **44pt minimum** tap target; small controls get a `::before` overlay
- **One confirmation model**: `confirmAction()` sheet for anything destructive.
  `armTwoTap` survives only on booking a slot, which has Undo
- Phones have **no footer**: Appearance, Privacy, Support live in the account
  sheet (monogram, top right). There is no hamburger
- **v3 type tokens are ratios of the root**: `1rem` is iOS Body (17pt), not
  16px. `--ios-body` is `1rem`; see DESIGN.md v3. Nothing under 11pt
- **Book on a phone** is a week strip plus one day as a grouped list with GET
  pills (Book -> Confirm via `armTwoTap`). Desktop keeps the week agenda
- The tab bar's shape, order and labels are JJ's — do not change them. The
  order is **Book, Find a Time, Calendar, My Team** (JJ, 2026-09-23: the order
  a coach works in). First launch opens on Book, then the last tab is restored
- **Calendar tab** = the month (Taken / Open / Mine, and a Fields sheet with
  any combination of fields); the list is its bar button. The Next Practice
  hero is on My Team, the setup checklist on Book
- **Book never preselects a field** (JJ, 2026-09-22): only a starred favourite
  or the last field chosen; otherwise the menu reads "Choose a field", because a
  silent default hid that four other fields exist
- **App icon is the full crest with its wordmark, on white** (JJ's call over a
  helmet-only crop). No dark or tinted variants: it shows as-is everywhere.
  Web home-screen icons (`apple-touch-icon`, `icon-*.png`) use the same art

## Verifying — do this instead of grepping
Three separate times a source grep said "clean" and the running page disagreed:
an emoji written as `&#128075;`, thirteen stroked icons, and a table that only
overflowed once a real long email was in it. **Source is what we wrote;
rendered output is what a coach sees.**

- `?fixture=1` boots the whole signed-in app against in-memory data with a mock
  Supabase client and **zero network calls**. `&as=coach` / `&as=director`
  switch role (default admin; `&as=assistant` too); `&shots=1` hides the banner
  for store screenshots. `invite-coach`/`manage-user` are called with fetch,
  so fixture mode stands them in with the same rules. `&now=soon` / `&now=live`
  add a practice today for the fixture coach (Live Activity, widget states)
- `tools/pixel-audit.js` — fetch and `eval` it on a phone-width fixture page.
  Walks every tab, reports sub-44pt targets and text under WCAG contrast measured
  against the real painted background. Run it in **both** themes
- `../seaford-lax-app/tools/dev-sim.sh` builds a simulator app pointed at the
  local server, and `tools/frames.swift` pulls frames from a `simctl
  recordVideo` capture — the only way to audit a transition, since the Browser
  pane is a hidden document where rAF never runs
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
  a fade, not a bug. Prefer DOM/computed-style reads over screenshots. A
  *hidden* pane never advances CSS transitions at all, so a computed colour can
  be the pre-fade one: `pixel-audit.js` turns transitions off for that reason
- Edge Functions: never nest template literals in the source you inject. Build
  it as an array of single-quoted strings, or fetch the raw file from GitHub
- An inline `style.display = 'block'`/`'inline-block'` beats the phone CSS
  (the tab bar's flex column, the one-line filters). Show things with
  `style.display = ''` and let the stylesheet decide
- Fixed layers must sit **under `<header>`'s z-index (550)** unless they mean
  to cover the tab bar: the bar is a fixed child of the header, so it paints
  at 550, not at its own 700
- The dev simulator (iPhone 17 Pro) is shared with JJ's other project's
  session; `dev-sim.sh` takes `DEV=<udid>` to use another
