import XCTest
@testable import SingleInstance

final class SingleInstanceTests: XCTestCase {
    private let ourID = "com.smartcat.WhisperKey"

    func testNoOtherInstancesWhenAlone() {
        XCTAssertFalse(SingleInstanceCheck.anotherInstanceIsRunning(
            ourBundleIdentifier: ourID,
            selfPID: 100,
            runningProcesses: [
                RunningProcess(bundleIdentifier: ourID, processIdentifier: 100),
                RunningProcess(bundleIdentifier: "com.apple.Safari", processIdentifier: 200),
            ]
        ))
    }

    func testDetectsAnotherInstance() {
        XCTAssertTrue(SingleInstanceCheck.anotherInstanceIsRunning(
            ourBundleIdentifier: ourID,
            selfPID: 100,
            runningProcesses: [
                RunningProcess(bundleIdentifier: ourID, processIdentifier: 100),
                RunningProcess(bundleIdentifier: ourID, processIdentifier: 555),
            ]
        ))
    }

    func testNilBundleIdentifierMeansNoCheck() {
        XCTAssertFalse(SingleInstanceCheck.anotherInstanceIsRunning(
            ourBundleIdentifier: nil,
            selfPID: 100,
            runningProcesses: [
                RunningProcess(bundleIdentifier: nil, processIdentifier: 200),
            ]
        ))
    }

    func testEmptyBundleIdentifierMeansNoCheck() {
        XCTAssertFalse(SingleInstanceCheck.anotherInstanceIsRunning(
            ourBundleIdentifier: "",
            selfPID: 100,
            runningProcesses: [
                RunningProcess(bundleIdentifier: "", processIdentifier: 200),
            ]
        ))
    }

    func testIgnoresMatchingPIDOfSelf() {
        XCTAssertFalse(SingleInstanceCheck.anotherInstanceIsRunning(
            ourBundleIdentifier: ourID,
            selfPID: 42,
            runningProcesses: [RunningProcess(bundleIdentifier: ourID, processIdentifier: 42)]
        ))
    }
}
