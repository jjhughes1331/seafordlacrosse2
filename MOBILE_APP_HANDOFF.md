# Seaford Lacrosse — Mobile App Handoff

This document is for the programmer building a native/hybrid mobile app that
shares data and behavior with the existing web app at **seafordlax.com**.

The web app is a single static file (`index.html`, ~3,900 lines — markup,
CSS, and JS all inline, no build step) backed by **Supabase** (Postgres +
Auth + Realtime + Edge Functions). There is no separate backend to build —
the mobile app should talk to the **same Supabase project** so both stay in
sync automatically. This doc exists to describe that backend precisely,
since it isn't self-documenting anywhere else.

---

## 1. Recommended approach

Given the existing app is 100% client-side logic against Supabase, the
lowest-risk path is **not** a full rewrite:

| Option | Verdict |
|---|---|
| **React Native / Flutter, calling Supabase directly** | Recommended. Reuse the schema, RLS, Edge Functions, and business logic described below. Native push (APNs/FCM) replaces web push. |
| **Capacitor/Cordova wrapping the existing site** | Fastest to ship, but inherits web-push limitations on iOS and feels non-native. Reasonable stopgap, not a long-term answer. |
| **Full rewrite of backend** | Not recommended — there is no reason to; the Supabase project already correctly enforces every permission rule via RLS (see §4), so a thin native client is the smallest correct implementation. |

Whichever is chosen, **the source of truth is the Supabase project below —
never duplicate business logic client-side in a way that could drift from
the RLS policies**, since RLS is the actual security boundary, not the app.

---

## 2. Supabase project connection

```
Project URL:      https://gjpqwmcdejpvffdimddk.supabase.co
Anon/publishable key: sb_publishable_wmEJ2j6OTyiSLE04BP0JSw_zAeEBFMh
```

The anon key is safe to embed in a mobile app (same way it's embedded in
the public `index.html` today) — every table has Row Level Security
enabled, so the key alone grants nothing; access is gated by the signed-in
user's row in `profiles`.

Use the official `supabase-js` client on web; for native, use
`supabase-swift` (iOS), `supabase-kt` (Android/Kotlin Multiplatform), or
`supabase-flutter` — all follow the same query/auth/realtime API shape as
the JS client used in the web app, so the logic below translates directly.

Auth: **Supabase Auth, email+password only.** No OAuth, no magic links.
Sign-up is **not self-serve** — accounts are created only via the
`invite-coach` Edge Function (§6), so the mobile app's "create account" flow
should not exist; it's sign-in only, same as the web app.

---

## 3. Data model

### `profiles` (1 row per authenticated user, id = `auth.users.id`)
| column | type | notes |
|---|---|---|
| `id` | uuid, PK | = `auth.uid()` |
| `email` | text | |
| `role` | text | `'coach'` \| `'director'` \| `'admin'` |
| `gender` | text | `'girls'` \| `'boys'` — null for admin |
| `team_id` | uuid, FK -> teams.id | set for coaches only; null for director/admin |

### `teams`
| column | type | notes |
|---|---|---|
| `id` | uuid, PK | |
| `gender` | text | `'girls'` \| `'boys'` |
| `grade` | text | one of the 7 `GRADES` values below |
| `priority_finished_at` | timestamptz, nullable | set when this team's coach/director marks priority booking "finished" — see §5 |

7 grades, in seniority order (index 0 = youngest/lowest priority, 6 =
oldest/highest priority):
```
Kindergarten, 1st Grade, 2nd Grade, 3rd Grade, 4th Grade, 5th Grade, 6th Grade
```
14 teams total (7 grades × 2 genders). Team identity is `(gender, grade)` —
there's exactly one team per combination, no team names beyond that.

