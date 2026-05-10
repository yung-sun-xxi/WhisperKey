# WhisperKey

Native macOS menu bar voice dictation utility — fast push-to-talk transcription via OpenAI / Groq Whisper.

## Status

In active development. The PRD lives in [Issue #1](https://github.com/yung-sun-xxi/WhisperKey/issues/1); see the [Implementation Order](https://github.com/yung-sun-xxi/WhisperKey/issues/1#implementation-order) section for the locked-in ticket sequence and milestones.

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

## Releasing

Cutting a Developer ID-signed, notarized DMG is documented in [RELEASING.md](RELEASING.md). The pipeline is driven by [`scripts/release.sh`](scripts/release.sh).

## License

TBD.
