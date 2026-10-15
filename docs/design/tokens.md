# Design tokens: Midnight (dark) and Daylight (light) themes

Source of truth: the "Token sheet" section of [`dark/master-design.dc.html`](dark/master-design.dc.html)
for Midnight, and the "Token table" section of [`light/master-design.dc.html`](light/master-design.dc.html)
for Daylight's colours. This file transcribes them; if they disagree, the design files win.

The second theme, Daylight, is Midnight in a light palette: it differs only in colours (and the window
appearance that follows them). The "Daylight" column gives its value for each colour token; every
other table holds for both themes.

Values and usage notes are copied as the sheet states them. A leading **+** marks an item the sheet
says was added in the last design round because a surface needed it. Numbers without a unit are
points.

## Greys

| Token | Midnight | Usage | Daylight |
|---|---|---|---|
| 01 | `#14161A` | bars: status, footer, titlebar, tab well, action bar. Type on red | `#F8F9FB` |
| 02 | `#1A1C21` | surface. Panels at 95% + blur 30, windows solid | `#EFF0F3`. Panels at 95% |
| 03 | `#23262D` | cards, controls, tracks. Dividers on 02 | `#E0E2E6` |
| 04 | `#2E323B` | hover and selected row, inactive keycap, off track. + a control sitting on a 03 card | `#D0D3D8` |
| 05 | `#3B4150` | every edge: shell, control outline, active keycap, divider on 03 | `#B8BCC4` |
| 06 | `#5A6070` | dashed failure edge, traffic lights. + unchecked checkbox edge. + empty-list glyph. Never text | `#8C929F` |
| 07 | `#9BA1AF` | secondary type. 6.4:1 on 02 | `#515763`. 6.4:1 on 02 |
| 07n | `#B4BAC6` | navigation at rest: inactive tabs and segments | `#424854` |
| 08 | `#E8EAEF` | primary type. + checked checkbox fill | `#16181D` |
| + 00 | `#0E1013` | desktop behind this board. Presentation only, not in the app | `#F2F2F7` |

## Brand, state, system

| Token | Midnight | Usage | Daylight |
|---|---|---|---|
| red | `#E24631` | oklch 0.60 0.196 31°. Trigger caps, active segment and tab, toggle on, 2pt selected-row bar. + default button. + stop button while recording | `#FF7B5D`. oklch 0.78 0.205 32°, the light design file's "custom" accent at its default; chosen 2026-10-15 |
| red hover | `#D0331F` | hover and pressed on any red fill | `#FF6A4D`. The same hue 0.05 darker |
| on red | `#14161A` | all type and glyphs on red, 4.4:1 | `#16181D` |
| green | `#78BE20` | 6pt dot only: Connected, Saved. + Granted. + 7pt idle dot in the popover header, copied check on a history row, API key saved | `#4F8E00` |
| failure | hatch `#8A909E` at 18% on `#1E2126`, 1px dashed 06 | Failed row, rejected key. + Needs access badge. + permission banner. + Invalid key badge | hatch `#666C78` at 18% on `#E8E9ED`, 1px dashed 06 |
| system red | `#FF3B30` | drawn by macOS in alerts. Never on a WhisperKey surface | `#FF3B30`, unchanged |
| off knob | `#8A909E` | off-toggle knob and hatch stroke. Shapes only | `#666C78` |

## Type (SF)

| Size / weight | Sample on the sheet | Usage |
|---|---|---|
| 15/600 | 90k | stat values, tabular |
| 13/600 | Settings | window title, alert title. + in-window heading |
| 13/400 | Launch at login | row labels, values, buttons, body text. Body line-height 1.45 |
| 12/400 | Full history | status line, footer, tabs. + description lines in 07 |
| 11/400 | 14m · ⌘K | timestamps, keycaps, units, badges |
| 11/500 | RECENT | caps headers, 0.06em. Floor is 11 |

## Radii