### `bookings`
| column | type | notes |
|---|---|---|
| `id` | uuid, PK | |
| `field_id` | text | FK-ish to the hardcoded `FIELDS` list below (not a DB table) |
| `date` | date | |
| `subfield` | text | e.g. "Field A", "Half Field A (North)" — varies per field, see §7 |
| `time` | text | e.g. "6:00-7:00 PM" — a display string, not a real time type |
| `team_id` | uuid, FK -> teams.id | |
| `booked_by` | uuid, FK -> auth.users.id | |
| unique constraint | | `(field_id, date, subfield, time)` — one booking per exact slot |

### `waitlist`
| column | type | notes |
|---|---|---|
| `id` | uuid, PK | |
| `field_id`, `date`, `subfield`, `time` | same shape as bookings | the slot being waited for |
| `team_id` | uuid, FK -> teams.id | |
| `requested_by` | uuid, FK -> auth.users.id | |
| `created_at` | timestamptz | |
| unique constraint | | `(field_id, date, subfield, time, team_id)` |

### `app_settings` (single row, no id filtering needed — always `limit 1`)
| column | type | notes |
|---|---|---|
| `schedule_locked` | boolean | admin kill-switch — no bookings/cancellations while true |
| `priority_booking_enabled` | boolean | turns the grade-hierarchy gate (§5) on/off |
| `priority_forced_ranks` | integer[] | admin override — see §5 |

### Fields (NOT a database table — hardcoded in the client)
Both the web app and the mobile app need this exact list hardcoded
client-side (it rarely changes; if it does, both apps must be updated
together). Alphabetical by name, which is also the order they should
render in:

```js
[
  { id: "cedarcreek", name: "Cedar Creek",
    note: "East Field, Tuesday and Thursday only. Half field only (shared with soccer and Wantagh Lax).",
    availability: [ { days:[2,4], subfields:["1/2 Field"], times:["4:30-5:30 PM","5:30-6:30 PM","6:30-8:00 PM"] } ] },
  { id: "harbor", name: "Seaford Harbor",
    note: "Field 1 inside track, Field 2 outside track.",
    availability: [
      { days:[1,2,3,4,5], subfields:["Field 1","Field 2"], times:["4:30-5:30 PM","5:30-6:30 PM","6:30-7:30 PM","7:30-8:30 PM"] },
      { days:[0,6], subfields:["Field 1","Field 2"], times:["9:00-10:00 AM","10:00-11:00 AM","11:00-12:00 PM","12:00-1:00 PM","1:00-2:00 PM","2:00-3:00 PM","3:00-4:00 PM","4:00-5:00 PM","5:00-6:00 PM","6:00-7:00 PM","7:00-8:00 PM"] },
    ] },
  { id: "seafordhs", name: "Seaford HS",
    note: "Turf field. School games have priority weeknights.",
    availability: [
      { days:[1,2,3,4,5], subfields:["Half Field A (North)","Half Field B (South)"], times:["7:15-9:00 PM"] },
      { days:[6], subfields:["Half Field A (North)","Half Field B (South)"], times:["1:00-2:00 PM","2:00-3:00 PM","3:00-4:00 PM","4:00-5:00 PM","5:00-6:00 PM","6:00-7:00 PM"] },
    ] },
  { id: "sms", name: "Seaford MS",
    note: "Grass field. School teams have priority; permit starts at 5 PM.",
    availability: [
      { days:[1,2,3,4,5], subfields:["Half Field A","Half Field B"], times:["6:00-7:00 PM","7:30-9:00 PM"] },
      { days:[6], subfields:["Half Field A","Half Field B"], times:["1:00-2:00 PM","2:00-3:00 PM","3:00-4:00 PM","4:00-5:00 PM","5:00-6:00 PM"] },
    ] },
  { id: "seamans", name: "Seamans Neck Park", short: "Seamans Neck",
    note: "Field A closest to parking, B mid field, C far end.",
    availability: [
      { days:[1,2,3,4,5], subfields:["Field A","Field B","Field C"], times:["5:00-6:30 PM","6:30-8:00 PM","8:00-10:00 PM"] },
      { days:[6], subfields:["Half Field A","Half Field B"], times:["1:00-2:00 PM","2:00-3:00 PM","3:00-4:00 PM","4:00-5:00 PM","5:00-6:00 PM"] },
    ] },
]
```
`availability[].days` uses JS `Date.getDay()` convention (0=Sunday...6=Saturday).
A field's bookable slots on a given date = the union of every `subfield` ×
`time` in whichever `availability` entry's `days` includes that date's
weekday. **Season bounds: March 1 2027 – June 30 2027** (`SEASON_START`,
`SEASON_END`) — no bookable dates outside that range.

