# Investigate HALC ProxyIOContext overload during recording

## Summary

Runtime logs repeatedly show audio work loop overload messages:

```text
HALC_ProxyIOContext.cpp:1623  HALC_ProxyIOContext::IOWorkLoop: skipping cycle due to overload
```

This ticket is not a fix request yet. The goal is to determine whether WhisperKey is causing audio callback pressure, whether the host system is overloaded, and whether this affects transcription quality.

## Why this may be bad

An audio work loop overload means CoreAudio skipped an I/O cycle because something did not keep up. In practice, that can cause dropped audio frames, gaps, distorted capture, or inconsistent transcription quality.

The current app can still complete transcriptions after these logs, so this is not necessarily fatal. But if users report missing words, clipped recordings, empty transcriptions, or degraded accuracy, this log is a serious lead.

## Why it may be acceptable

The message can be caused by overall machine load, other audio software, Bluetooth instability, virtual devices, or system-level scheduling. If it happens rarely and does not correlate with bad transcription output, it may not require app changes.

## Current code pointers

- `Sources/AudioRecorder/AudioRecorder.swift`
  - The input tap is installed with `bufferSize: 4_096`.
  - The tap closure creates a `Task` and sends each buffer into the `AudioRecorder` actor.
  - `append(buffer:inputFormat:outputFormat:)` performs sample-rate conversion with `AVAudioConverter` and appends PCM data to `Data`.

This design keeps heavier work out of the synchronous tap body, but it may still create backpressure if conversion tasks accumulate faster than they complete.

## Investigation questions

1. Do overload logs occur only during recording, or also while the app is idle?
2. Do they correlate with long recordings, short repeated recordings, or specific microphones?
3. Do they correlate with empty or low-quality transcription output?
4. Are conversion tasks piling up behind the actor during recording?
5. Is `bufferSize: 4_096` appropriate for the observed devices and sample rates?
6. Is `AVAudioConverter` being used in a way that is safe and efficient for repeated tap buffers?

## Suggested diagnostics before changing behavior

Add temporary metrics around the audio pipeline:

- Count received tap buffers.
- Count appended buffers.
- Track conversion failures from `AVAudioConverter`.
- Track max/average time spent in `append`.
- Track final captured duration versus wall-clock recording duration.
- Track final PCM byte count and expected byte count for 16 kHz mono Int16.

Use Instruments if needed:

- Time Profiler during repeated recording.
- System Trace or audio-related profiling while reproducing overload logs.
- Check whether CPU spikes come from WhisperKey, the provider upload path, or unrelated apps.

## Decision points

After investigation, decide whether to:

- Keep the current pipeline and classify the log as environmental noise.
- Move conversion to a more controlled serial processing path.
- Reduce allocations in the capture path.
- Change buffer size.
- Add detection for suspicious capture gaps and surface a "recording quality degraded" warning.

## Acceptance criteria for this investigation

- We know whether overload logs happen while WhisperKey is actively recording.
- We know whether captured audio duration matches wall-clock duration under overload.
- We know whether transcription quality suffers when overload logs appear.
- Any proposed fix is based on measured pipeline behavior, not just the scary-looking CoreAudio log line.
