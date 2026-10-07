import AVFoundation
import XCTest
@testable import AudioRecorder

final class AudioRecorderTests: XCTestCase {
    func testDefaultMaxDurationIsTenMinutes() async {
        let recorder = AudioRecorder()
        let value = await recorder.maxDuration
        XCTAssertEqual(value, 10 * 60, accuracy: 0.001)
    }

    func testMaxDurationIsInjectable() async {
        let recorder = AudioRecorder(maxDuration: 1.5)
        let value = await recorder.maxDuration
        XCTAssertEqual(value, 1.5, accuracy: 0.001)
    }

    func testMaxDurationHandlerFiresAfterScheduledInterval() async throws {
        let recorder = AudioRecorder(maxDuration: 0.05)

        let expectation = expectation(description: "max-duration handler fires")
        let counter = HandlerCallCounter()

        await recorder.setOnMaxDurationReached { [counter, expectation] in
            await counter.increment()
            expectation.fulfill()
        }

        await recorder._armMaxDurationTaskForTesting()

        await fulfillment(of: [expectation], timeout: 1.0)
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testCancellingMaxDurationTaskPreventsHandlerCall() async throws {
        let recorder = AudioRecorder(maxDuration: 0.05)
        let counter = HandlerCallCounter()

        await recorder.setOnMaxDurationReached { [counter] in
            await counter.increment()
        }

        await recorder._armMaxDurationTaskForTesting()
        await recorder._cancelMaxDurationTaskForTesting()

        try await Task.sleep(nanoseconds: 200_000_000)
        let count = await counter.value
        XCTAssertEqual(count, 0)
    }

    func testNoHandlerSetIsSafe() async throws {
        let recorder = AudioRecorder(maxDuration: 0.05)
        await recorder._armMaxDurationTaskForTesting()
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func testAudioBufferDetectsDigitalSilence() {
        let silent = AudioBuffer(samples: Data(repeating: 0, count: 8), sampleRate: 16_000, channelCount: 1)
        let nonSilent = AudioBuffer(samples: Data([0, 0, 1, 0]), sampleRate: 16_000, channelCount: 1)
        let empty = AudioBuffer(samples: Data(), sampleRate: 16_000, channelCount: 1)

        XCTAssertTrue(silent.isDigitalSilence)
        XCTAssertFalse(nonSilent.isDigitalSilence)
        XCTAssertFalse(empty.isDigitalSilence)
    }

    func testDiagnosticsExposeNoInFlightConversionBeforeCapture() {
        let recorder = AudioRecorder()
        let snapshot = recorder.diagnosticsSnapshot()

        XCTAssertFalse(snapshot.conversionInFlight)
        XCTAssertNil(snapshot.inFlightTapBufferID)
        XCTAssertNil(snapshot.conversionStartedAt)
    }

    // MARK: - Start-phase diagnostics

    func testDiagnosticsSnapshotDecodesWithoutStartPhaseFields() throws {
        let recorder = AudioRecorder()
        let encoded = try JSONEncoder().encode(recorder.diagnosticsSnapshot())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["inputNodeMillis", "installTapMillis", "prepareMillis", "engineStartMillis", "beginTotalMillis", "reusedEngine"] {
            object.removeValue(forKey: key)
        }
        let older = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AudioRecorderDiagnosticsSnapshot.self, from: older)

        XCTAssertNil(decoded.beginTotalMillis)
        XCTAssertNil(decoded.reusedEngine)
    }

    func testDiagnosticsSnapshotDecodesARecordWrittenBeforeDeviceSwitches() throws {
        let recorder = AudioRecorder()
        let encoded = try JSONEncoder().encode(recorder.diagnosticsSnapshot())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["deviceSwitchCount", "deviceSwitches", "deviceSwitchFailures"] {
            XCTAssertNotNil(object.removeValue(forKey: key), "the snapshot must encode \(key)")
        }
        let older = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AudioRecorderDiagnosticsSnapshot.self, from: older)

        XCTAssertEqual(decoded.deviceSwitchCount, 0)
        XCTAssertEqual(decoded.deviceSwitches, [])
        XCTAssertEqual(decoded.deviceSwitchFailures, 0)
        XCTAssertEqual(decoded.tapBuffersReceived, recorder.diagnosticsSnapshot().tapBuffersReceived)
    }

    func testDeviceSwitchesRoundTripThroughJSON() throws {
        let diagnostics = AudioRecorderDiagnosticsState()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        diagnostics.beginCapture(captureID: 1, engineHostID: 1, inputDevice: Self.builtInMic, inputFormat: format)
        diagnostics.recordDeviceSwitchGap(toHostID: 2, millis: 140)
        diagnostics.recordDeviceSwitch(toHostID: 2, from: Self.builtInMic, to: Self.headsetMic, inputFormat: format)
        diagnostics.recordDeviceSwitchFailure()

        let snapshot = diagnostics.snapshot()
        let decoded = try JSONDecoder().decode(
            AudioRecorderDiagnosticsSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.deviceSwitchCount, 1)
        XCTAssertEqual(decoded.deviceSwitches.first?.gapMillis, 140)
        XCTAssertEqual(decoded.deviceSwitches.first?.toDeviceUID, Self.headsetMic.uid)
        XCTAssertEqual(decoded.deviceSwitchFailures, 1)
        XCTAssertEqual(decoded.engineHostID, 2)
        XCTAssertEqual(decoded.inputDeviceUID, Self.headsetMic.uid)

        diagnostics.beginCapture(captureID: 2, engineHostID: 2, inputDevice: Self.headsetMic, inputFormat: format)
        XCTAssertEqual(diagnostics.snapshot().deviceSwitchCount, 0, "a new capture starts with no switches")
        XCTAssertEqual(diagnostics.snapshot().deviceSwitchFailures, 0)
    }

    func testStartPhasesAreReportedAndClearedByTheNextCapture() throws {
        let diagnostics = AudioRecorderDiagnosticsState()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        diagnostics.beginCapture(captureID: 1, engineHostID: 1, inputDevice: nil, inputFormat: format)
        diagnostics.recordStartPhases(CaptureStartPhases(
            inputNodeMillis: 300,
            installTapMillis: 40,
            prepareMillis: 90,
            engineStartMillis: 120,
            beginTotalMillis: 560,
            reusedEngine: false
        ))

        let first = diagnostics.snapshot()
        XCTAssertEqual(first.inputNodeMillis, 300)
        XCTAssertEqual(first.beginTotalMillis, 560)
        XCTAssertEqual(first.reusedEngine, false)

        diagnostics.beginCapture(captureID: 2, engineHostID: 1, inputDevice: nil, inputFormat: format)
        let second = diagnostics.snapshot()
        XCTAssertNil(second.inputNodeMillis)
        XCTAssertNil(second.beginTotalMillis)
        XCTAssertNil(second.reusedEngine)
    }

