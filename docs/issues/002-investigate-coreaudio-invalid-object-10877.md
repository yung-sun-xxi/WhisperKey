# Investigate CoreAudio invalid object errors during capture

Status: closed as no WhisperKey code fix needed for the built-in microphone path.

## Summary

Runtime logs repeatedly show CoreAudio/HAL errors around recording start:

```text
AudioHardware-mac-imp.cpp:917    AudioObjectSetPropertyData: no object with given ID 0
throwing -10877
AudioHardware-mac-imp.cpp:1512   AudioObjectRemovePropertyListener: no object with given ID 0
```

This ticket is not a fix request yet. The goal is to determine whether these messages are harmless macOS framework noise, device-specific audio instability, or a sign that WhisperKey is starting/stopping `AVAudioEngine` incorrectly.

## Why this may be bad

The app still completes many transcriptions after these messages, so they are not an immediate fatal error. However, repeated invalid-object errors can correlate with:

- Audio input device changes while the app is running.
- Stale `AVAudioEngine` or input node state.
- Virtual audio devices or Bluetooth devices disappearing/reappearing.
- Failed listener cleanup.
- Silent or partial audio capture.

If this correlates with empty transcriptions, missed recordings, or start failures, it is a real reliability issue.

## Why it may be acceptable

CoreAudio can emit noisy system logs that are outside app control, especially with Bluetooth, aggregate devices, screen/audio capture tools, or virtual drivers. If recording quality and start/stop behavior are unaffected, this may only be diagnostic noise.

## Current code pointers

- `Sources/AudioRecorder/AudioRecorder.swift`
  - `start()` checks microphone permission and calls `beginCapture()`.
  - `beginCapture()` recreates `AVAudioEngine` for each capture.
  - `beginCapture()` reads `engine.inputNode.outputFormat(forBus: 0)`, installs a tap, prepares, and starts the engine.
  - `stop()` removes the tap and stops the engine.

The code already recreates the engine each capture to avoid stale input format crashes after audio device changes. The question is whether that is sufficient, excessive, or unrelated to these HAL messages.

## Investigation questions

1. Do the `-10877` logs happen on every recording start, only after device changes, or only with specific devices?
2. Which input device is active when the error occurs?
3. Does the error correlate with empty transcription, short buffers, or `engineFailedToStart`?
4. Does it happen with built-in microphone only?
5. Does it happen with Bluetooth microphones, external USB microphones, virtual devices, or aggregate devices?
6. Is there any user-visible failure immediately after these logs?

## Suggested diagnostics before changing behavior

Add temporary logging around capture start/stop:

- Current default input device name/UID if accessible through CoreAudio APIs.
- `inputFormat.sampleRate` and `inputFormat.channelCount`.
- Whether `installTap`, `engine.prepare()`, or `engine.start()` throws.
- Recorded buffer duration and byte count at stop.
- Whether the active input device changed since the previous recording.

Also test a small matrix:

- Built-in microphone.
- AirPods or another Bluetooth input.
- External USB microphone if available.
- Any installed virtual audio device disabled/enabled.

## Decision points

After investigation, decide whether to:

- Ignore as harmless system noise and possibly reduce app log concern.
- Add better user-facing recovery when audio capture starts but produces no usable buffer.
- Rework audio session/engine lifecycle.
- Add device-change handling or explicit engine reset when the default input changes.

## Acceptance criteria for this investigation

- We know whether `-10877` correlates with a user-visible recording failure.
- We know which device conditions reproduce it.
- We have enough evidence to decide whether the fix belongs in WhisperKey code or in user/device troubleshooting guidance.

## Investigation notes

2026-05-14, built-in MacBook Air microphone:

- Device: `id=102 name=MacBook Air Microphone uid=BuiltInMicrophoneDevice`.
- Device remained stable across repeated captures: `inputDeviceChangedSincePrevious=false`.
- Input format remained stable: 48 kHz, 1 channel, non-interleaved float PCM.
- `installTap`, `engine.prepare()`, and `engine.start()` completed successfully.
- Captures produced non-empty PCM buffers, including:
  - capture 9: 14.25 seconds, 455902 bytes.
  - capture 10: 8.26 seconds, 264380 bytes.
  - capture 14: 21.83 seconds, 698662 bytes.
  - capture 15: 24.03 seconds, 768802 bytes.
  - capture 16: 7.42 seconds, 237502 bytes.
- A later spoken test transcribed successfully: "Раз, два, три, четыре, пять, шесть, восемь, девять, десять тест."

Conclusion for the built-in microphone: the CoreAudio `-10877` messages do not correlate with `AVAudioEngine` startup failure, missing taps, device changes, or empty audio buffers. They appear to be harmless framework noise for this device path.

Remaining unknowns:

- Bluetooth input devices.
- External USB microphones.
- Virtual or aggregate audio devices.
- Behavior during live input-device changes while recording or between recordings.

Decision:

- Do not rework the `AVAudioEngine` lifecycle for `-10877`.
- Do not add device-change recovery only because this log appears.
- Keep the capture diagnostics in `AudioRecorder` because they are low-risk and make future device-specific reports actionable.
- Treat the observed empty transcription as a separate issue: successful provider response with empty text should not mutate the clipboard or paste.

If future reports show `-10877` together with `engine.start failed`, zero captured bytes, or device changes on Bluetooth, USB, virtual, or aggregate input devices, open a new device-specific capture bug with those logs. Based on the current evidence, this ticket is system noise, not a WhisperKey recording lifecycle bug.
