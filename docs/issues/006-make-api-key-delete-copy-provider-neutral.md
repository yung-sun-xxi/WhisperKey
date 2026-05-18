# Make API key deletion copy provider-neutral

## Summary

The delete confirmation for the saved API key should not name a specific provider. The user action is "delete the saved API key from this Mac", not "delete the OpenAI key" or "delete the Groq key".

The message should also be a single paragraph with no trailing period, matching the requested tone and avoiding unnecessary internal detail.

## Problem

The current dialog copy includes the selected provider display name:

```text
This will remove the saved OpenAI API key from this Mac.

You will need to enter the API key again before using OpenAI transcription.
```

This is too specific for the UX. Users can configure multiple providers over time, and the destructive action should be phrased around the saved key itself. Provider-specific storage is an implementation detail.

## Desired copy

```text
Delete saved API key?

This will remove the saved API key from this Mac and you will need to enter it again before using transcription
```

## Acceptance criteria

1. The dialog message is one paragraph.
2. The dialog message does not mention OpenAI, Groq, or any provider name.
3. The dialog message has no period at the end.
4. The title remains `Delete saved API key?`.
5. The destructive action remains clearly labeled, for example `Delete API Key`.
6. The cancel action remains available.

## Current code pointers

- `WhisperKey/SettingsView.swift`
  - `SettingsForm` owns the API key delete alert state.
  - The alert message currently interpolates `request.provider.displayName`.
