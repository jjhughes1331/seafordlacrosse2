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