---

## 4. Row Level Security — the actual permission model

Every table has RLS enabled. **The mobile app must not attempt to
replicate these rules client-side as the security boundary** — always let
Postgres enforce them; client-side checks are only for UI (disabling a
button), never for actually gating a write.

- **`bookings` insert**: allowed if `booked_by = auth.uid()` AND the caller
  is (a) an admin, OR (b) a coach whose `profiles.team_id` matches the
  booking's `team_id`, OR (c) a director whose `profiles.gender` matches
  the target team's gender — AND `schedule_locked` is false — AND (if
  `priority_booking_enabled`) the team's grade tier is unlocked (§5).
- **`bookings` delete**: same scoping as insert (own team / own gender's
  teams / admin), plus schedule not locked.
- **`waitlist` insert/delete**: same team-ownership scoping as bookings,
  but **not** gated by `schedule_locked` (joining a waitlist doesn't move
  a slot, so it's harmless during a lock).
- **`waitlist` select**: any authenticated user can see the full waitlist
  (so "2 waiting" can render for anyone browsing).
- **`teams` update**: only used to set `priority_finished_at`; same
  team-ownership scoping (coach of that team / director of that gender /
  admin).
- **`profiles`**: users can read their own row. Invites (creating new
  profiles) go through the `invite-coach` Edge Function only (§6) — there
  is no direct insert policy for arbitrary signup.

A **coach** sees/acts on exactly one team (`profiles.team_id`). A
**director** sees/acts on every team of one gender (`profiles.gender`). An
**admin** sees/acts on everything and has no team_id/gender of their own.

---

## 5. Priority booking (grade-hierarchy gate)

When `app_settings.priority_booking_enabled = true`, a team can only book
once **every older/more-senior grade tier has finished** — combined across
both genders. Seniority order (highest number = most senior, unlocks
first): `Kindergarten=0, 1st=1, 2nd=2, 3rd=3, 4th=4, 5th=5, 6th=6`.

A team's tier is "unlocked" iff, for every grade rank strictly greater than
its own, either every team at that rank has `priority_finished_at` set, OR
that rank is present in `app_settings.priority_forced_ranks` (an admin
override — see below). This logic lives in two Postgres functions
(`grade_rank(text)`, `team_priority_unlocked(uuid)`), callable directly —
**do not reimplement this arithmetic in the mobile client**; call the
Postgres function or read `teams.priority_finished_at` fresh and defer the
actual decision to the RLS policy on insert (an insert simply fails if not
unlocked — surface that failure as "booking isn't open yet for your team").

**Director-forced override**: an admin can force a specific rank's tier
through even if not every team in it finished, by adding that rank number
to `priority_forced_ranks`. This is a *set*, not a threshold — forcing
rank 6 through only unlocks rank 5; it does not cascade to also unlock
rank 4/3/etc. before rank 5 itself finishes (or is itself forced).

A coach/director marks their own team "finished" by setting
`teams.priority_finished_at = now()` (via the RLS-scoped update, §4). An
admin can reset the whole season's priority state (used e.g. between
seasons) by nulling `priority_finished_at` on every team at once.

---

## 6. Edge Functions

Both already deployed on the Supabase project; call them the same way from
mobile as the web app does (plain `fetch`/HTTP, not a special SDK call).

