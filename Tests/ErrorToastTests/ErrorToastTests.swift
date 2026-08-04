import XCTest
@testable import ErrorToast
import TranscriptionProvider

final class ErrorToastTests: XCTestCase {

    // MARK: TranscriptionError.category mapping

    func testCategoryMapsAllErrorCases() {
        XCTAssertEqual(TranscriptionError.network.category, .network)
        XCTAssertEqual(TranscriptionError.timedOut.category, .timedOut)
        XCTAssertEqual(TranscriptionError.rateLimit(message: nil).category, .rateLimit)
        XCTAssertEqual(TranscriptionError.quotaExceeded(message: nil).category, .quotaExceeded)
        XCTAssertEqual(TranscriptionError.unauthorized(message: nil).category, .unauthorized)
        XCTAssertEqual(TranscriptionError.serverError(status: 503, message: nil).category, .serverError)
        XCTAssertEqual(TranscriptionError.clientError(status: 422, message: nil).category, .clientError)
        XCTAssertEqual(TranscriptionError.unknown.category, .unknown)
    }

    // MARK: Retry-eligible categories

    func testNetworkErrorWithCachedAudioOffersRetry() {
        XCTAssertEqual(ToastDecision.action(for: .transcription(.network), hasCachedAudio: true), .retry)
    }

    func testTimeoutWithCachedAudioOffersRetry() {
        XCTAssertEqual(ToastDecision.action(for: .transcription(.timedOut), hasCachedAudio: true), .retry)
    }

    func testRateLimitWithCachedAudioOffersRetry() {
        XCTAssertEqual(ToastDecision.action(for: .transcription(.rateLimit), hasCachedAudio: true), .retry)
    }

    func testServerErrorWithCachedAudioOffersRetry() {
        XCTAssertEqual(ToastDecision.action(for: .transcription(.serverError), hasCachedAudio: true), .retry)
    }

    func testNetworkErrorWithoutCachedAudioFallsBackToOpenSettings() {
        XCTAssertEqual(ToastDecision.action(for: .transcription(.network), hasCachedAudio: false), .openSettings)
    }

    func testRateLimitWithoutCachedAudioFallsBackToOpenSettings() {
        XCTAssertEqual(ToastDecision.action(for: .transcription(.rateLimit), hasCachedAudio: false), .openSettings)
    }

    func testServerErrorWithoutCachedAudioFallsBackToOpenSettings() {
        XCTAssertEqual(ToastDecision.action(for: .transcription(.serverError), hasCachedAudio: false), .openSettings)
    }

    // MARK: Auth / quota → Open Settings (regardless of cache)

    func testUnauthorizedAlwaysOpensSettings() {
        XCTAssertEqual(ToastDecision.action(for: .transcription(.unauthorized), hasCachedAudio: true), .openSettings)
        XCTAssertEqual(ToastDecision.action(for: .transcription(.unauthorized), hasCachedAudio: false), .openSettings)
    }

    func testQuotaExceededAlwaysOpensSettings() {
        XCTAssertEqual(ToastDecision.action(for: .transcription(.quotaExceeded), hasCachedAudio: true), .openSettings)
    }

    // MARK: Other 4xx / unknown → no action

    func testClientErrorHasNoAction() {
        XCTAssertEqual(ToastDecision.action(for: .transcription(.clientError), hasCachedAudio: true), .none)
        XCTAssertEqual(ToastDecision.action(for: .transcription(.clientError), hasCachedAudio: false), .none)
    }

    func testUnknownHasNoAction() {
        XCTAssertEqual(ToastDecision.action(for: .transcription(.unknown), hasCachedAudio: true), .none)
    }

    // MARK: App-level reasons

    func testMissingProviderOpensSettings() {
        XCTAssertEqual(ToastDecision.action(for: .missingProvider, hasCachedAudio: false), .openSettings)
    }

    func testMissingMicrophonePermissionOpensSettings() {
        XCTAssertEqual(ToastDecision.action(for: .microphoneDenied, hasCachedAudio: false), .openSettings)
    }

    func testMissingAccessibilityPermissionOpensSettings() {
        XCTAssertEqual(ToastDecision.action(for: .accessibilityDenied, hasCachedAudio: false), .openSettings)
    }

    func testRecordingCaptureTimeoutHasNoAction() {
        XCTAssertEqual(ToastDecision.action(for: .recordingCaptureTimedOut, hasCachedAudio: false), .none)
    }

    // MARK: ToastContent passthrough

    func testToastContentPreservesMessageAndDerivesAction() {
        let content = ToastDecision.content(
            reason: .transcription(.network),
            message: "Network error — check your internet connection.",
            hasCachedAudio: true
        )
        XCTAssertEqual(content.message, "Network error — check your internet connection.")
        XCTAssertEqual(content.action, .retry)
    }
}
