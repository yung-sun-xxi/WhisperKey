# Audio capture isolation and failure history

## Incident

On 2026-08-06, a short recording reached the 30-second `recordingStop`
deadline even though the microphone had been working normally seconds earlier.
The diagnostics show that `start()` and later `stop()` calls waited behind an
unrelated recorder operation.  The requested capture never produced audio, so
no history entry could be saved.

## Root cause and scope

`AudioRecorder` is an actor, but it also performs synchronous sample-rate
conversion inside that actor.  Each `AVAudioConverter.convert` call therefore
holds the same serial executor used by `start()` and `stop()`.  A stalled
CoreAudio conversion, or an operation coupled to an audio-device
reconfiguration, blocks every later recording command.

On 2026-08-28 a live stack sample of a wedged process identified the stalling
call.  It is not a conversion: `AudioRecorder.beginCapture()` was inside
`AVAudioEngine.inputNode` -> `AVAudioIOUnit::GetHWFormat` ->
`AudioObjectGetPropertyData`, waiting on `coreaudiod` for the input hardware
format.  A second thread was blocked on the same engine mutex inside
`AVAudioEngineImpl::IOUnitConfigurationChanged()`, and `coreaudiod` itself was
spinning at 66% CPU.  Because `beginCapture()` ran on the actor executor, the
stalled `start()` also owned `AudioRecorder`, so the `stop()` the user asked
for could never be scheduled.

The application defect is therefore broader than conversion: no non-returning
CoreAudio call may prevent a user from starting, stopping, or recovering a
later recording.

This change fixes the application failure boundary.  It does not attempt to
change macOS or a third-party audio driver.

## Goals

1. A stalled conversion from capture A must not block `AudioRecorder.start()`
   or `AudioRecorder.stop()` for capture B.
2. `stop()` must retire the active capture immediately and return the PCM
   captured so far without waiting for conversion work that is already stuck.
3. The UI must not represent a capture as active until the microphone engine
   has actually started.
6. `start()` must fail with a terminal error when the audio engine does not
   report a started capture within a fixed deadline, instead of leaving the
   app in a permanent starting state.
4. Every terminal capture failure, including one with no recoverable audio,
   must be visible in history.
5. Diagnostics must identify the capture, conversion queue, and the last
   completed conversion so a future CoreAudio stall is distinguishable from a
   provider timeout.

## Non-goals

1. Retrying a failed `AVAudioConverter` call in place.
2. Increasing the 30-second deadline.
3. Claiming that a failure with zero captured bytes can be retried.
4. Changing recognised-entry storage, transcription-provider behavior, or the
   user-configured history limit.

## Design

### Engine isolation

Each capture owns a `CaptureEngineHost`: one `AVAudioEngine` plus its own
serial queue.  Every CoreAudio-touching operation — reading the default input
device, `inputNode`, the input format, `installTap`, `prepare`, `start`,
`removeTap`, `stop` — runs on that queue.  The `AudioRecorder` actor never
calls CoreAudio directly.

`start()` hands the work to the host and awaits a result box that resolves to
whichever settles first: the host's completion, or a `startTimeout` deadline
(3 s by default).  Awaiting the box suspends the actor rather than blocking it.
On timeout the recorder retires the host, records the timeout in diagnostics,
and throws `engineStartTimedOut`.  A retired host that finally returns tears
its own engine down and reports failure, so a late start cannot begin
recording into a capture nobody is waiting for.  The next capture always gets a
fresh host, queue, and engine; a stranded host keeps only its own queue.

`stop()` snapshots the pipeline's PCM under a short lock and then asks the host
to retire.  The engine teardown is queued behind whatever CoreAudio work is
stuck, but `stop()` itself returns immediately.

### Capture pipeline isolation

Each actual microphone capture owns a `CapturePipeline` object with:

1. its own `AVAudioConverter`;
2. its own serial conversion queue;
3. a lock-protected, append-only PCM snapshot; and
4. a retired flag and capture identifier.

The audio tap makes an owned copy of each input buffer and submits it to that
capture's pipeline.  The `AudioRecorder` actor never awaits conversion work.
The pipeline accepts at most one pending conversion at a time; additional tap
buffers are counted as dropped rather than accumulating unbounded work.

`stop()` first retires the pipeline, removes the tap, and stops the engine.  It
then snapshots the already-converted PCM under a short lock.  An in-flight
conversion may finish later, but it belongs to the retired pipeline and can
neither append to its returned buffer nor delay a new capture.  A new capture
always receives a new pipeline and converter.

### Start and stop state

`AppCoordinator` keeps the UI in a pending-start path until `recorder.start()`
returns.  If the user releases the hotkey before that point, the operation is
marked cancelled and stopped immediately after a successful late start; it does
not enter the 30-second transcription deadline as a pretend recording.

### History

History gains `captureFailed`.  It records a timestamp, provider/model context,
and a stable explanatory label, but has no audio file and cannot be retried.
The coordinator adds this entry when a capture stop times out without a saved
buffer or when a start/stop race proves that no audio was captured.

Existing JSON remains compatible because the new status is additive.

### Diagnostics

The recorder diagnostic snapshot records whether a conversion is in flight,
its tap-buffer identifier, and how long it has been in flight.  The coordinator
emits the existing timeout events with that snapshot.  Device configuration
changes are recorded when a new capture observes a different default input or
input format.

## Invariants

1. No CoreAudio call of any kind runs on the `AudioRecorder` actor executor —
   neither sample-rate conversion nor engine and device configuration.
2. A pipeline may append PCM only while it is active for its capture ID.
3. Once `stop()` retires a pipeline, its returned buffer is immutable.
4. A timeout either saves an available buffer as retryable history or writes a
   non-retryable `captureFailed` history entry; it never silently disappears.
5. A stale completion must not change the state of a newer recording.
6. `start()` either reports a started engine or throws within `startTimeout`.

## Acceptance criteria

1. Artificially blocking one pipeline conversion does not prevent a second
   recorder operation from completing promptly.
6. An engine host that never returns makes `start()` throw
   `engineStartTimedOut`; `stop()` and the next `start()` still complete
   promptly, and the failed attempt appears in history.
2. A stopped capture returns available PCM without waiting for the blocked
   conversion.
3. A zero-audio capture timeout creates a visible, non-retryable history row.
4. Recognized, pending-recognition, no-speech, and silent-audio history
  behavior remains unchanged.
5. `swift test` passes and the signed-app Debug build succeeds.

## Verification plan

1. Unit-test the pipeline with a controllable conversion gate that deliberately
   blocks one conversion and assert that `stop()` returns its snapshot before
   the gate is released.
2. Unit-test `HistoryStore.captureFailed` persistence, reload compatibility,
   and retry eligibility.
3. Unit-test the start deadline with an engine host that never calls back, and
   assert that the recorder retires it and still serves a following capture.
4. Manually record multiple short messages while changing the system input
   device/sample-rate path; verify that a failed attempt appears in history and
   the next recording starts normally.
