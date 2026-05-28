# Transient window stack click-out contract

## Summary

WhisperKey's menu bar UI must behave like one transient window stack, not as several
independent windows racing to dismiss themselves.

The stack has ordered layers:

1. Menu bar popover: the root transient app surface opened from the menu bar icon.
2. Secondary windows opened from the popover, such as Settings and Full History.
3. Nested windows or dialogs opened from secondary windows, such as Reset Usage,
   clear-history confirmations, picker popovers, and destructive confirmations.

Click-out behavior depends on which layer receives the click:

1. Clicking inside the topmost visible layer keeps the whole stack open and lets the
   clicked control act normally.
2. Clicking a lower WhisperKey layer closes only the layers above that clicked layer.
3. Clicking outside all WhisperKey transient windows closes the whole stack.

## Current broken behavior

The regression is inconsistent across window types:

1. Opening Settings from the menu bar popover currently places Settings above the
   popover, which is correct.
2. Clicking the menu bar popover while Settings is open closes both Settings and the
   popover. Expected: close Settings only, keep the clicked popover open.
3. Opening Reset Usage from Settings can collapse/dismiss the surrounding UI stack.
   Expected: Reset Usage opens above Settings and the popover remains underneath.
4. Clicking a control inside Settings, such as a toggle, can close Settings. Expected:
   the control changes value and Settings stays open.
5. Opening Full History and then clicking the menu bar popover closes only Full
   History, which matches the desired behavior and should be preserved.

## Investigation notes

Current implementation does not have a single source of truth for this behavior.
The dismiss rules are split across multiple controllers:

1. `MenuBarController` installs its own local and global mouse monitors when the
   popover opens. Its outside-click path can close the popover plus Settings and
   Full History together.
2. `SettingsWindowController` installs another local and global monitor when
   Settings opens. Its local monitor treats anything outside Settings-owned windows
   as a reason to hide Settings.
3. `HistoryFullWindowController` installs a third local and global monitor when
   Full History opens. Its rules are similar to Settings, but not shared.
4. `UsageResetWindowController` is a separate AppKit window introduced later. It
   does not participate in an explicit transient stack; it only attaches itself as
   a child of Settings.

Relevant history:

1. Commit `59294f3` (`Add configurable transcription output routing`) introduced
   the independent click-out monitors for MenuBar, Settings, and Full History.
2. Commit `2b96950` (`Refine usage stats reset UI`) replaced the SwiftUI reset
   sheet with a standalone `UsageResetWindowController`.
3. The current uncommitted work revives the custom `NSStatusItem`/`NSPanel`
   `MenuBarController` path instead of SwiftUI `MenuBarExtra`, so the older
   monitor logic is now active again.

Likely failure mode: the app is trying to compose several local/global monitor
policies after the fact. Once a new child window or a window-level change is added,
one controller can classify a legitimate in-app click as "outside" while another
controller classifies it as inside. That is why Full History can appear correct
while Settings or Reset Usage collapses too much UI.

## Desired behavior matrix

| Visible stack | User click target | Expected result |
| --- | --- | --- |
| Popover | Inside popover | Popover stays open; control/action runs. |
| Popover | Outside WhisperKey | Popover closes. |
| Popover + Settings | Inside Settings | Both stay open; Settings control/action runs. |
| Popover + Settings | Inside popover | Settings closes; popover stays open; clicked popover control/action runs. |
| Popover + Settings | Outside WhisperKey | Settings and popover close. |
| Popover + Full History | Inside Full History | Both stay open; Full History control/action runs. |
| Popover + Full History | Inside popover | Full History closes; popover stays open; clicked popover control/action runs. |
| Popover + Full History | Outside WhisperKey | Full History and popover close. |
| Popover + Settings + Reset Usage | Inside Reset Usage | All stay open; Reset Usage control/action runs. |
| Popover + Settings + Reset Usage | Inside Settings | Reset Usage closes; Settings and popover stay open; clicked Settings control/action runs. |
| Popover + Settings + Reset Usage | Inside popover | Reset Usage and Settings close; popover stays open; clicked popover control/action runs. |
| Popover + Settings + Reset Usage | Outside WhisperKey | Reset Usage, Settings, and popover close. |

## Non-negotiable constraints

1. Do not solve this with one-off keyword checks for individual buttons or window
   titles.
2. Do not add independent dismiss monitors that can disagree about whether a click is
   inside the app.
3. Do not make Settings or child dialogs sit above system menu/picker levels; combo
   boxes, menus, and popovers must remain usable.
4. Do not leave stale SwiftUI transient state alive after a full outside-app dismiss.
5. Preserve normal control behavior: a click that toggles a setting, presses Reset
   Usage, selects a picker item, or presses Cancel must not be swallowed by the
   dismiss logic.

## Implementation direction to evaluate

The durable fix should model transient WhisperKey windows as a single ordered stack
with centralized hit classification:

1. Register every transient window with its stack layer and owner relationship.
2. Classify each mouse down as one of:
   - inside topmost layer;
   - inside a lower WhisperKey layer;
   - outside the WhisperKey transient stack.
3. Dismiss only windows above the clicked layer, or the full stack for outside clicks.
4. Let the original mouse event continue to the clicked window/control whenever the
   click is inside WhisperKey.

This should replace the current scattered behavior where MenuBar, Settings, Full
History, and nested dialogs each install their own local/global monitors and close
different subsets of the UI.

## Acceptance criteria

1. Every scenario in the desired behavior matrix passes manually.
2. Settings and Full History follow the same click-out rules.
3. Reset Usage behaves as a child layer of Settings, not as an outside click.
4. Clicking a Settings toggle changes the toggle and does not dismiss Settings.
5. Clicking the popover while Settings or Full History is open keeps the popover open.
6. Clicking outside all WhisperKey transient windows closes the full stack.
7. Reopening the menu bar popover after full outside dismiss starts from clean
   transient UI state: no Settings, Full History, Reset Usage, or stale confirmation.