    // MARK: - Capture start deadline

    func testStartTimesOutWhenEngineHostNeverCompletes() async {
        let host = StallingEngineHost(hostID: 1)
        let recorder = AudioRecorder(
            maxDuration: 60,
            startTimeout: 0.2,
            engineHostFactory: { _ in host },
            permissionCheck: {}
        )

        do {
            try await recorder.start()
            XCTFail("start() should not succeed while the engine host is stuck")
        } catch AudioRecorderError.engineStartTimedOut(let seconds) {
            XCTAssertEqual(seconds, 0.2, accuracy: 0.001)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertTrue(host.wasRetired, "a stuck host must be retired so it cannot record later")
        let snapshot = recorder.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.captureStartTimeouts, 1)
        XCTAssertNotNil(snapshot.lastCaptureStartTimeoutAt)
    }

    func testRecorderStaysResponsiveAfterAStuckStart() async throws {
        let stuck = StallingEngineHost(hostID: 1)
        let working = SucceedingEngineHost(hostID: 2)
        let hosts = EngineHostSequence(hosts: [stuck, working])
        let recorder = AudioRecorder(
            maxDuration: 60,
            startTimeout: 0.2,
            engineHostFactory: { hosts.next(hostID: $0) },
            permissionCheck: {}
        )

        do {
            try await recorder.start()
            XCTFail("start() should not succeed while the engine host is stuck")
        } catch AudioRecorderError.engineStartTimedOut {
            // expected
        }

        // The stuck host is still holding its queue. Neither call may wait on it.
        let stopped = await recorder.stop()
        XCTAssertNil(stopped, "no capture was active, so stop() must return nil immediately")

        try await recorder.start()
        let snapshot = recorder.diagnosticsSnapshot()
        XCTAssertTrue(snapshot.isRecording)
        XCTAssertEqual(snapshot.engineHostID, 2)
        XCTAssertTrue(stuck.wasRetired, "the stuck host must have been retired")

        _ = await recorder.stop()
        XCTAssertEqual(working.endCaptureCount, 1, "stopping must end the capture off the actor")
        XCTAssertFalse(working.wasRetired, "a normal stop keeps the host for the next start")
    }

