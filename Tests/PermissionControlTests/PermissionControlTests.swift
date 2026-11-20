import AVFoundation
import XCTest
@testable import PermissionControl

final class PermissionControlTests: XCTestCase {

    /// Records every command instead of running it: no test resets a real permission.
    final class FakeRunner: CommandRunning, @unchecked Sendable {
        var output = CommandOutput(exitStatus: 0, standardError: "")
        var error: Error?
        private(set) var calls: [(executable: URL, arguments: [String])] = []

        func run(_ executable: URL, arguments: [String]) async throws -> CommandOutput {
            calls.append((executable, arguments))
            if let error { throw error }
            return output
        }
    }

    struct LaunchError: LocalizedError {
        var errorDescription: String? { "The file doesn't exist." }
    }

    // MARK: - Status mapping

    func testMicrophoneStatusMapping() {
        XCTAssertEqual(PermissionStatus.microphone(.authorized), .allowed)
        XCTAssertEqual(PermissionStatus.microphone(.denied), .notAllowed)
        XCTAssertEqual(PermissionStatus.microphone(.restricted), .notAllowed)
        XCTAssertEqual(PermissionStatus.microphone(.notDetermined), .notAsked)
    }

    func testAccessibilityStatusMapping() {
        XCTAssertEqual(PermissionStatus.accessibility(trusted: true), .allowed)
        XCTAssertEqual(PermissionStatus.accessibility(trusted: false), .notAllowed)
    }

    func testAutomationStatusMapping() {
        XCTAssertEqual(PermissionStatus.automation(0), .allowed)
        XCTAssertEqual(PermissionStatus.automation(-1743), .notAllowed)
        XCTAssertEqual(PermissionStatus.automation(-1744), .notAsked)
        XCTAssertEqual(PermissionStatus.automation(-600), .unknown)
        XCTAssertEqual(PermissionStatus.automation(-50), .unknown)
    }

    func testStatusText() {
        XCTAssertEqual(PermissionStatus.allowed.text(for: .microphone), "Allowed")
        XCTAssertEqual(PermissionStatus.notAllowed.text(for: .accessibility), "Not allowed")
        XCTAssertEqual(PermissionStatus.notAsked.text(for: .appleMusic), "Not asked")
        XCTAssertEqual(PermissionStatus.unknown.text(for: .appleMusic), "Unknown until Apple Music is open")
    }

    // MARK: - The row's button

    func testGrantedPermissionsOfferRevoke() {
        for kind in PermissionKind.allCases {
            XCTAssertEqual(PermissionRowAction.action(for: kind, status: .allowed), .revoke, kind.rawValue)
        }
    }

    func testAppleMusicOffersRevokeWhileUnknown() {
        XCTAssertEqual(PermissionRowAction.action(for: .appleMusic, status: .unknown), .revoke)
    }

    func testMissingPermissionsOfferTheBannerActions() {
        XCTAssertEqual(PermissionRowAction.action(for: .microphone, status: .notAsked), .allowMicrophone)
        XCTAssertEqual(PermissionRowAction.action(for: .microphone, status: .notAllowed), .openSystemSettings)
        XCTAssertEqual(PermissionRowAction.action(for: .accessibility, status: .notAllowed), .openSystemSettings)
        XCTAssertEqual(PermissionRowAction.action(for: .appleMusic, status: .notAllowed), .openSystemSettings)
        XCTAssertEqual(PermissionRowAction.action(for: .appleMusic, status: .notAsked), .openSystemSettings)
    }

    func testButtonTitles() {
        XCTAssertEqual(PermissionRowAction.revoke.buttonTitle, "Revoke")
        XCTAssertEqual(PermissionRowAction.allowMicrophone.buttonTitle, "Allow Microphone")
        XCTAssertEqual(PermissionRowAction.openSystemSettings.buttonTitle, "Open System Settings")
    }

    // MARK: - tccutil

    func testTCCResetArgumentsPerService() {
        XCTAssertEqual(TCCResetCommand.executable.path, "/usr/bin/tccutil")
        XCTAssertEqual(
            TCCResetCommand.arguments(for: .microphone, bundleIdentifier: "yung-sun-xxi.WhisperKey.dev"),
            ["reset", "Microphone", "yung-sun-xxi.WhisperKey.dev"]
        )
        XCTAssertEqual(
            TCCResetCommand.arguments(for: .accessibility, bundleIdentifier: "yung-sun-xxi.WhisperKey"),
            ["reset", "Accessibility", "yung-sun-xxi.WhisperKey"]
        )
        XCTAssertEqual(
            TCCResetCommand.arguments(for: .appleMusic, bundleIdentifier: "example.app"),
            ["reset", "AppleEvents", "example.app"]
        )
    }

