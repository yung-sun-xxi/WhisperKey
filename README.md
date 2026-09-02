<p align="center">
  <img src="docs/banner.png" alt="WhisperKey" width="100%">
</p>

# WhisperKey

WhisperKey is a native macOS menu bar app for push-to-talk dictation. Press a
configurable hotkey, speak, and send the transcript to the clipboard and, when
safe, into the focused text field.

It supports OpenAI and Groq Whisper-compatible transcription APIs.

## Features

- Menu bar app with a compact command center.
- Configurable trigger key: Right Option, Right Command, or Right Shift.
- Tap and hold trigger modes.
- Esc-to-cancel while recording.
- OpenAI and Groq provider support with selectable models.
- API key validation and storage in the macOS Keychain.
- Optional clipboard output and auto-paste.
- Local transcription history with configurable retention.
- Local usage counters by provider and model.
- Optional sound effects and launch-at-login support.

## Requirements

- macOS 14 Sonoma or later.
- An API key for OpenAI or Groq.
- Xcode 15 or later for local development.

## Install

Download the latest signed and notarized DMG from
[GitHub Releases](https://github.com/yung-sun-xxi/WhisperKey/releases).

Open the DMG, install `WhisperKey.app`, and launch it from `/Applications` or
Spotlight.

## First Run

WhisperKey needs two macOS permissions:

- Microphone access to record audio while the hotkey is active.
- Accessibility access for the global hotkey and optional auto-paste.

The app opens the relevant System Settings panes during onboarding. If you deny a
permission, enable it later in System Settings under Privacy & Security.

## Provider Setup

Open Settings from the menu bar app, choose a provider, paste your API key, and
let WhisperKey validate and save it.

Supported providers:

- OpenAI: `whisper-1`, `gpt-4o-mini-transcribe`
- Groq: `whisper-large-v3`, `whisper-large-v3-turbo`,
  `distil-whisper-large-v3-en`

Language can be left on Auto or set to English or Russian.

## Privacy

WhisperKey runs locally on your Mac, but transcription is performed by the
provider you configure.

- Audio is recorded only while the configured hotkey starts capture.
- Recorded audio is sent directly to the selected transcription provider.
- API keys are stored in the macOS Keychain.
- Transcription history and usage counters are stored locally.
- WhisperKey does not run an owner-controlled backend service.
- Auto-paste is skipped for secure text fields and can be disabled.

Review your selected provider's terms and data policy before sending sensitive
audio.

## Development

Build the package, run its tests, and build the macOS app:

```sh
scripts/verify.sh
```

That script is the only place those commands live; CI runs the same one. `-t`
runs the package tests alone, `-b` skips them, `-c` cleans the app's derived
data first.

The shared Xcode schemes run the installed Debug app when TCC-sensitive
behavior is involved:

- `WhisperKey` builds Debug, installs `/Applications/WhisperKey Dev.app`, and
  runs that installed app. Use it for normal Xcode development.
- `WhisperKey Dev Installed` builds Debug, installs
  `/Applications/WhisperKey Dev.app`, and runs that installed app. It is kept
  as an explicit installed-app scheme for Microphone, Accessibility, global
  hotkeys, auto-paste, launch behavior, or any other macOS
  TCC/LaunchServices behavior.

The installed dev app uses bundle id `yung-sun-xxi.WhisperKey.dev`; the release
app uses `yung-sun-xxi.WhisperKey`. macOS permissions are separate for those two
identities.

Debug builds use a stable local signing identity named
`WhisperKey Local Development` so macOS TCC permissions survive rebuilds. Create
it once before using the Debug Xcode schemes:

```sh
scripts/ensure-local-signing-cert.sh
```

To skip the `/Applications` install step in scripts or CI:

```sh
WHISPERKEY_SKIP_APPLICATIONS_INSTALL=1 xcodebuild \
  -project WhisperKey.xcodeproj \
  -scheme "WhisperKey Dev Installed" \
  build
```

## Releases

Developer ID signing, notarization, DMG packaging, and GitHub Release publishing
are documented in [RELEASING.md](RELEASING.md).

The public release feed is available at
[GitHub Releases](https://github.com/yung-sun-xxi/WhisperKey/releases).

## Contributing

WhisperKey is currently an owner-driven project. Forks are welcome, but upstream
changes are accepted at the owner's discretion.

Public pull requests do not run on the owner's self-hosted Mac runner.

## License

WhisperKey is released under the [MIT License](LICENSE).