    func testStartPropagatesEngineFailure() async {
        let host = FailingEngineHost(hostID: 1)
        let recorder = AudioRecorder(
            maxDuration: 60,
            startTimeout: 5,
            engineHostFactory: { _ in host },
            permissionCheck: {}
        )

        do {
            try await recorder.start()
            XCTFail("start() should surface the engine failure")
        } catch AudioRecorderError.engineFailedToStart(let message) {
            XCTAssertEqual(message, "converter init failed")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(recorder.diagnosticsSnapshot().captureStartTimeouts, 0)
    }

    // MARK: - Engine reuse

    func testSecondStartReusesTheHostAfterANormalStop() async throws {
        let host = SucceedingEngineHost(hostID: 1)
        let factory = CountingHostFactory(hosts: [host])
        let recorder = makeRecorder(factory: factory)

        try await recorder.start()
        _ = await recorder.stop()
        try await recorder.start()

        XCTAssertEqual(factory.created, 1, "the second start must not build a new host")
        XCTAssertEqual(host.beginCount, 2)
        XCTAssertEqual(host.endCaptureCount, 1)
        XCTAssertFalse(host.wasRetired)
        XCTAssertTrue(recorder.diagnosticsSnapshot().isRecording)
        XCTAssertEqual(recorder.diagnosticsSnapshot().engineHostID, 1)
    }

    func testStaleHostIsRetiredAndExactlyOneFreshHostIsBuilt() async throws {
        let stale = SucceedingEngineHost(hostID: 1)
        let fresh = SucceedingEngineHost(hostID: 2)
        let factory = CountingHostFactory(hosts: [stale, fresh])
        let recorder = makeRecorder(factory: factory)
        try await recorder.start()
        _ = await recorder.stop()

        stale.nextBeginIsStale = true
        try await recorder.start()

        XCTAssertTrue(stale.wasRetired, "a stale host must be retired")
        XCTAssertEqual(factory.created, 2, "exactly one fresh host replaces the stale one")
        XCTAssertEqual(recorder.diagnosticsSnapshot().engineHostID, 2)
        XCTAssertTrue(recorder.diagnosticsSnapshot().isRecording)
        XCTAssertFalse(fresh.wasRetired)
    }

    func testAFreshHostThatIsAlsoStaleFailsTheStartWithoutAThirdHost() async {
        let first = SucceedingEngineHost(hostID: 1)
        let second = SucceedingEngineHost(hostID: 2)
        first.nextBeginIsStale = true
        second.nextBeginIsStale = true
        let factory = CountingHostFactory(hosts: [first, second])
        let recorder = makeRecorder(factory: factory)

        do {
            try await recorder.start()
            XCTFail("start() must fail when the replacement host is stale too")
        } catch AudioRecorderError.engineFailedToStart {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(factory.created, 2)
        XCTAssertTrue(first.wasRetired)
        XCTAssertTrue(second.wasRetired)
    }

    func testStaleRetryStaysWithinTheOneStartDeadline() async {
        let stale = SucceedingEngineHost(hostID: 1)
        stale.nextBeginIsStale = true
        stale.beginDelay = 0.15
        let stuck = StallingEngineHost(hostID: 2)
        let factory = CountingHostFactory(hosts: [stale, stuck])
        let recorder = makeRecorder(factory: factory, startTimeout: 0.3)

        let startedAt = Date()
        do {
            try await recorder.start()
            XCTFail("start() should time out on the stuck replacement")
        } catch AudioRecorderError.engineStartTimedOut(let seconds) {
            XCTAssertEqual(seconds, 0.3, accuracy: 0.001)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.45, "the retry must not get a deadline of its own")
        XCTAssertTrue(stale.wasRetired)
        XCTAssertTrue(stuck.wasRetired)
    }

    func testTimeoutRetiresAReusedHostAndTheNextStartBuildsANewOne() async throws {
        let first = SucceedingEngineHost(hostID: 1)
        let second = SucceedingEngineHost(hostID: 2)
        let factory = CountingHostFactory(hosts: [first, second])
        let recorder = makeRecorder(factory: factory, startTimeout: 0.2)
        try await recorder.start()
        _ = await recorder.stop()

        first.nextBeginStalls = true
        do {
            try await recorder.start()
            XCTFail("start() should time out")
        } catch AudioRecorderError.engineStartTimedOut {
            // expected
        }
        XCTAssertTrue(first.wasRetired, "a host that timed out must be retired")
        XCTAssertEqual(recorder.diagnosticsSnapshot().captureStartTimeouts, 1)

        try await recorder.start()
        XCTAssertEqual(factory.created, 2)
        XCTAssertEqual(recorder.diagnosticsSnapshot().engineHostID, 2)
    }

    func testPrewarmBuildsAtMostOneHostAndStartUsesIt() async throws {
        let host = SucceedingEngineHost(hostID: 1)
        let factory = CountingHostFactory(hosts: [host])
        let recorder = makeRecorder(factory: factory)

        await recorder.prewarm()
        await recorder.prewarm()
        await recorder.prewarm()
        XCTAssertEqual(factory.created, 1)
        XCTAssertEqual(host.warmCount, 1)

        try await recorder.start()
        await recorder.prewarm()
        XCTAssertEqual(factory.created, 1, "prewarm while recording must not build a host")
        XCTAssertEqual(host.beginCount, 1)
        XCTAssertEqual(host.warmCount, 1)
    }

    func testPrewarmDoesNothingWithoutMicrophoneAccess() async {
        let factory = CountingHostFactory(hosts: [])
        let recorder = AudioRecorder(
            maxDuration: 60,
            startTimeout: 1,
            engineHostFactory: { factory.next(hostID: $0) },
            permissionCheck: {},
            isMicrophoneAuthorized: { false }
        )

        await recorder.prewarm()

        XCTAssertEqual(factory.created, 0)
    }

    func testStopDuringAReusedStartBehavesAsToday() async throws {
        let host = SucceedingEngineHost(hostID: 1)
        let factory = CountingHostFactory(hosts: [host])
        let recorder = makeRecorder(factory: factory)
        try await recorder.start()
        _ = await recorder.stop()

        host.beginDelay = 0.2
        let starting = Task { try await recorder.start() }
        try await Task.sleep(nanoseconds: 50_000_000)

        let stoppedWhileStarting = await recorder.stop()
        XCTAssertNil(stoppedWhileStarting, "nothing is recording yet, so stop() returns nil at once")
        XCTAssertEqual(host.endCaptureCount, 1, "stop() while starting must not touch the host")

        try await starting.value
        XCTAssertTrue(recorder.diagnosticsSnapshot().isRecording)
        _ = await recorder.stop()
        XCTAssertEqual(host.endCaptureCount, 2)
        XCTAssertFalse(host.wasRetired)
        XCTAssertEqual(factory.created, 1)
    }

    private func makeRecorder(
        factory: CountingHostFactory,
        startTimeout: TimeInterval = 2,
        observer: AudioRouteChangeObserving = NoAudioRouteChangeObserver()
    ) -> AudioRecorder {
        AudioRecorder(
            maxDuration: 60,
            startTimeout: startTimeout,
            engineHostFactory: { factory.next(hostID: $0) },
            permissionCheck: {},
            routeChangeObserver: observer
        )
    }

    fileprivate static let builtInMic = AudioInputDeviceSnapshot(
        objectID: 101,
        name: "MacBook Air Microphone",
        uid: "BuiltInMicrophoneDevice"
    )
    fileprivate static let headsetMic = AudioInputDeviceSnapshot(
        objectID: 201,
        name: "Headset",
        uid: "44-1B-88-F2-0F-0E:input"
    )

    /// Polls `condition` until it holds. Fails the test on timeout unless
    /// `orGiveUp` is set, in which case it just returns.
    private func waitUntil(
        timeout: TimeInterval = 2,
        orGiveUp: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if !orGiveUp {
            XCTFail("condition not met within \(timeout)s", file: file, line: line)
        }
    }

    // MARK: - Input follows the output mid-capture

    func testDefaultOutputChangeMovesTheSameRecordingOntoTheNewInput() async throws {
        let builtIn = RoutingEngineHost(hostID: 1, device: Self.builtInMic, sampleRate: 48_000)
        let headset = RoutingEngineHost(hostID: 2, device: Self.headsetMic, sampleRate: 24_000)
        let factory = CountingHostFactory(hosts: [builtIn, headset])
        let observer = FakeRouteChangeObserver()
        let recorder = makeRecorder(factory: factory, observer: observer)

        try await recorder.start()
        try builtIn.deliverTone(seconds: 0.2)

        builtIn.routeChangeReason = "the derived input changed"
        observer.fire()
        try await waitUntil { recorder.diagnosticsSnapshot().deviceSwitchCount == 1 }

        try headset.deliverTone(seconds: 0.2)
        try await Task.sleep(nanoseconds: 350_000_000)
        // A late buffer from the old engine, still running until its teardown:
        // the new input has already delivered, so it must not be interleaved.
        try builtIn.deliverTone(seconds: 0.1, expectAppend: false)

        let stopped = await recorder.stop()
        let buffer = try XCTUnwrap(stopped)
        XCTAssertEqual(buffer.duration, 0.4, accuracy: 0.03, "audio before and after the switch ends up in one buffer")
        XCTAssertFalse(buffer.isDigitalSilence)
        XCTAssertGreaterThan(peakAmplitude(buffer.samples.prefix(3_000 * 2)), 8_000, "the part before the switch is kept")
        XCTAssertGreaterThan(peakAmplitude(buffer.samples.suffix(3_000 * 2)), 8_000, "the part after the switch is recorded")

        let snapshot = recorder.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.deviceSwitchCount, 1)
        let move = try XCTUnwrap(snapshot.deviceSwitches.first)
        XCTAssertEqual(move.fromDeviceUID, Self.builtInMic.uid)
        XCTAssertEqual(move.fromDeviceName, Self.builtInMic.name)
        XCTAssertEqual(move.toDeviceUID, Self.headsetMic.uid)
        XCTAssertEqual(move.toDeviceName, Self.headsetMic.name)
        let gap = try XCTUnwrap(move.gapMillis, "the gap is measured once the new input delivers")
        XCTAssertGreaterThanOrEqual(gap, 0)
        XCTAssertEqual(snapshot.engineHostID, 2)
        XCTAssertEqual(snapshot.inputDeviceUID, Self.headsetMic.uid)
        XCTAssertEqual(snapshot.inputSampleRate, 24_000)

        XCTAssertTrue(builtIn.wasRetired, "the old host is retired after the switch")
        XCTAssertFalse(headset.wasRetired)
        XCTAssertEqual(headset.endCaptureCount, 1, "stop() ends the capture on the host it moved to")
        XCTAssertTrue(headset.continuedPipeline === builtIn.startedPipeline, "the same pipeline is moved, not a fresh one")
    }

    func testEngineConfigurationChangeOnTheRecordingHostMovesTheRecording() async throws {
        let first = RoutingEngineHost(hostID: 1, device: Self.builtInMic, sampleRate: 48_000)
        let second = RoutingEngineHost(hostID: 2, device: Self.builtInMic, sampleRate: 48_000)
        let factory = CountingHostFactory(hosts: [first, second])
        let recorder = makeRecorder(factory: factory, observer: FakeRouteChangeObserver())

        try await recorder.start()
        try first.deliverTone(seconds: 0.2)
        first.routeChangeReason = "the engine stopped"
        first.fireConfigurationChange()
        try await waitUntil { recorder.diagnosticsSnapshot().deviceSwitchCount == 1 }
        try second.deliverTone(seconds: 0.2)
        try await Task.sleep(nanoseconds: 350_000_000)

        let stopped = await recorder.stop()
        let buffer = try XCTUnwrap(stopped)
        XCTAssertEqual(buffer.duration, 0.4, accuracy: 0.03)
        XCTAssertTrue(first.wasRetired)
    }

    func testARouteEventThatChangesNothingDoesNotRebuild() async throws {
        let host = RoutingEngineHost(hostID: 1, device: Self.builtInMic, sampleRate: 48_000)
        let factory = CountingHostFactory(hosts: [host])
        let observer = FakeRouteChangeObserver()
        let recorder = makeRecorder(factory: factory, observer: observer)

        try await recorder.start()
        host.routeChangeReason = nil
        observer.fire()
        host.fireConfigurationChange()
        try await waitUntil { host.checkRouteCount >= 2 }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(factory.created, 1)
        XCTAssertEqual(recorder.diagnosticsSnapshot().deviceSwitchCount, 0)
        XCTAssertFalse(host.wasRetired)
    }

    func testAConfigurationChangeFromAHostThatIsNotRecordingIsIgnored() async throws {
        let first = RoutingEngineHost(hostID: 1, device: Self.builtInMic, sampleRate: 48_000)
        let second = RoutingEngineHost(hostID: 2, device: Self.headsetMic, sampleRate: 24_000)
        let factory = CountingHostFactory(hosts: [first, second])
        let observer = FakeRouteChangeObserver()
        let recorder = makeRecorder(factory: factory, observer: observer)

        try await recorder.start()
        first.routeChangeReason = "the derived input changed"
        observer.fire()
        try await waitUntil { recorder.diagnosticsSnapshot().deviceSwitchCount == 1 }

        // The retired engine posts its own configuration change late.
        first.fireConfigurationChange()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(second.checkRouteCount, 0, "a retired host's event must not trigger a route check")
        XCTAssertEqual(factory.created, 2)
    }

    func testRebuildsPerCaptureAreCapped() async throws {
        let cap = AudioRecorder.maxDeviceSwitchesPerCapture
        let hosts = (1...(cap + 4)).map { id in
            RoutingEngineHost(hostID: UInt64(id), device: Self.headsetMic, sampleRate: 24_000, alwaysChanged: true)
        }
        let factory = CountingHostFactory(hosts: hosts)
        let observer = FakeRouteChangeObserver()
        let recorder = makeRecorder(factory: factory, observer: observer)

        try await recorder.start()
        for _ in 0..<(cap + 3) {
            let before = factory.created
            observer.fire()
            try await waitUntil(timeout: 0.5, orGiveUp: true) { factory.created > before }
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(factory.created, 1 + cap, "one starting host plus at most \(cap) switches")
        XCTAssertEqual(recorder.diagnosticsSnapshot().deviceSwitchCount, UInt64(cap))
        let stillRecording = recorder.diagnosticsSnapshot().isRecording
        XCTAssertTrue(stillRecording, "hitting the cap keeps the capture running")
    }

    func testTheCapIsPerCapture() async throws {
        let cap = AudioRecorder.maxDeviceSwitchesPerCapture
        let hosts = (1...(2 * cap + 2)).map { id in
            RoutingEngineHost(hostID: UInt64(id), device: Self.headsetMic, sampleRate: 24_000, alwaysChanged: true)
        }
        let factory = CountingHostFactory(hosts: hosts)
        let observer = FakeRouteChangeObserver()
        let recorder = makeRecorder(factory: factory, observer: observer)

        try await recorder.start()
        for _ in 0..<cap {
            let before = factory.created
            observer.fire()
            try await waitUntil { factory.created > before }
        }
        try await waitUntil { recorder.diagnosticsSnapshot().deviceSwitchCount == UInt64(cap) }
        _ = await recorder.stop()

        try await recorder.start()
        let before = factory.created
        observer.fire()
        try await waitUntil { factory.created > before }
    }

    func testAFailedSwitchKeepsTheAudioAlreadyCaptured() async throws {
        let builtIn = RoutingEngineHost(hostID: 1, device: Self.builtInMic, sampleRate: 48_000)
        let broken = RoutingEngineHost(hostID: 2, device: Self.headsetMic, sampleRate: 24_000)
        broken.failsToContinue = true
        let factory = CountingHostFactory(hosts: [builtIn, broken])
        let observer = FakeRouteChangeObserver()
        let recorder = makeRecorder(factory: factory, observer: observer)

        try await recorder.start()
        try builtIn.deliverTone(seconds: 0.4)
        builtIn.routeChangeReason = "the engine stopped"
        observer.fire()
        try await waitUntil { recorder.diagnosticsSnapshot().deviceSwitchFailures == 1 }
        try await Task.sleep(nanoseconds: 350_000_000)

        let stopped = await recorder.stop()
        let buffer = try XCTUnwrap(stopped, "a failed switch must not lose the recording")
        XCTAssertEqual(buffer.duration, 0.4, accuracy: 0.03)
        XCTAssertTrue(broken.wasRetired)
        XCTAssertEqual(builtIn.endCaptureCount, 1, "the capture still ends on the host it never left")
        XCTAssertEqual(recorder.diagnosticsSnapshot().deviceSwitchCount, 0)
    }

    func testAStopDuringASwitchReturnsTheAudioAndKeepsTheNewHostWarm() async throws {
        let builtIn = RoutingEngineHost(hostID: 1, device: Self.builtInMic, sampleRate: 48_000)
        let headset = RoutingEngineHost(hostID: 2, device: Self.headsetMic, sampleRate: 24_000)
        headset.continueDelay = 0.6
        let factory = CountingHostFactory(hosts: [builtIn, headset])
        let observer = FakeRouteChangeObserver()
        let recorder = makeRecorder(factory: factory, observer: observer)

        try await recorder.start()
        try builtIn.deliverTone(seconds: 0.4)
        builtIn.routeChangeReason = "the derived input changed"
        observer.fire()
        try await waitUntil { headset.continueCount == 1 }
        try await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertEqual(recorder.diagnosticsSnapshot().deviceSwitchCount, 0, "the switch is still running")

        let stopped = await recorder.stop()
        let buffer = try XCTUnwrap(stopped)
        XCTAssertEqual(buffer.duration, 0.4, accuracy: 0.03)

        try await waitUntil { builtIn.wasRetired }
        try await waitUntil { headset.endCaptureCount == 1 }
        XCTAssertFalse(headset.wasRetired, "the host built for the new route is kept for the next start")

        try await recorder.start()
        XCTAssertEqual(factory.created, 2, "the next start reuses the host built during the switch")
        XCTAssertEqual(headset.beginCount, 1)
    }

    func testARouteChangeDuringStartIsCheckedOnceTheCaptureRuns() async throws {
        let host = RoutingEngineHost(hostID: 1, device: Self.builtInMic, sampleRate: 48_000)
        host.beginDelay = 0.2
        let factory = CountingHostFactory(hosts: [host])
        let observer = FakeRouteChangeObserver()
        let recorder = makeRecorder(factory: factory, observer: observer)

        let starting = Task { try await recorder.start() }
        try await Task.sleep(nanoseconds: 50_000_000)
        observer.fire()
        try await starting.value

        try await waitUntil { host.checkRouteCount == 1 }
    }

    // MARK: - Capture pipeline across a format change

    func testPipelineRebuildsItsConverterWhenTheSampleRateChanges() throws {
        let first = try monoFormat(48_000)
        let second = try monoFormat(24_000)
        let diagnostics = AudioRecorderDiagnosticsState()
        let pipeline = try CapturePipeline(captureID: 1, inputFormat: first, outputFormat: Self.outputFormat, diagnostics: diagnostics)

        // Buffers of at most 4096 frames, as the tap delivers them.
        for _ in 0..<2 {
            try feed(pipeline, diagnostics, toneBuffer(format: first, toneChannels: [0], seconds: 0.08), sourceID: 1)
        }
        for _ in 0..<2 {
            try feed(pipeline, diagnostics, toneBuffer(format: second, toneChannels: [0], seconds: 0.08), sourceID: 1)
        }

        let samples = pipeline.retireAndSnapshot()
        XCTAssertEqual(diagnostics.snapshot().converterFailures, 0)
        XCTAssertEqual(Double(samples.count / 2) / 16_000, 0.32, accuracy: 0.015)
        XCTAssertGreaterThan(peakAmplitude(samples.suffix(1_500 * 2)), 12_000, "the 24 kHz half is converted, not garbled")
    }

    func testPipelineFollowsAChannelCountChange() throws {
        let mono = try monoFormat(48_000)
        let threeChannels = try multichannelFormat(channels: 3, tag: kAudioChannelLayoutTag_DiscreteInOrder | 3)
        let diagnostics = AudioRecorderDiagnosticsState()
        let pipeline = try CapturePipeline(captureID: 1, inputFormat: mono, outputFormat: Self.outputFormat, diagnostics: diagnostics)

        try feed(pipeline, diagnostics, toneBuffer(format: mono, toneChannels: [0], seconds: 0.08), sourceID: 1)
        try feed(pipeline, diagnostics, toneBuffer(format: threeChannels, toneChannels: [2], seconds: 0.08), sourceID: 1)

        let samples = pipeline.retireAndSnapshot()
        XCTAssertEqual(diagnostics.snapshot().converterFailures, 0)
        XCTAssertEqual(Double(samples.count / 2) / 16_000, 0.16, accuracy: 0.01)
        XCTAssertEqual(Double(peakAmplitude(samples.prefix(1_000 * 2))), 16_384, accuracy: 3_000, "the mono part is at full level")
        XCTAssertEqual(Double(peakAmplitude(samples.suffix(1_000 * 2))), 16_384.0 / 3, accuracy: 1_200, "the 3-channel part is downmixed")
    }

    func testPipelineSwitchesSourceOnTheFirstBufferOfTheNewOne() throws {
        let format = try monoFormat(48_000)
        let diagnostics = AudioRecorderDiagnosticsState()
        diagnostics.beginCapture(captureID: 1, engineHostID: 1, inputDevice: Self.builtInMic, inputFormat: format)
        let pipeline = try CapturePipeline(captureID: 1, inputFormat: format, outputFormat: Self.outputFormat, diagnostics: diagnostics)
        let tone = try toneBuffer(format: format, toneChannels: [0], seconds: 0.08)

        try feed(pipeline, diagnostics, tone, sourceID: 1)
        pipeline.prepareSwitch(toSourceID: 2)
        try feed(pipeline, diagnostics, tone, sourceID: 1)
        diagnostics.recordDeviceSwitch(toHostID: 2, from: Self.builtInMic, to: Self.headsetMic, inputFormat: format)
        XCTAssertNil(diagnostics.snapshot().deviceSwitches.first?.gapMillis, "no gap before the new source delivers")
        try feed(pipeline, diagnostics, tone, sourceID: 2)
        try feed(pipeline, diagnostics, tone, sourceID: 1, expectAppend: false)
        try feed(pipeline, diagnostics, tone, sourceID: 3, expectAppend: false)

        let samples = pipeline.retireAndSnapshot()
        XCTAssertEqual(Double(samples.count / 2) / 16_000, 0.24, accuracy: 0.01, "three buffers of 0.08 s are kept, two are ignored")
        XCTAssertNotNil(diagnostics.snapshot().deviceSwitches.first?.gapMillis)
    }

    // MARK: - Capture pipeline channel handling

    /// The built-in MacBook mic shows up as a 3-channel discrete array while
    /// another app runs voice processing on it. AVAudioConverter cannot derive
    /// a downmix for that layout and writes zeros (issue #125).
    func testThreeChannelDiscreteInputWithToneOnEveryChannelIsNotSilent() throws {
        let format = try multichannelFormat(channels: 3, tag: kAudioChannelLayoutTag_DiscreteInOrder | 3)
        let result = try runPipeline(inputFormat: format, toneChannels: [0, 1, 2])

        XCTAssertFalse(result.isDigitalSilence)
        XCTAssertEqual(Double(result.peak), 16_384, accuracy: 3_000)
    }

    func testThreeChannelInputKeepsAToneCarriedOnlyByTheLastChannel() throws {
        let format = try multichannelFormat(channels: 3, tag: kAudioChannelLayoutTag_DiscreteInOrder | 3)
        let result = try runPipeline(inputFormat: format, toneChannels: [2])

        XCTAssertFalse(result.isDigitalSilence)
        // Averaged over three channels: 0.5 / 3 of full scale.
        XCTAssertEqual(Double(result.peak), 16_384.0 / 3, accuracy: 1_200)
    }

    func testTwoChannelInputKeepsAToneCarriedOnlyByTheSecondChannel() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let result = try runPipeline(inputFormat: format, toneChannels: [1])

        XCTAssertFalse(result.isDigitalSilence)
        XCTAssertEqual(Double(result.peak), 16_384.0 / 2, accuracy: 1_600)
    }

    func testFourChannelInterleavedInputIsNotSilent() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Unknown | 4))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: true,
            channelLayout: layout
        )
        let result = try runPipeline(inputFormat: format, toneChannels: [0, 1, 2, 3])

        XCTAssertFalse(result.isDigitalSilence)
        XCTAssertEqual(Double(result.peak), 16_384, accuracy: 3_000)
    }

    func testMonoInputConvertsExactlyAsADirectConverterDoes() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let result = try runPipeline(inputFormat: format, toneChannels: [0])

        let input = try toneBuffer(format: format, toneChannels: [0])
        let reference = try directConversion(of: input, to: Self.outputFormat)

        XCTAssertEqual(Double(result.peak), 16_384, accuracy: 3_000)
        XCTAssertEqual(result.samples, reference)
    }

    func testMultichannelNonFloatInputFailsToStartInsteadOfRecordingSilence() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        )

        XCTAssertThrowsError(try CapturePipeline(
            captureID: 1,
            inputFormat: format,
            outputFormat: Self.outputFormat,
            diagnostics: AudioRecorderDiagnosticsState()
        )) { error in
            guard case AudioRecorderError.engineFailedToStart = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    // MARK: Helpers

    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private struct PipelineResult {
        let samples: Data
        let peak: Int

        var isDigitalSilence: Bool {
            AudioBuffer(samples: samples, sampleRate: 16_000, channelCount: 1).isDigitalSilence
        }
    }

    private func multichannelFormat(channels: UInt32, tag: AudioChannelLayoutTag) throws -> AVAudioFormat {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: tag))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        )
        XCTAssertEqual(format.channelCount, channels)
        return format
    }

    private func monoFormat(_ sampleRate: Double) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false))
    }

    /// Enqueues one buffer and waits for its conversion to finish.
    private func feed(
        _ pipeline: CapturePipeline,
        _ diagnostics: AudioRecorderDiagnosticsState,
        _ buffer: AVAudioPCMBuffer,
        sourceID: UInt64,
        expectAppend: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let before = diagnostics.snapshot().appendedBuffers
        pipeline.enqueue(
            buffer: buffer,
            tapBufferID: 1,
            inputFrameLength: buffer.frameLength,
            enqueuedAtNanos: audioRecorderNowNanos(),
            sourceID: sourceID
        )
        let deadline = Date().addingTimeInterval(expectAppend ? 2 : 0.1)
        var snapshot = diagnostics.snapshot()
        while (snapshot.appendedBuffers == before || snapshot.conversionInFlight), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
            snapshot = diagnostics.snapshot()
        }
        XCTAssertEqual(snapshot.appendedBuffers, before + (expectAppend ? 1 : 0), file: file, line: line)
    }

    /// `seconds` of a 440 Hz tone at amplitude 0.5 on `toneChannels`, zeros elsewhere.
    private func toneBuffer(format: AVAudioFormat, toneChannels: Set<Int>, seconds: Double = 0.1) throws -> AVAudioPCMBuffer {
        try makeToneBuffer(format: format, toneChannels: toneChannels, seconds: seconds)
    }

    /// Runs one tone buffer through a real `CapturePipeline`, built the way
    /// `CaptureEngineHost` builds it, and returns the captured PCM.
    private func runPipeline(inputFormat: AVAudioFormat, toneChannels: Set<Int>) throws -> PipelineResult {
        let diagnostics = AudioRecorderDiagnosticsState()
        let pipeline = try CapturePipeline(
            captureID: 1,
            inputFormat: inputFormat,
            outputFormat: Self.outputFormat,
            diagnostics: diagnostics
        )
        let input = try toneBuffer(format: inputFormat, toneChannels: toneChannels)
        pipeline.enqueue(
            buffer: input,
            tapBufferID: 1,
            inputFrameLength: input.frameLength,
            enqueuedAtNanos: audioRecorderNowNanos()
        )

        let deadline = Date().addingTimeInterval(2)
        var snapshot = diagnostics.snapshot()
        while (snapshot.appendAttempts < 1 || snapshot.conversionInFlight), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            snapshot = diagnostics.snapshot()
        }
        XCTAssertEqual(snapshot.appendedBuffers, 1, "the buffer must be converted and appended")
        XCTAssertEqual(snapshot.converterFailures, 0)
        XCTAssertEqual(snapshot.outputAllocationFailures, 0)
        XCTAssertEqual(snapshot.emptyOutputBuffers, 0)

        let samples = pipeline.retireAndSnapshot()
        XCTAssertGreaterThan(samples.count, 0)
        return PipelineResult(
            samples: samples,
            peak: peakAmplitude(samples)
        )
    }

    private func directConversion(of input: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) throws -> Data {
        let converter = try XCTUnwrap(AVAudioConverter(from: input.format, to: outputFormat))
        let capacity = AVAudioFrameCount(Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate + 1024)
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity))
        var provided = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return input
        }
        XCTAssertNil(error)
        let channel = try XCTUnwrap(output.int16ChannelData?.pointee)
        return Data(bytes: channel, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    private func peakAmplitude<D: DataProtocol>(_ samples: D) -> Int {
        let bytes = Data(samples)
        return bytes.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).reduce(0) { max($0, abs(Int($1))) }
        }
    }
}

