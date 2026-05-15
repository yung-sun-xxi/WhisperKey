# Add transcription output destination settings

## Summary

Add user settings that control where a successful non-empty transcription goes:

- Clipboard.
- Auto-paste into the currently focused input field.
- Both clipboard and auto-paste.
- Neither clipboard nor auto-paste.

The UI should expose this as two independent toggles:

- `Save to Clipboard`
- `Auto-Paste`

History is independent from these toggles. A successful non-empty transcription must still be written to history even when both toggles are disabled.

## Why this matters

Current behavior always writes the transcription to `NSPasteboard` and then attempts paste. That is convenient for the default flow, but it couples three different product behaviors:

- Keeping the recognized text available in the clipboard.
- Inserting the text into the focused app.
- Saving the text in WhisperKey history.

Users may want different combinations:

- Clipboard only: capture text for manual paste later.
- Auto-paste only: insert text now without replacing their long-term clipboard.
- Both: current default behavior.
- History only: keep a record without touching the active app or clipboard.

## Product behavior

For successful non-empty transcriptions:

| Save to Clipboard | Auto-Paste | Expected behavior |
| --- | --- | --- |
| On | Off | Write transcription to clipboard. Do not send paste. |
| Off | On | Paste transcription into the focused field. Preserve the user's previous clipboard after paste. |
| On | On | Write transcription to clipboard and attempt paste. |
| Off | Off | Do not touch clipboard and do not paste. Save to history only. |

For empty or whitespace-only transcriptions:

- Keep the existing no-op behavior.
- Do not write clipboard.
- Do not paste.
- Do not add a history entry.

## Important implementation constraint

The current paste implementation sends Command-V, so auto-paste depends on the system pasteboard.

If `Auto-Paste` is enabled and `Save to Clipboard` is disabled, the app still needs to mutate the pasteboard temporarily:

1. Snapshot the current pasteboard contents as safely as possible.
2. Write the transcription to the pasteboard.
3. Attempt paste.
4. Restore the previous pasteboard contents after the paste event has had a chance to read the transcription.

Do not pretend this mode avoids pasteboard mutation entirely. The correct user-facing promise is: "Auto-Paste does not leave the transcription in your clipboard."

## Current code pointers

- `WhisperKey/AppCoordinator.swift`
  - `runTranscription(encoded:language:audioDuration:)` currently owns the final post-transcription behavior.
  - It writes to `NSPasteboard`, attempts paste, writes history, and returns to idle.
- `Sources/PasteEngine/PasteEngine.swift`
  - `attemptPaste()` decides whether to send Command-V based on AX focus and secure input.
  - It does not currently own pasteboard writes or restoration.
- `Sources/SettingsStore/SettingsStore.swift`
  - Stores user-facing settings in `UserDefaults`.
  - Should gain persisted output destination toggles with defaults that preserve current behavior.
- `WhisperKey/SettingsView.swift`
  - Should expose the two toggles near existing transcription behavior settings.

## Suggested design

Add two persisted booleans to `SettingsStore`:

- `saveTranscriptionToClipboard`
- `autoPasteTranscription`

Default both to `true` to preserve existing behavior for current users.

Consider extracting clipboard mutation into a small helper instead of keeping all pasteboard logic in `AppCoordinator`. The helper should support:

- Permanent write for clipboard-enabled flows.
- Temporary write + delayed restore for auto-paste-only flows.
- No-op when neither output is enabled.

## Edge cases

- If auto-paste is blocked by `PasteEngine` because the focused field is unsafe, clipboard behavior should still follow `Save to Clipboard`.
- In auto-paste-only mode, if paste is blocked, the previous clipboard should be restored and the transcription should still be available in history.
- If pasteboard restoration fails, log it without exposing raw transcription text.
- Do not log transcription text or pasteboard contents.
- Do not let these toggles affect retry eligibility for provider/network failures.

## Acceptance criteria

- Settings UI contains two toggles: `Save to Clipboard` and `Auto-Paste`.
- Both toggles are persisted across app launches.
- Defaults preserve current behavior: clipboard on, auto-paste on.
- Clipboard-only mode writes clipboard, does not paste, and writes history.
- Auto-paste-only mode attempts paste, restores the previous clipboard, and writes history.
- Both-on mode matches current non-empty behavior and writes history.
- Both-off mode does not touch clipboard, does not paste, and still writes history.
- Empty or whitespace-only transcription remains a no-op and does not write history.
- Tests cover the output matrix independently from provider parsing.
