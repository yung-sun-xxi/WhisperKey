# Close all popovers and settings on click-out

## Summary

Click-out should dismiss the full transient WhisperKey UI stack. If the user clicks outside WhisperKey, the menu bar popover, Settings window, and any nested confirmation dialogs should all close/reset.

After that, reopening WhisperKey from the menu bar should show only the normal menu bar popover. Settings should not reappear by itself, and no stale nested dialog should remain open.

## Problem

The current behavior can preserve transient UI state across click-out:

1. Open Settings.
2. Click the trash button beside the API key field.
3. The `Delete saved API key?` confirmation opens.
4. Click outside WhisperKey.
5. Reopen WhisperKey from the menu bar.

Observed bad behavior: Settings and/or the old delete confirmation can still be around or reappear. That makes a dismissed destructive confirmation feel sticky, which is a bad trust signal.

## Desired behavior

Click-out should act like a complete dismiss for transient UI:

1. Close the menu bar popover.
2. Close or fully reset the Settings window.
3. Close any nested confirmation dialogs attached to Settings.
4. Do not reopen Settings automatically when the user later opens the menu bar popover.

## Acceptance criteria

1. Clicking outside WhisperKey closes the menu bar popover.
2. Clicking outside WhisperKey closes the Settings window if it is open.
3. Clicking outside WhisperKey dismisses any nested Settings dialog, including `Delete saved API key?`.
4. Reopening the menu bar item shows the normal popover only.
5. Reopening Settings later starts from a clean Settings UI state.
6. No destructive confirmation remains open after a click-out cycle.

## Current code pointers

- `WhisperKey/SettingsView.swift`
  - `SettingsWindowController.hide()` currently orders the Settings window out.
  - The SwiftUI `SettingsForm` owns transient dialog state via `@State`.
  - Hiding the window may not recreate or reset the SwiftUI view tree.
- `WhisperKey/MenuBarController.swift`
  - Owns menu bar popover presentation and click behavior.

## Implementation notes

Do not paper over this by adding one-off state resets only for the API key dialog. The broader rule is that click-out dismisses the transient UI stack. The fix should make that behavior explicit so future nested dialogs do not inherit the same bug.

Potential approaches to evaluate:

1. Close and recreate the Settings window on click-out instead of only ordering it out.
2. Add an explicit transient-state reset signal from the window controller to SwiftUI.
3. Centralize menu bar popover and Settings dismissal so click-out cannot leave one UI layer alive behind another.