/// `seconds` of a 440 Hz tone at amplitude 0.5 on `toneChannels`, zeros elsewhere.
private func makeToneBuffer(format: AVAudioFormat, toneChannels: Set<Int>, seconds: Double) throws -> AVAudioPCMBuffer {
    let frames = AVAudioFrameCount((format.sampleRate * seconds).rounded())
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let channelData = try XCTUnwrap(buffer.floatChannelData)
    let channels = Int(format.channelCount)
    let stride = buffer.stride
    for frame in 0..<Int(frames) {
        let sample = Float(0.5 * sin(2 * Double.pi * 440 * Double(frame) / format.sampleRate))
        for channel in 0..<channels {
            let value = toneChannels.contains(channel) ? sample : 0
            if format.isInterleaved {
                channelData[0][frame * stride + channel] = value
            } else {
                channelData[channel][frame] = value
            }
        }
    }
    return buffer
}

// MARK: - Engine host doubles

/// Never calls back — stands in for a CoreAudio call that does not return.
private final class StallingEngineHost: CaptureEngineHosting, @unchecked Sendable {
    let hostID: UInt64
    private let lock = NSLock()
    private var retired = false

    init(hostID: UInt64) { self.hostID = hostID }

    var wasRetired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retired
    }

    func warm() {}

    func begin(
        captureID: UInt64,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState,
        previousInputDevice: AudioInputDeviceSnapshot?,
        completion: @escaping @Sendable (Result<CaptureStartResult, CaptureBeginError>) -> Void
    ) {}

    func continueCapture(
        captureID: UInt64,
        pipeline: CapturePipeline,
        diagnostics: AudioRecorderDiagnosticsState,
        completion: @escaping @Sendable (Result<CaptureSwitchResult, CaptureBeginError>) -> Void
    ) {}

    func checkRoute(completion: @escaping @Sendable (String?) -> Void) {
        completion(nil)
    }

    func setConfigurationChangeHandler(_ handler: @escaping @Sendable () -> Void) {}

    func endCapture() {}

    func retire() {
        lock.lock()
        retired = true
        lock.unlock()
    }
}

