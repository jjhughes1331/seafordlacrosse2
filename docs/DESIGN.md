# Seaford Lacrosse — Design v2 ("Floodlight")

The brief: minimalist, design-forward, premium, every interaction delightful,
native-feeling but not generic iOS. This file is the source of truth for the
redesign: principles, the system, each signature component, and a running log.

## Principles
1. **One answer per screen.** Every screen opens on the thing you came for.
2. **Colour carries meaning, never decoration.** Green = interactive/selected.
   Gold = your team. Each field has its own hue. Everything else is neutral.
3. **Motion is physics, not timing.** Springs with real velocity, interruptible,
   no linear or ease-in-out tweens on anything a finger touched.
4. **Quiet surfaces, loud moments.** Chrome is near-invisible; the few moments
   that matter (next practice, a booking landing) get the craft budget.
5. **Nothing moves for Reduce Motion users** beyond opacity.

## The system
| Token family | Rule |
|---|---|
| Spacing | 4pt base; component padding in 8s; section rhythm 24/32 |
| Type | SF Pro. Large title 34/700 −0.6; title 22/600; body 17/400; caption 13/400. Tabular numerals on every number that aligns |
| Radii | 8 / 12 / 16 / 22 / pill. Cards 16, sheets 22 |
| Surfaces | Light: #F2F2F7 page, #FFF card. Dark: #000 page, #1C1C1E card, #2C2C2E raised |
| Field hues | Cedar Creek teal, Seaford Harbor blue, Seaford HS violet, Seaford MS orange, Seamans Neck rose. Each has a light and dark value |
| Motion | `spring.snappy` (menus, thumbs), `spring.gentle` (sheets), `spring.bouncy` (success only) |

## Signature components (`ui/`)
| File | What it is |
|---|---|
| `ui/spring.js` | Tiny spring solver. Interruptible, carries velocity, drives transforms |
| `ui/field-menu.js` | The field switcher: a title-style button that blooms into a menu from its own origin. Colour dot per field, checkmark, favourite star |
| `ui/aurora.js` | WebGL mesh-gradient shader behind the Next Practice card, tinted by the practice's field |
| `ui/ripple.js` | The booking-landed moment: a pressure ring from the exact tap point |
| iOS `LaunchShader` | Native Metal launch: chalk field lines draw on over turf, then hand off to the app |

## Verification
- Every screen, light and dark, iPhone 17 Pro Max simulator, dev build pointed
  at the local fixture server (no deploy needed to iterate)
- Transitions recorded with `simctl io recordVideo`, frames pulled with
  `tools/frames.swift`, inspected frame by frame
- `tools/render-audit.js` extended with a spacing-grid and contrast pass

## Log
- 2026-09-22 — plan written; starting with tokens, spring, field menu
- 2026-09-22 — shipped: field hues, field menu (schedule/league/book), Apple
  Calendar cells with times, inset-grouped list, aurora hero with countdown,
  ripple on booking, Metal launch scene, HUD toast, menu carries footer
- Audit findings fixed along the way, each caught on the simulator, not in
  source: team filter above the title; orphaned bar subtitle; hero edge to
  edge; shader bloom behind the white type; hero colour pop before first
  WebGL frame; launch clock started during the icon zoom; storyboard class
  ignored (Capacitor 8 builds the root VC in SceneDelegate); toast white in dark
  mode and one word wide; zebra rows plus hairlines; field hues failing
  contrast as text in light mode; grey track eating segment label contrast;
  push entitlement missing entirely
- pixel-audit: 0 sub-44pt targets, 0 contrast failures, all tabs, both themes
- 2026-09-22 — JJ: Book must not preselect a field (coaches missed that there
  are five); it opens on "Choose a field". JJ: the home-screen icon is the full
  crest with its wordmark on white, not the helmet crop. Both in CLAUDE.md