### `invite-coach`
```
POST https://gjpqwmcdejpvffdimddk.supabase.co/functions/v1/invite-coach
Authorization: Bearer <the calling admin/director's own session access token>
Content-Type: application/json
```
This is the **only** way new accounts get created — there is no public
sign-up. Admins can invite a coach (any team) or director (either gender);
directors can invite coaches for their own gender's teams only (enforced
inside the function, mirroring §4's scoping). Body shape: consult
`index.html`'s two call sites (`INVITE_FUNCTION_URL` usages) for the exact
JSON payload (`email`, `role`, `gender`, `team_id`/grade) before
implementing, since the function itself is the source of truth for its
request contract, not this doc.

### `send-push`
```
POST https://gjpqwmcdejpvffdimddk.supabase.co/functions/v1/send-push
x-push-secret: <shared secret — NOT the OneSignal REST key, a separate
                 secret stored in Supabase Edge Function secrets AND
                 Supabase Vault>
Content-Type: application/json

{ "title": "...", "message": "...", "url"?: "...",
  "broadcast"?: true, "externalIds"?: ["<supabase user uuid>", ...] }
```
This function is called **server-side only**, by three Postgres triggers
(pg_net) — never called directly from either the web or mobile client. It
exists so the real OneSignal REST API key never touches client code. The
mobile app does not need to call this function itself; it only needs to
be a valid *recipient* (§8).

---

## 7. Feature-by-feature behavior to replicate

The web app has 6 views, gated by role. Tab visibility per role:

| View | Coach | Director | Admin |
|---|---|---|---|
| Schedule (view full town schedule, all teams/genders) | ✅ | ✅ | ✅ |
| Book (a practice time) | ✅ own team only | ✅ any team of their gender | ✅ any of 14 teams |
| Fields Open This Week | ✅ | ✅ | ✅ |
| My Team's Practices | ✅ | — | — |
| League Overview | — | ✅ | ✅ |
| Admin (invites, lock toggle, priority controls, danger zone, reports) | — | partial | ✅ full |

Key behaviors:
- **Schedule**: filterable by gender + grade (a single-select picker, not
  a big grid — see the mobile-web redesign notes in git history if
  curious why) or "All teams". Toggle between "By Team" (agenda list) and
  "By Field" (weekly/monthly grid of open/booked slots, read-only).
- **Book**: pick a field (chips), pick timing mode — **Weekly** (agenda,
  paged 7 days at a time), **Monthly** (calendar grid), or **Season**
  (pick day(s)-of-week + one time slot, books every matching date through
  season end in one batch — this is the "recurring" booking feature).
  "Find next open slot" jumps straight to the earliest open slot for the
  selected field. Coaches land pre-filtered to their own team; admin/
  director must explicitly pick a team first (dropdown defaults to a
  placeholder, not a silent default — booking UI stays hidden until a
  team is chosen).
- **Fields Open This Week**: read-only list of what's currently open,
  filterable by field.
- **My Team's Practices**: coach-only agenda of just their team's
  bookings, with CSV export (TeamSnap import format) and .ics calendar
  export.
- **League Overview**: director/admin-only cross-team summary.
- **Admin**: sectioned as *People* (invite coach/director, bulk invite
  from spreadsheet, coach list), *Booking Controls* (schedule lock
  toggle, priority-booking toggle + per-tier status + reset), *Danger
  Zone* (destructive actions, two-tap confirm), *Reports* (analytics,
  moved out of the main flow deliberately — see §9 UX notes).
- **Two-tap confirm pattern**: every irreversible action (cancel a
  booking, delete something, mark priority finished) requires tapping
  once to "arm" (button re-labels itself, e.g. "Tap again to confirm...")
  and again within a few seconds to actually execute — never a native
  confirm() dialog. Replicate this interaction pattern natively rather
  than using a platform alert, for consistency with the web app.
- **Waitlist**: if a slot is booked, users can join a waitlist for it
  instead of just seeing it as unavailable; if the booking is later
  cancelled, everyone waiting gets notified (push, §8) and can then book
  it normally (no auto-assignment — first to act gets it).