private final class FailingEngineHost: CaptureEngineHosting, @unchecked Sendable {
    let hostID: UInt64

    init(hostID: UInt64) { self.hostID = hostID }

    func warm() {}

    func begin(
        captureID: UInt64,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState,
        previousInputDevice: AudioInputDeviceSnapshot?,
        completion: @escaping @Sendable (Result<CaptureStartResult, CaptureBeginError>) -> Void
    ) {
        completion(.failure(.recorder(.engineFailedToStart("converter init failed"))))
    }

    func continueCapture(
        captureID: UInt64,
        pipeline: CapturePipeline,
        diagnostics: AudioRecorderDiagnosticsState,
        completion: @escaping @Sendable (Result<CaptureSwitchResult, CaptureBeginError>) -> Void
    ) {}

    func checkRoute(completion: @escaping @Sendable (String?) -> Void) {
        completion(nil)
    }

    func setConfigurationChangeHandler(_ handler: @escaping @Sendable () -> Void) {}

    func endCapture() {}

    func retire() {}
}

/// Reports a started capture without touching audio hardware. A test can
/// make its next begin report the host stale, stall, or answer late.
private final class SucceedingEngineHost: CaptureEngineHosting, @unchecked Sendable {
    let hostID: UInt64
    private let lock = NSLock()
    private var retired = false
    private var begins = 0
    private var warms = 0
    private var endCaptures = 0
    private var stale = false
    private var stalls = false
    private var delay: TimeInterval = 0

