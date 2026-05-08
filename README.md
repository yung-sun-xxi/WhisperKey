# WhisperKey

Native macOS menu bar voice dictation utility — fast push-to-talk transcription via OpenAI / Groq Whisper.

## Status

Pre-implementation. PRD pending.

## Concept

Lives in the menu bar. Push-to-talk via a configurable hotkey (Right Option / Right Cmd / Right Shift). Audio is sent to a configurable transcription provider; the resulting text lands in the clipboard and auto-pastes into the focused text field if there is one.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+
- An API key for one of the supported providers (OpenAI, Groq)

## Permissions

The app requires:
- **Microphone** — to record audio
- **Accessibility** — for the global hotkey (CGEventTap) and auto-paste (AX focus inspection + simulated ⌘V)

## License

TBD.
