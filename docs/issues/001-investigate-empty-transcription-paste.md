# Investigate empty transcription being pasted

## Summary

Runtime logs show at least one successful transcription flow that wrote an empty string to the clipboard and then still attempted paste:

```text
transcription written to clipboard, 0 chars
focus role=nil subrole=nil secureInput=false decision=paste
paste decision: paste
```

This ticket is not a fix request yet. The goal is to understand whether an empty transcription is a valid provider result, an audio capture problem, a parsing edge case, or a UI behavior bug.

## Why this may be bad

If WhisperKey clears the clipboard, writes an empty string, and sends Command-V, it can replace the user's current selection with nothing. That is user-visible data loss in the active app, even if the original clipboard can no longer be recovered.

It may also hide the real failure mode. A "successful" empty transcription could mean the provider returned no speech, the audio buffer was silent, encoding produced bad audio, the request timed out and mapped incorrectly, or the response parser accepted an unexpected empty payload.

## Why it may be acceptable

An empty transcription can be legitimate when the recording contains silence, accidental trigger presses, background noise, or speech below the model's detection threshold. In that case the app should probably do nothing visible, or show a lightweight "no speech detected" state, rather than paste an empty value.

## Current code pointers

- `WhisperKey/AppCoordinator.swift`
  - `runTranscription(encoded:language:)` writes the provider result to `NSPasteboard` before checking `text.isEmpty`.
  - The `!text.isEmpty` guard currently only controls history insertion.
- `Sources/TranscriptionProvider/OpenAIProvider.swift`
  - Maps network errors to `TranscriptionError.network`.
  - Parses successful HTTP responses through `WhisperResponseParser.parseSuccess`.
- `Sources/TranscriptionProvider/GroqProvider.swift`
  - Same provider flow and parser path as OpenAI.

## Investigation questions

1. Which provider and model produced the `0 chars` result?
2. Was the recorded audio buffer non-empty and longer than `AudioRecorder.minDuration`?
3. Was the audio mostly silence, clipped input, or malformed encoded audio?
4. Did the provider return an explicit empty `text`, whitespace, or a different response shape that parsed to empty?
5. Should empty/whitespace-only transcription be treated as success, soft no-op, or failure?
6. Should the previous clipboard be preserved when the transcribed text is empty?

## Suggested diagnostics before changing behavior

Add temporary structured logging around the transcription boundary:

- Provider ID and model.
- Encoded audio format, byte count, and duration.
- HTTP status for successful responses.
- Parsed text length after trimming whitespace.
- Whether the app is about to mutate clipboard or paste.

Avoid logging raw transcription text or API keys.

## Decision points

After investigation, choose one behavior explicitly:

- Treat empty/whitespace-only transcription as "no speech detected" and do not touch clipboard or paste.
- Paste empty text intentionally, but only if there is a clear product reason. This is risky and needs confirmation.
- Classify empty provider output as an error for some providers/models if it indicates a bad response.

## Acceptance criteria for this investigation

- We can reproduce or explain the empty transcription case.
- We know whether the empty result came from capture, encoding, provider response, or parser behavior.
- The expected UX for empty transcription is documented before any implementation work starts.

## Investigation result

- The captured audio path already rejects recordings shorter than `AudioRecorder.minDuration` and empty PCM buffers before encoding, so the observed `0 chars` paste did not come from an empty capture reaching the provider.
- `WhisperResponseParser.parseSuccess` only accepts successful JSON responses shaped like `{"text":"..."}`. A different response shape maps to `TranscriptionError.unknown`; it does not silently become an empty string.
- Therefore `transcription written to clipboard, 0 chars` means the selected provider returned an explicit empty `text` value on a successful HTTP response.
- Previous logs did not include provider/model, encoded byte count, duration, HTTP status, or trimmed result length, so the exact provider/model for the historical event cannot be recovered from the shown snippet.

## Chosen behavior

Empty or whitespace-only transcription is treated as a successful "no speech detected" no-op:

- Do not clear or write the clipboard.
- Do not send Command-V.
- Do not add a history entry.
- Return the app to idle state.
- Keep diagnostics that identify provider, model, encoded audio format, byte count, duration, HTTP status, parsed length, trimmed length, and paste/clipboard decision without logging raw transcription text or API keys.