    init(hostID: UInt64) { self.hostID = hostID }

    var wasRetired: Bool { locked { retired } }
    var beginCount: Int { locked { begins } }
    var warmCount: Int { locked { warms } }
    var endCaptureCount: Int { locked { endCaptures } }
    var nextBeginIsStale: Bool {
        get { locked { stale } }
        set { locked { stale = newValue } }
    }
    var nextBeginStalls: Bool {
        get { locked { stalls } }
        set { locked { stalls = newValue } }
    }
    var beginDelay: TimeInterval {
        get { locked { delay } }
        set { locked { delay = newValue } }
    }

    func warm() {
        locked { warms += 1 }
    }

    func begin(
        captureID: UInt64,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState,
        previousInputDevice: AudioInputDeviceSnapshot?,
        completion: @escaping @Sendable (Result<CaptureStartResult, CaptureBeginError>) -> Void
    ) {
        let (isStale, isStalling, delay) = locked { () -> (Bool, Bool, TimeInterval) in
            begins += 1
            defer {
                stale = false
                stalls = false
            }
            return (stale, stalls, self.delay)
        }
        if isStalling { return }
        let hostID = hostID
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            if isStale {
                completion(.failure(.staleHost("test host reported stale")))
                return
            }
            guard
                let inputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 44_100,
                    channels: 1,
                    interleaved: false
                ),
                let pipeline = try? CapturePipeline(
                    captureID: captureID,
                    inputFormat: inputFormat,
                    outputFormat: outputFormat,
                    diagnostics: diagnostics
                )
            else {
                completion(.failure(.recorder(.engineFailedToStart("test host could not build a pipeline"))))
                return
            }
            diagnostics.beginCapture(
                captureID: captureID,
                engineHostID: hostID,
                inputDevice: nil,
                inputFormat: inputFormat
            )
            completion(.success(CaptureStartResult(
                pipeline: pipeline,
                inputDevice: nil,
                inputFormat: inputFormat
            )))
        }
    }

    func endCapture() {
        locked { endCaptures += 1 }
    }

    func continueCapture(
        captureID: UInt64,
        pipeline: CapturePipeline,
        diagnostics: AudioRecorderDiagnosticsState,
        completion: @escaping @Sendable (Result<CaptureSwitchResult, CaptureBeginError>) -> Void
    ) {}

    func checkRoute(completion: @escaping @Sendable (String?) -> Void) {
        completion(nil)
    }

    func setConfigurationChangeHandler(_ handler: @escaping @Sendable () -> Void) {}

    func retire() {
        locked { retired = true }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Stands in for an engine bound to one input device at one sample rate. A
/// test feeds audio through it as the real tap would, says what its route
/// check reports, and fires its configuration change.
private final class RoutingEngineHost: CaptureEngineHosting, @unchecked Sendable {
    let hostID: UInt64
    let device: AudioInputDeviceSnapshot
    let inputFormat: AVAudioFormat
    private let alwaysChanged: Bool
    private let lock = NSLock()
    private var retired = false
    private var begins = 0
    private var continues = 0
    private var checks = 0
    private var endCaptures = 0
    private var reason: String?
    private var failsContinue = false
    private var continueWait: TimeInterval = 0
    private var beginWait: TimeInterval = 0
    private var configurationHandler: (@Sendable () -> Void)?
    private var started: CapturePipeline?
    private var continued: CapturePipeline?
    private var attachedDiagnostics: AudioRecorderDiagnosticsState?
    private var tapSequence: UInt64 = 0

    init(hostID: UInt64, device: AudioInputDeviceSnapshot, sampleRate: Double, alwaysChanged: Bool = false) {
        self.hostID = hostID
        self.device = device
        self.alwaysChanged = alwaysChanged
        inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    var wasRetired: Bool { locked { retired } }
    var beginCount: Int { locked { begins } }
    var continueCount: Int { locked { continues } }
    var checkRouteCount: Int { locked { checks } }
    var endCaptureCount: Int { locked { endCaptures } }
    var startedPipeline: CapturePipeline? { locked { started } }
    var continuedPipeline: CapturePipeline? { locked { continued } }
    var routeChangeReason: String? {
        get { locked { reason } }
        set { locked { reason = newValue } }
    }
    var failsToContinue: Bool {
        get { locked { failsContinue } }
        set { locked { failsContinue = newValue } }
    }
    var continueDelay: TimeInterval {
        get { locked { continueWait } }
        set { locked { continueWait = newValue } }
    }
    var beginDelay: TimeInterval {
        get { locked { beginWait } }
        set { locked { beginWait = newValue } }
    }

    func fireConfigurationChange() {
        let handler = locked { configurationHandler }
        handler?()
    }

    /// Feeds `seconds` of tone through the attached pipeline as this host's
    /// tap would, in buffers of at most 4096 frames (the tap's size), and
    /// waits until each is converted (or, when no append is expected, briefly).
    func deliverTone(seconds: Double, expectAppend: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws {
        var remaining = Int((inputFormat.sampleRate * seconds).rounded())
        while remaining > 0 {
            let frames = min(remaining, 4_096)
            try deliverBuffer(frames: frames, expectAppend: expectAppend, file: file, line: line)
            remaining -= frames
        }
    }

    private func deliverBuffer(frames: Int, expectAppend: Bool, file: StaticString, line: UInt) throws {
        let (pipeline, diagnostics, tapBufferID) = locked { () -> (CapturePipeline?, AudioRecorderDiagnosticsState?, UInt64) in
            tapSequence += 1
            return (continued ?? started, attachedDiagnostics, tapSequence)
        }
        let attached = try XCTUnwrap(pipeline, "nothing is attached to host \(hostID)", file: file, line: line)
        let diag = try XCTUnwrap(diagnostics, file: file, line: line)
        let buffer = try makeToneBuffer(format: inputFormat, toneChannels: [0], seconds: Double(frames) / inputFormat.sampleRate)
        let before = diag.snapshot().appendedBuffers
        attached.enqueue(
            buffer: buffer,
            tapBufferID: tapBufferID,
            inputFrameLength: buffer.frameLength,
            enqueuedAtNanos: audioRecorderNowNanos(),
            sourceID: hostID
        )
        let deadline = Date().addingTimeInterval(expectAppend ? 2 : 0.05)
        var snapshot = diag.snapshot()
        while (snapshot.appendedBuffers == before || snapshot.conversionInFlight), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
            snapshot = diag.snapshot()
        }
        XCTAssertEqual(snapshot.appendedBuffers, before + (expectAppend ? 1 : 0), "host \(hostID)", file: file, line: line)
    }

    func warm() {}

    func begin(
        captureID: UInt64,
        outputFormat: AVAudioFormat,
        diagnostics: AudioRecorderDiagnosticsState,
        previousInputDevice: AudioInputDeviceSnapshot?,
        completion: @escaping @Sendable (Result<CaptureStartResult, CaptureBeginError>) -> Void
    ) {
        let delay = locked { () -> TimeInterval in
            begins += 1
            return beginWait
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard let pipeline = try? CapturePipeline(
                captureID: captureID,
                inputFormat: inputFormat,
                outputFormat: outputFormat,
                diagnostics: diagnostics
            ) else {
                completion(.failure(.recorder(.engineFailedToStart("test host could not build a pipeline"))))
                return
            }
            diagnostics.beginCapture(captureID: captureID, engineHostID: hostID, inputDevice: device, inputFormat: inputFormat)
            locked {
                started = pipeline
                continued = nil
                attachedDiagnostics = diagnostics
            }
            completion(.success(CaptureStartResult(pipeline: pipeline, inputDevice: device, inputFormat: inputFormat)))
        }
    }

    func continueCapture(
        captureID: UInt64,
        pipeline: CapturePipeline,
        diagnostics: AudioRecorderDiagnosticsState,
        completion: @escaping @Sendable (Result<CaptureSwitchResult, CaptureBeginError>) -> Void
    ) {
        let (fails, delay) = locked { () -> (Bool, TimeInterval) in
            continues += 1
            return (failsContinue, continueWait)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            if fails {
                completion(.failure(.recorder(.engineFailedToStart("test host failed to continue"))))
                return
            }
            locked {
                continued = pipeline
                attachedDiagnostics = diagnostics
            }
            completion(.success(CaptureSwitchResult(inputDevice: device, inputFormat: inputFormat)))
        }
    }

    func checkRoute(completion: @escaping @Sendable (String?) -> Void) {
        let answer = locked { () -> String? in
            checks += 1
            return alwaysChanged ? "the route always changes on this host" : reason
        }
        DispatchQueue.global().async { completion(answer) }
    }

    func setConfigurationChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        locked { configurationHandler = handler }
    }

    func endCapture() {
        locked { endCaptures += 1 }
    }

    func retire() {
        locked { retired = true }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Stands in for the CoreAudio default-output listener.
private final class FakeRouteChangeObserver: AudioRouteChangeObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    func start(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func stop() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let handler = handler
        lock.unlock()
        handler?()
    }
}

/// Hands out the given hosts in order and counts how many were built.
private final class CountingHostFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [CaptureEngineHosting]
    private var count = 0

    init(hosts: [CaptureEngineHosting]) { self.hosts = hosts }

    var created: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func next(hostID: UInt64) -> CaptureEngineHosting {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return hosts.isEmpty ? StallingEngineHost(hostID: hostID) : hosts.removeFirst()
    }
}

private final class EngineHostSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [CaptureEngineHosting]

    init(hosts: [CaptureEngineHosting]) { self.hosts = hosts }

    func next(hostID: UInt64) -> CaptureEngineHosting {
        lock.lock()
        defer { lock.unlock() }
        return hosts.isEmpty ? StallingEngineHost(hostID: hostID) : hosts.removeFirst()
    }
}


private actor HandlerCallCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