- Later polish from the simulator: iOS sticky hover on touch, tab switches
  carrying scroll, the title handoff waiting until fully hidden, and a
  segmented thumb measured while hidden. Builds 8-10 uploaded; push
  entitlement now provisioned (aps-environment: production in the export)


---

# Design v3 — "as if Apple built it" (2026-09-23)

JJ's brief: judge it as an Apple Design Award panel would, take what the
winners do, and make it look and work like an app Apple ships on every
iPhone. Research (ADA 2023-2026 winners and criteria, the iOS 26 HIG, best
schedule/booking apps, a code-level audit) is summarised in the session
scratchpad; the rules it produced are below.

## Rules
1. **iOS grammar everywhere; the field hues and the chalk-line launch are the
   only things that are ours.** Inset grouped lists (26pt corners, 52pt rows,
   title-case section headers), sheets with a grabber and Done, action sheets
   for choices and confirmations, bar buttons as glass circles, GET pills.
2. **Type is Apple's text styles, as ratios of the root.** The root is
   `-apple-system-body`, so `1rem` is Body (17pt at the default size):
   `--ios-large` 2rem (34), `--ios-title2` 1.294rem (22), `--ios-title3`
   1.176rem (20), `--ios-body` 1rem, `--ios-sub` .882rem (15), `--ios-foot`
   .765rem (13), `--ios-cap` .706rem (12). Nothing under 11pt.
3. **One answer per screen, controls in the bar.** Month/List is a bar button
   (Schedule and League); filters share one line; Find a Time's filters are
   pull-down pills over native `<select>`s so iOS draws its own pickers.
4. **Book on a phone is Calendar's day view**: a week strip (dots: green open,
   gold yours), then one day as a grouped list, a section per time, a row per
   field, a GET pill that arms to Confirm (armTwoTap), gold when booked.
5. **Haptics by outcome**: `selection` for segments/filters/strip, `light` to
   open, `success`/`warning`/`error` for how it went (warning = another coach
   took the slot). Tab taps are silent, as in iOS.
6. **Motion**: tabs appear instantly on a phone; sheets drag with the finger's
   velocity (`ui/sheet.js`); the hero shader runs ~20fps, rests after 12s
   idle, and is still under Reduce Motion or Low Power Mode (`html.lpm`).
7. **The app works offline**: scripts are vendored (`vendor/`), boot reads
   the session from the device, and a cached schedule draws before the
   network answers.
8. **Tabs run in the order a coach works** (JJ, 2026-09-23): Book, Find a
   Time, Calendar, My Team. The first launch opens on Book; after that the
   app reopens on the tab you left (`seaford-last-view`), as Apple's tab-bar
   apps do. The setup checklist lives on Book, the Next Practice hero on My
   Team.
9. **Calendar is iPhone Calendar's month**: weeks edge to edge under a
   hairline, today filled with the tint, practices as labels tinted in their
   field's colour. **Taken / Open / Mine** is a segmented control (Open is
   outlined, like an unconfirmed event, and each open time has a Book pill
   that lands on that time in Book). **Fields** is Calendar's "Calendars"
   sheet: any combination of fields on or off. Both are per device.

## Log
- 2026-09-23 — v3 shipped to branch `design-ada` in parts 1-12: account
  sheet (monogram replaces the hamburger), draggable sheets, Book day view,
  Find a Time results-first, My Team action tiles, scroll-edge fades,
  action-sheet confirmations, sign-in rebuilt (AutoFill), month agenda as a
  grouped list, League in Schedule's grammar, and the audit's fixes (type
  scale, touch hygiene, VoiceOver live toast, clean sign-out, colour
  meaning, calendars open on today, one refresh path, offline boot).
- 2026-09-23 — v3.1 after JJ used build 12: tabs reordered to Book, Find a
  Time, Calendar, My Team; the app lands on Book and then restores the last
  tab; Calendar opens on the month on phones (it opened on a 16,000px list)
  with Taken / Open / Mine and a Fields sheet; the day list stacks start over
  end time in a fixed column so every title aligns.
