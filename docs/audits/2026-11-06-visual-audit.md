## Design Critique: seafordlax.com

Audit of 2026-11-06, branch `native` (clean). Local fixture `?fixture=1&shots=1` as admin, director, coach and assistant; phone 375x812 and 430x932, desktop 1440x900, light and dark. Live public pages: `/`, `/privacy.html`, `/support.html` (not signed in). Numbers are computed styles or the repo's audit tools unless marked "source". Screens caught mid-GSAP were re-checked after 1.5s before being called a bug.

Tool results:
- `pixel-audit.js`, admin, light: 1 target under 44pt (League `select.grade-select`, 43px), 0 contrast failures. That run missed Book's content because no field was chosen yet.
- `pixel-audit.js`, coach, light, with a field chosen: **`span.book-month-badge "1 mine" 2.92:1 (needs 4.5)`**.
- `pixel-audit.js`, coach, dark: clean.
- `render-audit.js`: 0 emoji, 0 stroked icons, 5 solid icons, 0 em dashes, 0 sideways page scroll. 1 overflowing `TABLE` (Admin > People). Font families in use: `Arial`, `ui-rounded`, `-apple-system`.

### Overall Impression
The coach-facing core is good. Find a Time, the field menu, the Fields sheet, the My Team hero and the Book day list with GET pills read like an Apple app, and dark mode is well made. The problems are about getting to things and keeping them consistent. On a phone, Book pushes the first bookable slot below the fold at every size. Admin, including the new Teams and League Schedule screens, has lost its layout container (0px gutters on phone, full-bleed at 1440). And the older v2 grammar (bordered cards, Arial buttons, uppercase labels) still sits right next to the new iOS-style sheets.

### Priority Recommendations

