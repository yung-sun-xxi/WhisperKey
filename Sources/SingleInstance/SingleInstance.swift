import Foundation

public struct RunningProcess: Sendable, Equatable {
    public let bundleIdentifier: String?
    public let processIdentifier: Int32

    public init(bundleIdentifier: String?, processIdentifier: Int32) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }
}

public enum SingleInstanceCheck {

    /// Returns `true` if any other process besides `selfPID` shares the same non-empty
    /// `ourBundleIdentifier`. Pure function — accepts a pre-extracted snapshot of running
    /// processes so it can be unit-tested without involving NSWorkspace.
    public static func anotherInstanceIsRunning(
        ourBundleIdentifier: String?,
        selfPID: Int32,
        runningProcesses: [RunningProcess]
    ) -> Bool {
        guard let ours = ourBundleIdentifier, !ours.isEmpty else { return false }
        return runningProcesses.contains { proc in
            proc.bundleIdentifier == ours && proc.processIdentifier != selfPID
        }
    }
}