- **Weather**: best-effort forecast overlay on the calendar (a third-party
  API call, fire-and-forget — never blocks sign-in or booking if it
  fails).

---

## 8. Push notifications — native equivalent

The web app uses OneSignal Web Push. For the mobile app, use OneSignal's
native SDKs (same OneSignal **App ID**, different platform config):

```
OneSignal App ID: 6566d2f0-7fee-4091-849f-d39551d3f360
```
This is the same App ID as the website — **do not create a second
OneSignal app**; add iOS (APNs) and/or Android (FCM) as additional
platforms on this existing app so both web and mobile notifications route
through one dashboard/one set of triggers.

Requires:
- An APNs `.p8` auth key (Apple Developer account) for iOS.
- A Firebase FCM v1 service account JSON for Android.
- Uploading both to this OneSignal app (Settings → Platforms), or via the
  OneSignal API's credential-provisioning endpoint.

**Critical for parity with the web app**: after sign-in, call
`OneSignal.login(supabaseUserId)` (native SDK has the same method) so this
device's subscription is tagged with the same Supabase user id the web
app uses. This is what lets the existing Postgres triggers target a
specific person by `external_id` across *both* platforms — no trigger
changes needed on the backend, they already send to `external_id`, which
OneSignal fans out to every subscribed device (web + iOS + Android) for
that person. Call `OneSignal.logout()` on sign-out, same as web.

The 3 events that currently trigger a push (already live, backend-only,
nothing to build here beyond receiving them):
1. A booking is cancelled and someone was waitlisted for that exact slot.
2. Admin locks/unlocks the schedule (broadcast to everyone subscribed).
3. A grade tier finishes priority booking, unlocking the tier below it
   (sent to that tier's coaches/directors specifically).

---

## 9. Design reference

Not required for functional parity, but for visual consistency:

- **Palette**: deep forest green primary (`--turf-deep`), lighter green
  accent (`--turf`), warm off-white background in light mode, dark
  charcoal-green in dark mode. Full token list is in `index.html`'s
  `:root` block — copy the hex values directly rather than eyeballing
  screenshots.
- **Type**: a rounded display font for headings, system font stack for
  body text.
- **Shape language**: fully-rounded "pill" controls everywhere —
  segmented toggles, chips, the bottom tab bar, the grade/team picker —
  not sharp corners or even standard 8px-radius cards. This was a
  deliberate, recent design pass; match it rather than defaulting to
  platform-standard corner radii.
- **Bottom nav**: on mobile web, a floating inset pill bar (not
  edge-to-edge), icon + short label, sliding active-pill indicator,
  subtly shrinks while scrolling and springs back when scrolling stops.
  A native tab bar achieving the same *feel* (not necessarily identical
  CSS-for-CSS) is the goal, not a literal WebView port of this exact bar.
- **Dark mode**: follows system `prefers-color-scheme` by default; a
  manual override is available and persisted (would map to the native
  platform's own light/dark override mechanism).
- Full CSS is in `index.html` if exact values are needed for anything not
  covered above — there is no separate design file/Figma to consult.

---

## 10. What "in sync" means in practice

Because both apps hit the same Supabase project directly:
- **Data is always in sync** — a booking made on mobile appears
  immediately on web and vice versa, no polling/sync logic to write
  beyond subscribing to the same Realtime channels the web app uses
  (`bookings`, `app_settings`, `waitlist`, `teams` — see §3's code
  snippet in `setupRealtime()` in `index.html` for the exact channel
  setup to mirror).
- **Permissions are always in sync** — since RLS is the enforcement
  layer, not app code, there's no separate "mobile API" to keep
  consistent with "web API" — they're the same API.
- **The one thing that does NOT sync automatically** is UI/business-rule
  changes made only in `index.html` (e.g. a new view, a changed booking
  flow) — those must be manually ported to the mobile codebase, since
  there is no shared component layer between a static HTML site and a
  native app. Budget for that ongoing maintenance cost explicitly; it is
  the real cost of "two apps, one backend."