    func testRevokeRunsTccutilForTheGivenBundleIdentifier() async {
        let runner = FakeRunner()
        let result = await PermissionRevoker(runner: runner).revoke(.accessibility, bundleIdentifier: "example.dev")

        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls.first?.executable.path, "/usr/bin/tccutil")
        XCTAssertEqual(runner.calls.first?.arguments, ["reset", "Accessibility", "example.dev"])
    }

    func testRevokeWithoutBundleIdentifierRunsNothing() async {
        let runner = FakeRunner()
        let result = await PermissionRevoker(runner: runner).revoke(.microphone, bundleIdentifier: nil)

        XCTAssertEqual(result.failure, .noBundleIdentifier)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testNonZeroExitSurfacesTheFirstErrorLine() async {
        let runner = FakeRunner()
        runner.output = CommandOutput(exitStatus: 1, standardError: "tccutil: Failed to reset Microphone\nmore\n")
        let result = await PermissionRevoker(runner: runner).revoke(.microphone, bundleIdentifier: "example.dev")

        XCTAssertEqual(result.failure, .failed(exitStatus: 1, message: "tccutil: Failed to reset Microphone"))
        XCTAssertEqual(result.failure?.userMessage, "Couldn't revoke: tccutil: Failed to reset Microphone")
    }

    func testNonZeroExitWithoutOutputNamesTheStatus() async {
        let runner = FakeRunner()
        runner.output = CommandOutput(exitStatus: 70, standardError: "")
        let result = await PermissionRevoker(runner: runner).revoke(.appleMusic, bundleIdentifier: "example.dev")

        XCTAssertEqual(result.failure?.userMessage, "Couldn't revoke (error 70).")
    }

    func testCommandThatCannotStartIsAFailure() async {
        let runner = FakeRunner()
        runner.error = LaunchError()
        let result = await PermissionRevoker(runner: runner).revoke(.microphone, bundleIdentifier: "example.dev")

        XCTAssertEqual(result.failure?.userMessage, "Couldn't revoke: The file doesn't exist.")
    }

    // MARK: - The real runner, on harmless commands

    func testProcessRunnerReportsExitStatusAndStandardError() async throws {
        let output = try await ProcessCommandRunner().run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo oops >&2; exit 3"]
        )
        XCTAssertEqual(output, CommandOutput(exitStatus: 3, standardError: "oops\n"))
    }

    func testProcessRunnerThrowsForAMissingExecutable() async {
        do {
            _ = try await ProcessCommandRunner().run(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [])
            XCTFail("expected a throw")
        } catch {}
    }

    // MARK: - The confirmation

    func testRevokePromptNamesThePermission() {
        XCTAssertEqual(PermissionRevokePrompt(kind: .microphone).title, "Revoke Microphone access?")
        XCTAssertEqual(PermissionRevokePrompt(kind: .accessibility).title, "Revoke Accessibility access?")
        XCTAssertEqual(PermissionRevokePrompt(kind: .appleMusic).title, "Revoke Apple Music automation?")
    }

    func testOnlyAMicrophoneRevokeRestartsTheApp() {
        XCTAssertTrue(PermissionKind.microphone.revokeRestartsApp)
        XCTAssertFalse(PermissionKind.accessibility.revokeRestartsApp)
        XCTAssertFalse(PermissionKind.appleMusic.revokeRestartsApp)
    }

    func testRestartingPromptSaysSo() {
        XCTAssertTrue(PermissionRevokePrompt(kind: .microphone).informativeText.contains("restarts"))
        XCTAssertFalse(PermissionRevokePrompt(kind: .accessibility).informativeText.contains("restarts"))
        XCTAssertFalse(PermissionRevokePrompt(kind: .appleMusic).informativeText.contains("restarts"))
    }

    // MARK: - The restart

    func testRelaunchWaitsForTheOldProcessThenOpensTheBundleOnTheTab() {
        let arguments = RelaunchCommand.arguments(
            bundlePath: "/Applications/WhisperKey Dev.app",
            processIdentifier: 4242,
            settingsTab: "permissions"
        )

        XCTAssertEqual(RelaunchCommand.executable.path, "/bin/sh")
        XCTAssertEqual(arguments.first, "-c")
        XCTAssertEqual(
            Array(arguments.suffix(4)),
            ["sh", "4242", "/Applications/WhisperKey Dev.app", "permissions"],
            "pid, bundle and tab travel as positional parameters, never spliced into the script"
        )
        let script = arguments[1]
        XCTAssertTrue(script.contains("kill -0 \"$1\""), script)
        XCTAssertTrue(script.contains("seq 1 \(RelaunchCommand.maxWaitPolls)"), "the wait has a deadline: \(script)")
        XCTAssertTrue(script.contains("/usr/bin/open \"$2\" --args -\(RelaunchCommand.openSettingsTabArgument) \"$3\""), script)
    }

    /// Runs the real script against a process that is already gone and a bundle that does
    /// not exist: it must not wait out the deadline, and it must reach `open`.
    func testRelaunchScriptStopsWaitingOnceTheProcessIsGone() async throws {
        let arguments = RelaunchCommand.arguments(
            bundlePath: "/nonexistent/WhisperKey Test.app",
            processIdentifier: 999_999,
            settingsTab: "permissions"
        )
        let started = Date()
        let output = try await ProcessCommandRunner().run(RelaunchCommand.executable, arguments: arguments)

        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertNotEqual(output.exitStatus, 0, "open fails on a missing bundle, so the script got that far")
        XCTAssertTrue(output.standardError.contains("WhisperKey Test.app"), output.standardError)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