1. **Book: show slots without scrolling (coach, phone).** After a field is chosen, the week strip starts at y=843 on 375x812 and y=844 on 430x932. The tab bar starts at about y=740 (375x812) and y=842 (430x932), so a coach sees no slot at all. The space above it holds the Get Set Up card (250px), the install nudge (152px), the field note and Map (74px) and the segmented control. *Why:* "one answer per screen". Booking is the job, and coaches do it fast. *How:* order the page as field menu, Week/Month/Season, week strip, day list. Move Get Set Up below the day list, or collapse it to a single row ("Get Set Up, 1 of 3") once any item is done. Move the install nudge to the bottom of Book or into the account sheet. Put the field note and Map pill on one 44pt row. **M**
2. **Admin: restore the page container (admin and director, phone and desktop).** On a phone, `#adminPaneToggle` measures L=0 R=375, and every Teams group, `.admin-section-label` and the Add Team button touch the screen edge. The rule at index.html:2323 (`margin: 12px 16px`) is overridden by the inline `style="margin:0 0 18px"` on line 3009. At 1440 the new Teams list and League Schedule run 0 to 1440 and Add Team ends at x=1436, while People cards are capped at 1000px (`.admin-card`). *Why:* the new screens look broken at first sight, and rows are hard to scan on desktop. *How:* wrap each `.admin-pane` in `.wrap` (max-width 1000, 20px padding) and remove the inline margin. **S**
3. **Fix the two text contrast failures (light).** The Book Month "1 mine" badge is `rgb(184,134,11)` 11px on #F2F2F7, **2.92:1**. The priority ladder's "AFTER YOU" rows are `--muted` at opacity .55 on a pink tint, **2.15:1**. *How:* give the badge the colour of the "Yours" label (measured 5.68:1 on the gold row; use a `--mine-text` token). Draw ladder rows at full opacity in `--muted` (5.23:1) and dim only the dot. **S**
4. **Team sheet: don't drop edits on Done (admin, new).** `closeTSheet('teamSheet')` sets `teamDraft = null`, so typing a Name or League Name and tapping Done or swiping the sheet away loses it with no warning. The edits only save through an in-list "Save" row. Add Team, by contrast, uses Cancel / Add in the bar. *How:* when the draft has changed, make the bar button **Save** (it saves, then closes), or ask "Discard changes?" through `confirmAction()`. Drop the in-list Save row. **S**
5. **Booking toast: make Undo big enough and the message specific (coach).** `.toast-action` "Undo" is 58x28 with no `::before` overlay. Undo is the recovery path for the one action that has no confirm sheet. The message "Booked Field 2, 4:30–5:30 PM" wraps between "4:30–" and "5:30 PM" at 375, and it doesn't say which of the five sites or which day ("Field 2" exists at four of them). *How:* add the 44pt `::before` overlay to `.toast-action`, put `white-space: nowrap` on the time, and use the copy "Booked Seaford Harbor Field 2, Mon Mar 1, 4:30 to 5:30 PM". **S**
6. **Notifications sheet: be honest when push is off (all roles, new).** With browser permission off, the top row reads "Notifications Off" and has no action, yet five switches below show green (on). A coach thinks alerts are on. *How:* when permission is not granted, dim the Alerts group (opacity .4, still editable) and make the top row a green action, "Turn On Notifications", or on iOS web "Add to Home Screen to get alerts". This matches the Get Set Up row, which already says "Turn On Notifications". **M**
7. **Bring the old Admin panes and Season card up to v3 grammar.** Booking, Danger, Reports, People > Invite and Book > Season still use `.admin-card` and `.recurring-card` (14px radius, 1px border, shadow), `.allbtn` and `.btn-primary` (10px radius, **Arial**, because buttons don't inherit the font), uppercase `.admin-section-label`, and nested segmented controls three levels deep (Admin, People, Email invite). The new Teams pane next to them uses inset grouped lists and title case. *How:* Schedule lock becomes a switch row, "Schedule Locked", with a footer. Priority booking becomes a switch row plus a "Reset Finished Teams" action row, which uses `confirmAction()`. Danger selects open on "Choose a team" and "Choose a field", never a real team (today "Girls Kindergarten" is preselected for a delete). Reports chips become a segmented control (today "Waitlist" wraps to a second line). Add `button, select, input { font-family: inherit; }` globally. **L**
8. **Priority gate: wrong colour and an emoji (coach and director).** `#priorityLockedBanner` has a red border and tint (`rgb(215,0,21)`) for "not your turn yet", which is not destructive. The blocking row's dot is `&#8987;` (index.html:5209), which iOS draws as a colour emoji. `render-audit`'s emoji range starts at U+2600, so it misses it. The notes are uppercase and letter-spaced. *How:* use a neutral card with a gold `--mine` outline on "your" row and a custom solid hourglass SVG. Write the notes in title case: "2 Teams Still Booking", "You're Next", "After You". Extend the render-audit emoji range to `⌀-⏿`. **S**

### Usability

| Finding | Severity | Recommendation |
|---|---|---|
| Book slots below the fold on every phone size (y=843/844) | 🔴 | Rec 1 |
| Team sheet loses Name/League Name edits on Done | 🔴 | Rec 4 |
| Notification switches look on while push is off | 🔴 | Rec 6 |
| `armTwoTap` window is 3s (index.html:4403). In testing, an armed Confirm expired between two deliberate taps. VoiceOver users get no extension | 🟡 | 5s, and keep it armed while focus or VoiceOver is on the pill. Update `aria-label` to "Confirm booking, Field 2, ..." while armed |
| Phone Waitlist pill (ink text, 14.75:1) outweighs the Book pill (green, 5.09:1), so taken rows look more actionable than open ones | 🟡 | Draw Waitlist in `--muted` text on the quiet pill, so Book is the strongest thing in the list |
| My Team action tile labelled "Calendar" (it adds to your phone's calendar) shares its name with the Calendar tab | 🟡 | Label it "Add to Calendar". Make "TeamSnap" read "TeamSnap CSV" (its aria-label already says Export to CSV) |
| Coaches list on My Team is plain text, so a coach can't reach the assistant from it | 🟡 | Make each row a `mailto:` link with a chevron, and show the name above the email |
| Person picker (Change Head Coach / Add Assistant) has no way to add someone not yet invited | 🟡 | Last row: "Invite Someone New", which opens People > Invite with the team filled in |
| Admin > People on phone is a 675px table in a 333px scroller. Emails are clipped, and rows are 100-190px tall | 🟡 | Use the person picker's row grammar (name, then "Role · Teams · email") |
| League Schedule preview shows only totals (94 games, Girls 50, Boys 44), so a director can't sanity-check before "replace the whole season" | 🟡 | Add the date range ("Mar 28 to Jun 6") and games per grade. Keep the unmatched-names list |
| Calendar list mode swaps Taken/Open/Mine and Fields for Girls/Boys and Team, so the filters change under the coach | 🟢 | Keep Mine as a filter in list mode, or say in the list header which filter applies |
| Book large-title subtitle stays "Choose a team to book for" after a team is chosen (admin) | 🟢 | Subtitle becomes the team, as it does for coaches |
| Director Book shows a month of "5 open / 1 mine" counts while the empty state above says "Choose the team..." (field remembered from an earlier session) | 🟢 | Hide the calendar until a team is chosen |
| Lock and priority toggles have no confirm, though they change booking for everyone. They're reversible, so that's acceptable | 🟢 | Keep. The switch rows in Rec 7 make the state readable |

### Visual Hierarchy

- **Book (coach, phone):** the eye lands on the Large Title, then the coloured Get Set Up icons (gold, green, red), then the install card. The field menu is fourth and the slots are off-screen. After Rec 1 it should read title, field, week strip, first GET pill.
- **Find a Time:** the best hierarchy in the app. Filters as pills on one line, a one-line explanation ("Showing your team's usual days and time"), then results with field-hue dots and Book pills. Nothing to change.
- **Calendar (month):** the 11px time chips form a dense coloured grid that reads well as "busy or not". The "mine" chip (gold at 32%) is hard to tell from a Seaford MS chip (orange at 17%) at that size. Give mine chips a 2px gold leading bar so they don't depend on hue alone.
- **My Team:** the hero leads, then the tiles, then the per-field lists. Good. The large-title subtitle "Girls 6th Grade" repeats in the switcher directly below it ("Girls 6th Grade · Head Coach"). When the switcher shows, put only "Updated just now" in the subtitle.
- **Admin > Teams:** the description and Add Team share a row, so Add Team (outlined, 13px Arial) reads as secondary. Put "Add Team" as a green action row at the top of the list or as a `+` bar button, as iOS Contacts does.
- **League:** two filter rows (All/Girls/Boys + team, then Taken/Open + Fields) push the month down. The month header sits at L=36 while Calendar's sits at about L=16, so the same component has two indents.

### Consistency

| Element | Issue | Recommendation |
|---|---|---|
| Corner radii | Tokens are `--radius-card` 14 and `--radius-chip` 10. DESIGN.md says 8/12/16/22/pill, and v3 grouped lists use 26 | Retire 10 and 14. Cards 16, sheets 22, grouped lists 26, as written |
| My Team practice lists, Coaches card | `.rows` 14px radius, 0.5px hairline border, 335 wide (20px gutter) vs Book `.ios-group` 26px, no border, 343 wide (16px gutter) | Make both `.ios-group` with the 16px gutter |
| Button font | `.allbtn`, `.btn-primary`, `.view-tab`, `.mtab`, `.signout-btn` compute to **Arial** in Chromium (render-audit). Safari hides it, but desktop Chrome and Windows directors see it | `button, select, input, textarea { font: inherit; }` |
| Section labels | Admin uses uppercase letter-spaced labels ("TEAMS", "LEAGUE SCHEDULE", "DANGER ZONE"). v3 rule 1 says title case | `.admin-section-label { text-transform: none; }` at `--ios-foot` |
| Waitlist control | Phone: grey quiet pill. Desktop: green text button, 24px tall | One component. On desktop give it the same pill and a 44pt hit area (iPads at 768 and up get the desktop layout) |
| Arrows and close glyphs | Text characters: `‹ ›` (cal-nav, 30px weight 300), "←Prev month / Next month→" on desktop, `×` in the toast, `✓ ● ⌛` in the ladder | Custom solid chevron, close and check SVGs, per "icons are custom and solid" |
| Red | Used for the Notifications tile in Get Set Up, the lock banner and the priority gate. None are destructive | Red only for delete. Lock banner and gate become neutral, with gold for "you" |
| Switch green | `.ios-switch` is `rgb(52,199,89)` (system green). The app's interactive green is `rgb(31,110,64)` | Acceptable as iOS grammar. If kept, document it in DESIGN.md as the one exception |
| Site names | "Seamans Neck" (Find a Time rows) vs "Seamans Neck Park" (menus, My Team) | Use the full name everywhere, or define a short name in `field-catalog.js` |

**New screens specifically**
- Admin > Teams list, team sheet, person picker and Add Team sheet: the right grammar (grouped rows, grabber, Done, chevrons, title case). Only the container is broken (Rec 2).
- Team sheet vs Add Team sheet: Done + in-list Save vs Cancel / Add. Use Cancel / Save (Rec 4).
- League Schedule: the action is an `.ios-row` (good), but Import / Cancel underneath are v2 `.btn-primary` / `.allbtn` (10px radius, Arial, 17.4px vs 13.1px labels). Use a full-width green action row and a plain Cancel row.
- Notifications sheet: matches iOS Settings. "My Assigned Teams" has a subtitle, "Your assigned teams", that repeats it; give it a fact instead ("Girls 6th Grade, Girls 2nd Grade Green").
- My Team switcher and Coaches: the switcher is a native select pill (good, iOS draws the picker). The Coaches card has its title inside the card, while v3 headers sit outside the group. Move "Coaches" out as a section header.

### Accessibility

- **Contrast, light:** "1 mine" 2.92:1 and ladder "AFTER YOU" 2.15:1 fail (Rec 3). Close passes: lock banner red 4.58:1, field note `--muted` on the page 4.69:1, week-strip day letters 4.69:1. Sign-in placeholders are 3.26:1 (iOS default, and the fields have labels, so acceptable).
- **Contrast, dark:** pixel-audit clean on all coach tabs. I didn't measure the hero text over the WebGL surface. By eye, the subtitle line on the rose hero (Seamans Neck, dark) is the weakest; add a 20% black scrim behind the text block.
- **Targets:** field-menu star `fm-star` is 40x40 with no overlay, and it sits inside a 60px row, so a near miss selects the field instead of starring it. Toast Undo is 58x28 (Rec 5). League team select is 43px. Desktop Waitlist is 24px. Sign-in "Privacy Policy" and "Support" links are 15px tall on the page App Review sees. Give the links 44pt padding.
- **Dynamic Type:** body and most UI use rem (good). Calendar chips (`.cal-ev` 11px), `.book-month-badge` (11px phone, **9px** base per source line 1011), `.book-month-dow` (10px base) and `font-size: 16px` inputs are px and won't scale. Move them to `--ios-cap` or `--ios-foot`.
- **Colour alone:** calendar chips tell fields apart only by hue (WCAG 1.4.1). The Fields sheet legend helps. Rec: the gold bar for "mine" (Hierarchy), and the field name in each chip's `aria-label`.
- **Motion:** `prefers-reduced-motion` is handled in index.html (4 rules), spring.js, aurora.js and ripple.js. `button:active { transform: scale(.98) }` is a CSS ease on touched elements. Route it through spring or drop the scale under reduced motion.
- **Focus:** `:focus-visible` rings exist for buttons, links, selects, the monogram and bar buttons. Good.

### Polish

- **Orphan bullet:** the large-title subtitle wraps "· Updated just now" onto its own line with the dot first (admin and director at 375, where the subtitle is "Choose a team to book for"). Hide the `::before` dot when the label wraps, or drop the "Updated" stamp once a team subtitle is long.
- **Stray 4x4 dot:** a director with one program gets an empty `#genderTabs` (4x4, drawn as a grey dot at x=16). It pushes the team select to x=30 instead of the 16px gutter. Use `display:none` when there are no tabs.
- **Desktop Book:** the "Booking for: Girls 6th Grade" banner has a 1.5px black border and looks like a focused text field. Use a plain caption. The "Signed in as ... Sign out" bar repeats the account sheet.
- **Long values:** `jordan.reallylongaddress@fixture.test` fits in the Teams row and the picker. It is clipped in the People table (Usability).
- **Empty and loading states:** copy is clear and specific ("5 fields, each with its own days and times. Pick one to see what is open."). Reports shows "Nothing recorded yet." with no icon. Fine.
- **Public pages:** `privacy.html` and `support.html` set body text in **Manrope** (the rule is wordmark only) on a green-tinted `#F7F8F7`, not `#F2F2F7`. Their `<title>` uses an em dash ("Support — Seaford Lacrosse"); use "Support · Seaford Lacrosse". Support says to tap **Forgot your password?**, but the button reads "Forgot Password?"; match the button. The back link exists, but only at the bottom of the page.
- **Dark mode:** the materials are correct (true black, #1C1C1E groups, bright accent with dark text). Segmented thumbs and sheets look native.

### What Works Well

- **Find a Time** is the model screen: results first, pill filters over native selects, field-hue dots, one clear explanation line.
- **Field menu and Fields sheet**: blooming menu with hue dots and "2 fields · Mon–Sat" subtitles, and the Calendars-style sheet with Hide All and Done. Very Apple.
- **Booking moment**: GET pill (30pt visual, 44pt overlay), countdown ring on Confirm, the gold "Yours" row (5.68:1), and a cancel × with the full aria-label "Cancel Field 2, 4:30–5:30 PM".
- **My Team hero**: date, time, "in 4 months", site, Directions and See the Day. It answers the question at a glance.
- **New Admin sheets** (team, person picker, Add Team) already follow v3 grammar. They need the container, not a redesign.
- **Account sheet**: monogram, name fields with a reason ("Directors see this when you book"), Notifications, Appearance, Privacy, Support. A clean replacement for the footer.
- **Hygiene**: 0 emoji (besides the ladder glyph), 0 stroked icons, 0 em dashes in the app, 0 sideways scroll, pixel-audit clean in dark.

### For JJ to decide

- **Desktop tab labels differ from the phone's.** Desktop says "Book A Practice Time", "Find an Open Time", "My Team's Practices" and "League Overview". The phone says Book, Find a Time, Calendar and My Team. The labels are yours, so this is only flagged. A coach who uses both sees two vocabularies, and "Book A" has a capital A mid-phrase. Option: use the phone labels on desktop too, or at least "Book a Practice Time".
