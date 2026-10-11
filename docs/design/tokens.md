# Design tokens: Midnight (dark) theme

Source of truth: the "Token sheet" section of [`dark/master-design.dc.html`](dark/master-design.dc.html).
This file transcribes it; if the two disagree, the design file wins.

The tokens apply to the **Midnight (dark) theme** only. The light **Classic** theme is the current
system look and was not designed.

Values and usage notes are copied as the sheet states them. A leading **+** marks an item the sheet
says was added in the last design round because a surface needed it. Numbers without a unit are
points.

## Greys

| Token | Value | Usage |
|---|---|---|
| 01 | `#14161A` | bars: status, footer, titlebar, tab well, action bar. Type on red |
| 02 | `#1A1C21` | surface. Panels at 95% + blur 30, windows solid |
| 03 | `#23262D` | cards, controls, tracks. Dividers on 02 |
| 04 | `#2E323B` | hover and selected row, inactive keycap, off track. + a control sitting on a 03 card |
| 05 | `#3B4150` | every edge: shell, control outline, active keycap, divider on 03 |
| 06 | `#5A6070` | dashed failure edge, traffic lights. + unchecked checkbox edge. Never text |
| 07 | `#9BA1AF` | secondary type. 6.4:1 on 02 |
| 07n | `#B4BAC6` | navigation at rest: inactive tabs and segments |
| 08 | `#E8EAEF` | primary type. + checked checkbox fill |
| + 00 | `#0E1013` | desktop behind this board. Presentation only, not in the app |

## Brand, state, system

| Token | Value | Usage |
|---|---|---|
| red | `#E24631` | oklch 0.60 0.196 31°. Trigger caps, active segment and tab, toggle on, 2pt selected-row bar. + default button |
| red hover | `#D0331F` | hover and pressed on any red fill |
| on red | `#14161A` | all type and glyphs on red, 4.4:1 |
| green | `#78BE20` | 6pt dot only: Connected, Saved. + Granted |
| failure | hatch `#8A909E` at 18% on `#1E2126`, 1px dashed 06 | Failed row, rejected key. + Needs access badge |
| system red | `#FF3B30` | drawn by macOS in alerts. Never on a WhisperKey surface |
| off knob | `#8A909E` | off-toggle knob and hatch stroke. Shapes only |

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
| form row | 40 | Settings |
| panel bar | 36 | |
| titlebar | 44 | |
| + action bar | 48 | |
| menu item | 30 | |
| control | 26 | |
| keycap, badge | 18 | |
| toggle | 28×16 | |
| + checkbox | 14 | |
| dot | 6 | |
| bar | 2×18 | |
| widths | panel 320 · quick paste 328 · toast 380 | |

The standard row heights asked for in #105 are **list row 34** and **form row 40**.

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
- **Green, failure**: extended to Granted and Needs access

## Values the surfaces use that the sheet does not list

Found by scanning the inline styles of the 17 surface sections of the design file on 2026-10-10.
Values that follow from a sheet token (a 6pt dot at radius 3, a 2pt bar at radius 1, panel fill
`rgba(26,28,33,0.95)` = 02 at 95%, the hatch at 18%) are not listed.

1. **Shadows.** The sheet has no shadow tokens, yet every shell carries one: panels
   `0 22px 48px rgba(0,0,0,0.5)`, windows `0 24px 52px rgba(0,0,0,0.45)`, actions menu
   `0 18px 36px rgba(0,0,0,0.5)`, the mock alert `0 20px 44px rgba(0,0,0,0.6)`.
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
10. **Settings window.** The window is 580 wide, its edge included. The tab well band is padded
   14 above and below, its track padded 2 with a 2 gap between segments 26 tall. The row area
   is padded 10 at the top and 16 at the bottom.
11. **Settings controls.** Push button: a 24 line inside a 1px 05 edge, padded 10. Pop-up: min
   width 150, padded 10, a 10 gap before up and down chevrons of 3.5 with a 3 gap. Segmented
   control: 150 wide. Number field: padded 10, an 8 gap before the unit, then a 22×26 stepper
   6 apart with triangles of 4, 4 apart. Toggle knob 12, inset 2. API key field 150 wide, an 8
   gap between the row's controls. Saved badge: a 5 gap after the dot. Rejected badge: a 20
   line padded 8 in a 1px dashed 06 edge.
