# Redesign popover as command center

## Summary

Redesign the main WhisperKey popover from a settings-heavy form into a compact command center.

The popover should focus on the user's immediate dictation workflow:

- Show the current transcription model.
- Let the user quickly toggle output destinations.
- Show lightweight today usage stats.
- Keep history as the main content.
- Move slower-changing configuration into a separate Settings window.

This ticket is about product/UI structure and implementation scope. It should not turn the popover into a full analytics dashboard.

## Why this matters

The current popover carries too many settings:

- Provider.
- Model.
- API key.
- Language.
- Save to Clipboard.
- Auto-Paste.
- Trigger.
- Mode.
- Sound effects.
- Launch at login.
- History size.

That makes the app feel like a configuration panel instead of a fast menu bar utility. A menu bar popover should answer two questions quickly:

1. What will happen if I dictate now?
2. What did I recently dictate?

Settings that users rarely change should move out of the primary path.

## Desired popover layout

At the top of the popover, show a compact command/status area.

### Current model

Show the currently selected provider and model in a read-only row.

Example:

```text
OpenAI · gpt-4o-transcribe
```

If space is tight, truncate the model name with an ellipsis. Do not let this row expand the popover width.

### Output destination toggles

Keep these controls in the popover because they affect the next transcription:

- `Clipboard`
- `Auto-Paste`

These are the compact popover labels for the existing output destination settings:

- `Save to Clipboard`
- `Auto-Paste`

The toggles should make the current destination behavior obvious without requiring the user to open Settings.

### Today usage summary

Show one compact usage line:

```text
Today: 12 min · 1.8k words · ~$0.07
```

This line should include:

- Minutes transcribed today.
- Words transcribed today.
- Estimated cost today, if available.

Use `~` for cost because this is an estimate, not billing-grade accounting.

### Saved time estimate

Show saved time as a small secondary line:

```text
Saved time: ~18 min
```

This should be visually subordinate to the current model and output destination controls. It is a product feedback metric, not a primary control.

### History

History remains the main content of the popover.

The new command/status area must stay compact enough that history still has the main visual weight.

### Footer actions

Keep footer actions simple:

- `Settings...`
- `Quit`

## Move to Settings window

Move slower-changing settings out of the main popover and into a separate Settings window:

- Provider.
- Model.
- API key.
- Language, unless there is clear evidence that users frequently switch it before dictation.
- Trigger / hotkey.
- Mode.
- Sound effects.
- Launch at login.
- History size.
- Privacy/history retention settings, if added.

The Settings window should become the place for configuration. The popover should remain the place for action, status, and history.

## Keep in popover

Keep only the controls and information that are useful at the moment of dictation:

- Current model display, read-only.
- `Clipboard` toggle.
- `Auto-Paste` toggle.
- Today usage summary.
- Saved time estimate.
- Permission banner, when permissions are missing.
- History.
- `Settings...`.
- `Quit`.

Optionally keep a compact language selector only if the current app workflow strongly depends on frequent language switching. Otherwise language belongs in Settings.

## Usage calculation

Today stats should be calculated using the user's local calendar day.

For transcriptions created today:

- `minutes transcribed` = sum of audio duration.
- `words transcribed` = sum of recognized word count.
- `estimated cost` = sum of estimated price captured at transcription time.
- `saved time` = sum of estimated saved seconds captured at transcription time.

If there is no usage today, show a clean zero state:

```text
Today: 0 min · 0 words · ~$0.00
Saved time: ~0 min
```

If cost is unavailable or cannot be estimated honestly, do not fake it.

Acceptable fallback:

```text
Today: 12 min · 1.8k words
```

or:

```text
Today: 12 min · 1.8k words · cost unavailable
```

Prefer the shorter version if space is tight.

## Data model requirements

To make the usage block honest, each successful non-empty transcription should store enough metadata to reconstruct the summary later:

- `audioDurationSeconds`.
- `wordCount`.
- `provider`.
- `model`.
- `language`.
- `estimatedPriceAtTime`.
- `currency`.
- `createdAt`.
- `destinationUsed`.
- `copiedToClipboard`.
- `autoPasted`.

For saved time:

- Use a simple explicit baseline, such as assumed typing speed.
- Prefer storing `estimatedSavedSecondsAtTime` on each history item so old history does not change if the formula changes later.

Avoid deriving historical cost from the current model price table. Prices and provider billing behavior can change.

## UX constraints

- Do not turn the popover into an analytics dashboard.
- Keep the command/status area compact.
- History must remain the primary section.
- Treat cost as an estimate, not exact billing.
- Do not add provider/model breakdowns to the popover in this ticket.
- Do not add language breakdowns to the popover in this ticket.
- Do not add charts to the popover in this ticket.
- Do not show transcription text in new places beyond the existing history behavior.
- Do not make users open Settings to change `Clipboard` or `Auto-Paste`.

## Current code pointers

- `WhisperKey/SettingsView.swift`
  - Currently contains many popover-visible settings and should likely be split or reduced.
- `WhisperKey/HistorySection.swift`
  - Owns the history UI that should remain the main popover content.
- `WhisperKey/MenuBarController.swift`
  - Owns menu bar popover presentation.
- `Sources/SettingsStore/SettingsStore.swift`
  - Stores persisted settings, including output destination settings.
- `Sources/HistoryStore/HistoryStore.swift`
  - Should gain or expose the metadata needed for usage summaries.

## Suggested implementation shape

Introduce a small SwiftUI component for the top command/status area, for example:

```text
CommandCenterHeader
```

It should own presentation of:

- Current provider/model row.
- Output destination toggles row.
- Today usage row.
- Saved time row.

Keep the usage aggregation separate from the view so it can be tested without SwiftUI layout tests.

Consider a separate Settings window/screen for the moved settings. The exact window management approach should follow the existing macOS app structure.

## Acceptance criteria

- The main popover no longer contains the full settings form.
- The popover shows the current provider/model near the top.
- The popover exposes `Clipboard` and `Auto-Paste` toggles.
- The popover shows a today usage summary with minutes and words.
- The popover shows estimated cost only when it can be estimated honestly.
- The popover shows a saved time estimate.
- History remains visible on the main popover screen and keeps the main visual weight.
- There is a clear `Settings...` path to the full Settings window.
- Provider, model, API key, trigger, mode, sound effects, launch at login, and history size are available in Settings.
- Empty and unknown usage states render cleanly without fake data.
- Long model names do not break the popover layout.
- The new usage summary does not log or expose raw transcription text.