| Radius | Usage |
|---|---|
| 12 | panel shell (popover, quick paste, toast) |
| 10 | window shell, actions menu |
| 8 | rows, cards, tracks, toggles |
| 6 | keycaps, fields, buttons, badges |
| + 4 | checkbox |

## Sizes

| Name | Size | Usage |
|---|---|---|
| list row | 34 | popover, quick paste, full history, checklist |
| form row | 32 | Settings |
| panel bar | 36 | |
| titlebar | 44 | |
| + action bar | 48 | |
| menu item | 30 | |
| control | 26 | |
| keycap, badge | 18 | |
| toggle | 28×16 | |
| + checkbox | 14 | |
| dot | 6 | |
| + idle dot | 7 | popover header, idle |
| bar | 2×18 | |
| + stop button | 18 | popover header, while recording |
| + icon button | 26 | API key validate and delete |
| + toast close | 20 | |
| widths | panel 320 · quick paste 328 · toast 380 | |
| + settings window | 520 | Settings, both themes |
| + empty-list glyph | 22 | SF title size, tray in Full history |

The standard row heights asked for in #105 are **list row 34** and **form row 32**. The form row was 40
until 2026-10-11, when the Settings window was made one size in both themes: 520 wide, rows of 32.

## Spacing and edges

Steps: **2, 3, 4, 6, 8, 10, 14, 16, 20**.

Text edge 16 in panels, 20 in windows. Rows inset 8 from the shell with 8 inside. Stat tile inset
9×10 stays as drawn.

## Added this round

- **Default button**: red fill, 13/500 on-red label. Welcome only
- **Disabled control**: no fill, 05 edge, 07 label
- **Checkbox**: 14, radius 4. Off: 06 edge on 02. On and mixed: 08 fill, 01 mark
- **Action bar**: 48 on 01, the panel footer at window scale
- **Row names**: 34 is now "list row", 40 "form row"
- **Theme picker**: 40 icon, radius 8. Selected: 2pt red outline, offset 2. Rest: 05 edge, hover 04 fill
- **Green, failure**: extended to Granted and Needs access
- **Empty list**: tray glyph 22 in 06, 4 above a 13/400 line in 07, centred both ways

## Added for the app's controls

