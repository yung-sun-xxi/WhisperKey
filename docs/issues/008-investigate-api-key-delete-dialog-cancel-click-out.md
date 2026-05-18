# Investigate API key delete dialog cancel click-out behavior

## Summary

The `Cancel` button in the `Delete saved API key?` dialog appears to behave like a click-out: instead of only dismissing the confirmation, it may also close the surrounding Settings UI.

This should be investigated before changing the event handling, because the failure mode likely sits at the boundary between SwiftUI alerts and the current AppKit click-out monitor.

## Problem

The Settings window has mouse monitors that close Settings when a click is considered outside the Settings window. SwiftUI alerts may be implemented as separate windows or child windows. If the monitor does not treat the alert as part of the Settings UI, clicking `Cancel` can be misclassified as an outside click.

That makes a safe action feel unsafe: the user expects `Cancel` to dismiss only the confirmation and leave Settings open.

## Investigation questions

1. When the SwiftUI alert is open, is the alert represented as a child window of the Settings window?
2. What does `event.window` point to when clicking `Cancel`?
3. Does `SettingsWindowController.eventIsInsideSettingsWindow(_:)` return false for alert button clicks?
4. Does the local mouse monitor run before or after SwiftUI handles the alert button action?
5. Would switching from SwiftUI `.alert` to an explicit AppKit `NSAlert` sheet/window avoid the event ordering issue?
6. Would the broader click-out fix from issue 007 make this bug disappear, or does `Cancel` still need special handling?

## Acceptance criteria

1. Clicking `Cancel` dismisses only the `Delete saved API key?` confirmation.
2. Settings remains open after clicking `Cancel`.
3. Clicking `Delete API Key` performs the deletion and does not look like an accidental click-out.
4. Clicking outside WhisperKey still dismisses the full transient UI stack as described in issue 007.
5. The chosen fix is documented in code or tests where the event-ordering behavior would otherwise be non-obvious.

## Current code pointers

- `WhisperKey/SettingsView.swift`
  - `SettingsWindowController.startDismissMonitoring()` installs local and global mouse monitors.
  - `SettingsWindowController.eventIsInsideSettingsWindow(_:)` checks the Settings window, parent window, and child windows.
  - `SettingsForm` presents the delete confirmation with SwiftUI `.alert`.

## Research output

Before implementation, capture the observed AppKit window relationships for the alert and decide whether the right fix is:

1. improve the click-out containment logic;
2. reset/close the full transient UI stack on click-out;
3. replace the SwiftUI alert with an AppKit alert/sheet;
4. combine the above if SwiftUI alert behavior remains ambiguous.