Added on 2026-10-15, when the design was revised to govern the look only (#173): every surface now
shows the app's own texts and controls. The sheet's older captions and type samples still name trigger
caps, the selected-row bar, "⌘K" and "RECENT", which the app does not have; the sheet was left as it
was on purpose.

- **Stop button**: 18 red disc, 6 square in 01, radius 1. Hover red hover
- **Icon button**: 26 square, the push button's 03 fill and 05 edge, glyph in 07
- **Toast close**: 20 disc, 03 fill, 05 edge, 07 xmark; centre on the shell's top-left corner, hover only
- **Permission banner**: failure hatch, 1px dashed 06, radius 8; 13/600 title, 12 body in 07, push button on 04
- **Badge tones**: success: 6 green dot + 07 text. Failure: dashed 06. Caution: 04 fill, solid 06 edge, 08 text. Pending: 6 ring in 07 + 07 text
- **Row menu**: the menu shell: 03, 05 edge, radius 10, 30 items, hover 04

## Quick paste popup

Same sizes in Midnight and Daylight; only the colours differ (Daylight in brackets).

| Part | Value |
|---|---|
| header bar | **36** tall (panel bar), full width inside the shell, clipped by the shell's radius 12 |
| header fill | **01** `#14161A` (Daylight `#F8F9FB`) |
| header separator | **1px 03** `#23262D` (Daylight `#E0E2E6`), under the bar; rows start below it |
| header label | "CLIPBOARD", 11/500 caps, 0.06em, 07, text edge 16 |
| rows | list row 34, inset 8 from the shell (8 above the first row), 8 inside |
| selection | 04 fill, 2×18 red bar at the row's leading edge |
| marker column | 14 wide, leading, on every row; 8 gap before the text |
| marker symbol | 11pt, 07 (`Color.secondary`) |
| dictated marker | SF Symbol **`waveform`**, `.semibold` |
| copied marker | SF Symbol **`command`**, `.semibold` (replaces `doc.on.clipboard`) |

Panel height = 1 (edge) + 36 + 1 (separator) + 8 + rows × 34 + 8 + 1 (edge).

`command` is the ⌘ key glyph, in SF Symbols since macOS 11. It names the Cmd-C the user pressed,
reads as a key rather than a button, and its closed loops look nothing like `waveform`'s vertical
bars. At `.semibold` its stroke matches `waveform`'s.

## Values the surfaces use that the sheet does not list

Found by scanning the inline styles of the 17 surface sections of the design file on 2026-10-10.
Values that follow from a sheet token (a 6pt dot at radius 3, a 2pt bar at radius 1, panel fill
`rgba(26,28,33,0.95)` = 02 at 95%, the hatch at 18%) are not listed.

1. **Shadows.** The sheet has no shadow tokens, yet every shell carries one: panels
   `0 22px 48px rgba(0,0,0,0.5)`, windows `0 24px 52px rgba(0,0,0,0.45)`, actions menu
   `0 18px 36px rgba(0,0,0,0.5)`, the mock alert `0 20px 44px rgba(0,0,0,0.6)`. Daylight keeps the
   offsets and blurs with a lighter black, as the light design file draws them: light panels
   `0 22px 48px rgba(0,0,0,0.16)`, light windows `0 24px 52px rgba(0,0,0,0.14)`, light actions menu
   `0 18px 36px rgba(0,0,0,0.16)`, light mock alert `0 20px 44px rgba(0,0,0,0.2)`. The light token
   table lists panel, window and alert sheet; the actions menu value is from the file's mockup.
2. **Weight 500 on red fills.** The active period segment ("All") is 11/500, the active Settings
   tab and the active "Hold" segment are 12/500. The sheet lists 11/500 only for caps headers and
   has no 12/500; 13/500 appears only for the default button.
3. **Checkbox check mark** in Full history is 10/700, below the stated type floor of 11.
4. **Segment heights.** Popover period segments are 24 tall in a 28 track (2 padding); the
   Recording "Hold / Toggle" segments are 22 tall at radius 4 in a 26 track. The sheet has
   control 26 and radius 4 for the checkbox only.
5. **Line heights.** Description lines at 12 use 1.5 (and some 1.4); the sheet states only body
   1.45.
6. **Letter spacing 0.12em** on the masked API key dots; not on the sheet.
7. **`#FFF`** label on the system-red button inside the Reset usage mock alert. macOS draws that
   button, so it is presentation, not an app token.
8. **Spacing off the step list.** 12 is used for padding and gaps in most surfaces; 5, 18, 22, 24
   and 28 also occur. This scan is approximate: it also counts gaps between mockups and captions on
   the board, which are not app spacing.
9. **Radius 7** on the 14×18 microphone glyph drawn in the toast; a glyph shape, not a control.
10. **Settings window.** The window is 520 wide, its edge included. The tab well band is padded
   14 above and below, its track padded 2 with a 2 gap between segments 26 tall. The row area
   is padded 10 at the top and 16 at the bottom.
11. **Settings controls.** Push button: a 24 line inside a 1px 05 edge, padded 10. Pop-up: min
   width 150, padded 10, a 10 gap before up and down chevrons of 3.5 with a 3 gap. Segmented
   control: 150 wide. Number field: padded 10, an 8 gap before the unit, then a 22×26 stepper
   6 apart with triangles of 4, 4 apart. Toggle knob 12, inset 2. API key field 150 wide, an 8
   gap between the row's controls. Saved badge: a 5 gap after the dot. Rejected badge: a 20
   line padded 8 in a 1px dashed 06 edge.
